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
    public var videoBitrate: Int?
    public var codec: CompCodec
    public var framing: CompFraming
    public var cropPosition: Double
    public var trimStart: Double
    public var trimEnd: Double?
    public var captions: CompCaptionSettings?
    public var words: [CompWord]
    /// Measure and level the audio to −14 LUFS.
    public var levelAudio: Bool
    /// A gain already measured, in dB (skips measuring).
    public var levelGain: Double?
    /// Progress share spent on analysis passes before the encode.
    var analysisShare = 0.0

    public init(job: CompJob, source: URL, output: URL) {
        self.source = source; self.output = output; preset = job.preset
        videoBitrate = job.videoBitrate; codec = job.codec
        framing = job.framing; cropPosition = job.cropPosition; trimStart = job.trimStart; trimEnd = job.trimEnd
        captions = job.hasCaptions ? job.captions : nil
        words = job.words ?? []
        levelAudio = job.levelAudio
    }

    static func audioOnly(source: URL, output: URL, start: Double, end: Double?) -> CompRequest {
        var job = CompJob(name: "", sourceFile: "", source: CompSourceInfo(duration: 0, width: 0, height: 0, hasVideo: false, hasAudio: true, bytes: 0),
                          preset: .audio, trimStart: start, trimEnd: end)
        job.levelAudio = false
        return CompRequest(job: job, source: source, output: output)
    }
}

/// One encode: Apple's hardware encoders through AVAssetReader → AVAssetWriter.
/// Crop, scale and rotation happen in a video composition; captions are drawn
/// onto each frame; audio gain is applied to each buffer.
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

    static let floatPCM: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

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

        // Analysis passes first.
        var gain: Float = 1
        if req.levelAudio, !audioTracks.isEmpty {
            var db = req.levelGain ?? 0
            if req.levelGain == nil { db = try await CompLoudness.measure(req.source, range: range).gainDB }
            gain = Float(pow(10, db / 20))
            progress(0.05)
        }
        if isCancelled { throw CancellationError() }

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
        var encodeShare = 0.95
        var encodeBase = req.levelAudio ? 0.05 : 0

        if let videoTrack {
            let (natural, transform, fps, dataRate) = try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate)
            let displayRect = CGRect(origin: .zero, size: natural).applying(transform)
            let display = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
            // Move the rotated frame back to the origin before cropping or scaling.
            let upright = transform.concatenating(CGAffineTransform(translationX: -displayRect.minX, y: -displayRect.minY))

            let render: CGSize
            var place: (Double) -> CGAffineTransform = { _ in upright }
            var keys: [CompFollow.Key] = []
            if let w = req.preset.width, let h = req.preset.height, let aspect = req.preset.aspect {
                render = CGSize(width: w, height: h)
                switch req.framing {
                case .fill, .follow:
                    place = { position in
                        let crop = CompMath.cropRect(source: display, aspect: aspect, position: position)
                        let s = render.width / crop.width
                        return upright
                            .concatenating(CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                            .concatenating(CGAffineTransform(scaleX: s, y: s))
                    }
                    if req.framing == .follow {
                        keys = await CompFollow.keyframes(source: req.source, display: display, aspect: aspect, range: range, start: req.cropPosition)
                        progress(encodeBase + 0.1)
                        encodeBase += 0.1; encodeShare -= 0.1
                    }
                case .fit:
                    let fit = CompMath.fitRect(source: display, target: render)
                    let s = fit.width / display.width
                    let t = upright
                        .concatenating(CGAffineTransform(scaleX: s, y: s))
                        .concatenating(CGAffineTransform(translationX: fit.minX, y: fit.minY))
                    place = { _ in t }
                }
            } else {
                render = CGSize(width: CompMath.even(display.width), height: CompMath.even(display.height))
            }
            if isCancelled { throw CancellationError() }

            let rate = Double(fps > 0 ? fps : 30)
            let outFPS = min(rate, req.preset.maxFrameRate > 0 ? req.preset.maxFrameRate : rate)

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: assetDuration)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            if keys.count > 1 {
                layer.setTransform(place(keys[0].position), at: .zero)
                for (a, b) in zip(keys, keys.dropFirst()) {
                    let r = CMTimeRange(start: CMTime(seconds: a.time, preferredTimescale: 600),
                                        end: CMTime(seconds: b.time, preferredTimescale: 600))
                    layer.setTransformRamp(fromStart: place(a.position), toEnd: place(b.position), timeRange: r)
                }
            } else {
                layer.setTransform(place(keys.first?.position ?? req.cropPosition), at: .zero)
            }
            instruction.layerInstructions = [layer]
            let composition = AVMutableVideoComposition()
            composition.renderSize = render
            composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(outFPS.rounded()))
            composition.instructions = [instruction]

            let captions = req.captions.flatMap { settings in
                req.words.isEmpty ? nil : CompCaptionRenderer(settings: settings, words: req.words)
            }
            let out = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack], videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: captions != nil ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            out.videoComposition = composition
            out.alwaysCopiesSampleData = false

            let bitrate = req.videoBitrate ?? max(1_500_000, Int(Double(dataRate) * 0.5))
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: outFPS,
                AVVideoMaxKeyFrameIntervalKey: Int(outFPS * 2),
            ]
            if req.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: req.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                AVVideoWidthKey: Int(render.width),
                AVVideoHeightKey: Int(render.height),
                AVVideoCompressionPropertiesKey: compression,
            ])
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(out), writer.canAdd(input) else { throw CompError.cannotWrite("Video settings were refused.") }
            reader.add(out); writer.add(input)
            let drawCaptions: ((CMSampleBuffer) -> Void)? = captions.map { renderer in
                { buffer in
                    guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
                    renderer.draw(into: pixels, at: CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
                }
            }
            pumps.append(Pump(output: out, input: input, label: "video", reportsProgress: true, transform: drawCaptions))
        }

        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: Self.floatPCM)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: req.preset.audioBitrate,
            ])
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(out), writer.canAdd(input) else { throw CompError.cannotWrite("Audio settings were refused.") }
            reader.add(out); writer.add(input)
            let g = gain
            let transform: ((CMSampleBuffer) -> Void)? = g == 1 ? nil : { buffer in Self.apply(gain: g, to: buffer) }
            // With no video, audio drives the progress bar.
            pumps.append(Pump(output: out, input: input, label: "audio", reportsProgress: pumps.isEmpty, transform: transform))
        }

        guard writer.startWriting() else { throw CompError.cannotWrite(writer.error?.localizedDescription ?? "") }
        guard reader.startReading() else { throw CompError.cannotRead(reader.error?.localizedDescription ?? "") }
        writer.startSession(atSourceTime: range.start)

        let base = encodeBase, share = encodeShare
        await withTaskGroup(of: Void.self) { group in
            for pump in pumps {
                group.addTask { [self] in
                    await pump.run(isCancelled: { self.isCancelled }) { t in
                        progress(base + share * min(1, max(0, (t - range.start.seconds) / total)))
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

    /// Multiplies float samples in place, holding them inside ±1.
    static func apply(gain: Float, to buffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
        var atOffset = 0, total = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &atOffset, totalLengthOut: &total, dataPointerOut: &pointer) == noErr,
              let pointer, atOffset == total else { return }
        pointer.withMemoryRebound(to: Float.self, capacity: total / 4) { p in
            for i in 0..<(total / 4) { p[i] = min(1, max(-1, p[i] * gain)) }
        }
    }
}

/// Moves samples from one reader output into one writer input on its own queue.
private final class Pump: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    let queue: DispatchQueue
    let reportsProgress: Bool
    let transform: ((CMSampleBuffer) -> Void)?

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput, label: String, reportsProgress: Bool, transform: ((CMSampleBuffer) -> Void)?) {
        self.output = output; self.input = input; self.reportsProgress = reportsProgress; self.transform = transform
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
                    transform?(buffer)
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
