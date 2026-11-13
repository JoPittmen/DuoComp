import Foundation
import AVFoundation
import CoreGraphics

public enum CompError: LocalizedError {
    case noTracks
    case cannotRead(String)
    case cannotWrite(String)

    public var errorDescription: String? {
        switch self {
        case .noTracks: "This file has no video or audio Duo Comp can read."
        case .cannotRead(let m): "Couldn't read the file. \(m)"
        case .cannotWrite(let m): "Couldn't write the new file. \(m)"
        }
    }
}

public struct CompRequest: Sendable {
    public var source: URL
    public var output: URL
    public var preset: CompPreset
    public var framing: CompFraming
    public var cropPosition: Double
    public var trimStart: Double
    public var trimEnd: Double?

    public init(job: CompJob, source: URL, output: URL) {
        self.source = source; self.output = output; preset = job.preset
        framing = job.framing; cropPosition = job.cropPosition; trimStart = job.trimStart; trimEnd = job.trimEnd
    }
}

/// One encode: Apple's hardware encoders through AVAssetReader → AVAssetWriter.
/// Crop, scale and rotation happen in a video composition on the way through.
public final class CompEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?

    public init() {}

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        reader?.cancelReading()
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    public func run(_ req: CompRequest, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: req.source)
        let assetDuration = try await asset.load(.duration)
        let videoTrack = req.preset.isAudioOnly ? nil : try await asset.loadTracks(withMediaType: .video).first
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard videoTrack != nil || !audioTracks.isEmpty else { throw CompError.noTracks }

        let start = CMTime(seconds: max(0, req.trimStart), preferredTimescale: 600)
        let end = req.trimEnd.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? assetDuration
        let range = CMTimeRange(start: start, end: CMTimeMinimum(end, assetDuration))
        let total = max(range.duration.seconds, 0.001)

        try? FileManager.default.removeItem(at: req.output)
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: req.output, fileType: req.preset.isAudioOnly ? .m4a : .mp4)
        } catch {
            throw CompError.cannotRead(error.localizedDescription)
        }
        reader.timeRange = range
        writer.shouldOptimizeForNetworkUse = true
        self.reader = reader; self.writer = writer

        var pumps: [Pump] = []

        if let videoTrack {
            let (natural, transform, fps, dataRate) = try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate)
            let displayRect = CGRect(origin: .zero, size: natural).applying(transform)
            let display = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
            // Move the rotated frame back to the origin before cropping or scaling.
            let upright = transform.concatenating(CGAffineTransform(translationX: -displayRect.minX, y: -displayRect.minY))

            let render: CGSize
            let place: CGAffineTransform
            if let w = req.preset.width, let h = req.preset.height, let aspect = req.preset.aspect {
                render = CGSize(width: w, height: h)
                switch req.framing {
                case .fill:
                    let crop = CompMath.cropRect(source: display, aspect: aspect, position: req.cropPosition)
                    let s = render.width / crop.width
                    place = upright
                        .concatenating(CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                        .concatenating(CGAffineTransform(scaleX: s, y: s))
                case .fit:
                    let fit = CompMath.fitRect(source: display, target: render)
                    let s = fit.width / display.width
                    place = upright
                        .concatenating(CGAffineTransform(scaleX: s, y: s))
                        .concatenating(CGAffineTransform(translationX: fit.minX, y: fit.minY))
                }
            } else {
                render = CGSize(width: CompMath.even(display.width), height: CompMath.even(display.height))
                place = upright
            }

            let rate = Double(fps > 0 ? fps : 30)
            let outFPS = min(rate, req.preset.maxFrameRate > 0 ? req.preset.maxFrameRate : rate)

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: assetDuration)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(place, at: .zero)
            instruction.layerInstructions = [layer]
            let composition = AVMutableVideoComposition()
            composition.renderSize = render
            composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(outFPS.rounded()))
            composition.instructions = [instruction]

            let out = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack], videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            out.videoComposition = composition
            out.alwaysCopiesSampleData = false

            let bitrate = req.preset.videoBitrate ?? max(1_500_000, Int(Double(dataRate) * 0.5))
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: outFPS,
                AVVideoMaxKeyFrameIntervalKey: Int(outFPS * 2),
            ]
            if req.preset.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: req.preset.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                AVVideoWidthKey: Int(render.width),
                AVVideoHeightKey: Int(render.height),
                AVVideoCompressionPropertiesKey: compression,
            ])
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(out), writer.canAdd(input) else { throw CompError.cannotWrite("Video settings were refused.") }
            reader.add(out); writer.add(input)
            pumps.append(Pump(output: out, input: input, label: "video", reportsProgress: true))
        }

        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: req.preset.audioBitrate,
            ])
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(out), writer.canAdd(input) else { throw CompError.cannotWrite("Audio settings were refused.") }
            reader.add(out); writer.add(input)
            // With no video, audio drives the progress bar.
            pumps.append(Pump(output: out, input: input, label: "audio", reportsProgress: pumps.isEmpty))
        }

        guard writer.startWriting() else { throw CompError.cannotWrite(writer.error?.localizedDescription ?? "") }
        guard reader.startReading() else { throw CompError.cannotRead(reader.error?.localizedDescription ?? "") }
        writer.startSession(atSourceTime: range.start)

        await withTaskGroup(of: Void.self) { group in
            for pump in pumps {
                group.addTask { [self] in
                    await pump.run(isCancelled: { self.isCancelled }) { t in
                        progress(min(1, max(0, (t - range.start.seconds) / total)))
                    }
                }
            }
        }

        if isCancelled || reader.status == .cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: req.output)
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: req.output)
            throw CompError.cannotRead(reader.error?.localizedDescription ?? "")
        }
        await writer.finishWriting()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: req.output)
            throw CompError.cannotWrite(writer.error?.localizedDescription ?? "")
        }
        progress(1)
    }
}

/// Moves samples from one reader output into one writer input on its own queue.
private final class Pump: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    let queue: DispatchQueue
    let reportsProgress: Bool

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput, label: String, reportsProgress: Bool) {
        self.output = output; self.input = input; self.reportsProgress = reportsProgress
        queue = DispatchQueue(label: "DuoComp.\(label)")
    }

    func run(isCancelled: @escaping @Sendable () -> Bool, progress: @escaping @Sendable (Double) -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            var lastReport = -1.0
            func finish() {
                guard !finished else { return }
                finished = true
                input.markAsFinished()
                done.resume()
            }
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    if isCancelled() { finish(); return }
                    guard let buffer = output.copyNextSampleBuffer() else { finish(); return }
                    if reportsProgress {
                        let t = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                        if t.isFinite, t - lastReport >= 0.25 { lastReport = t; progress(t) }
                    }
                    if !input.append(buffer) { finish(); return }
                }
            }
        }
    }
}
