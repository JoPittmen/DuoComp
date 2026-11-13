import Foundation
import AVFoundation
import Vision
import ImageIO
import UniformTypeIdentifiers

// MARK: - Loudness (ITU-R BS.1770 integrated, gated)

public enum CompLoudness {
    public static let target = -14.0
    public static let peakCeiling = -1.0

    public struct Measurement: Sendable {
        public var lufs: Double
        public var peakDB: Double
        /// Gain to reach the target without the peak going over the ceiling, capped at +20 dB.
        public var gainDB: Double {
            guard lufs.isFinite else { return 0 }
            return min(target - lufs, peakCeiling - peakDB, 20)
        }
    }

    /// Two-stage K-weighting at 48 kHz.
    struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
        static var shelf: Biquad { Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285, a1: -1.69065929318241, a2: 0.73248077421585) }
        static var highPass: Biquad { Biquad(b0: 1, b1: -2, b2: 1, a1: -1.99004745483398, a2: 0.99007225036621) }
    }

    /// Integrated loudness of interleaved stereo float samples at 48 kHz.
    public static func measure(interleaved samples: [Float]) -> Measurement {
        var acc = Accumulator()
        acc.add(samples)
        return acc.result()
    }

    struct Accumulator {
        var filters = [[Biquad.shelf, Biquad.highPass], [Biquad.shelf, Biquad.highPass]]
        var sub: [Double] = []          // mean square of each 100 ms (both channels summed)
        var sum = 0.0
        var count = 0
        var peak: Float = 0
        let subLength = 4800

        mutating func add(_ samples: UnsafeBufferPointer<Float>) {
            var i = 0
            while i + 1 < samples.count {
                var e = 0.0
                for ch in 0..<2 {
                    let x = samples[i + ch]
                    peak = max(peak, abs(x))
                    var y = filters[ch][0].run(Double(x))
                    y = filters[ch][1].run(y)
                    e += y * y
                }
                sum += e; count += 1
                if count == subLength { sub.append(sum / Double(subLength)); sum = 0; count = 0 }
                i += 2
            }
        }
        mutating func add(_ samples: [Float]) { samples.withUnsafeBufferPointer { add($0) } }

        func result() -> Measurement {
            var blocks: [Double] = []
            if sub.count >= 4 {
                for i in 0...(sub.count - 4) { blocks.append((sub[i] + sub[i + 1] + sub[i + 2] + sub[i + 3]) / 4) }
            }
            func lk(_ e: Double) -> Double { -0.691 + 10 * log10(e) }
            let absGated = blocks.filter { $0 > 0 && lk($0) > -70 }
            let peakDB = peak > 0 ? 20 * log10(Double(peak)) : -.infinity
            guard !absGated.isEmpty else { return Measurement(lufs: -.infinity, peakDB: peakDB) }
            let relGate = lk(absGated.reduce(0, +) / Double(absGated.count)) - 10
            let gated = absGated.filter { lk($0) > relGate }
            return Measurement(lufs: lk(gated.reduce(0, +) / Double(gated.count)), peakDB: peakDB)
        }
    }

    /// Reads the audio of `url` in `range` once and measures it.
    public static func measure(_ url: URL, range: CMTimeRange) async throws -> Measurement {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return Measurement(lufs: -.infinity, peakDB: -.infinity) }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: CompEncoder.floatPCM)
        reader.add(out)
        reader.startReading()
        var acc = Accumulator()
        while let buffer = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { p in
                acc.add(UnsafeBufferPointer(start: p, count: length / 4))
            }
        }
        return acc.result()
    }
}

// MARK: - Following the speaker

public enum CompFollow {
    public struct Key: Sendable, Equatable { public var time: Double; public var position: Double }

    /// Crop positions over time that keep the most prominent person in frame.
    /// Smoothed: small moves are ignored, larger ones glide.
    public static func keyframes(source url: URL, display: CGSize, aspect: Double, range: CMTimeRange, start: Double) async -> [Key] {
        let horizontal = display.width / display.height > aspect
        let crop = CompMath.cropRect(source: display, aspect: aspect, position: 0.5)
        let fraction = horizontal ? crop.width / display.width : crop.height / display.height
        guard fraction < 0.999 else { return [] }

        let duration = range.duration.seconds
        let step = max(0.5, duration / 1500)
        var times: [CMTime] = []
        var t = range.start.seconds
        while t < range.end.seconds { times.append(CMTime(seconds: t, preferredTimescale: 600)); t += step }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = CMTime(seconds: step / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: step / 2, preferredTimescale: 600)

        var raw: [Key] = []
        var last = start
        for await result in generator.images(for: times) {
            let time = result.requestedTime.seconds
            guard let image = try? result.image else { raw.append(Key(time: time, position: last)); continue }
            let request = VNDetectHumanRectanglesRequest()
            request.upperBodyOnly = true
            try? VNImageRequestHandler(cgImage: image).perform([request])
            if let person = (request.results ?? []).max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
                let box = person.boundingBox
                let center = horizontal ? box.midX : 1 - box.midY   // Vision's origin is bottom-left
                let leading = center - fraction / 2
                last = min(1, max(0, leading / (1 - fraction)))
            }
            raw.append(Key(time: time, position: last))
        }
        return smooth(raw, start: start)
    }

    /// Dead zone then easing, so the frame holds still until the speaker really moves.
    static func smooth(_ raw: [Key], start: Double) -> [Key] {
        guard !raw.isEmpty else { return [] }
        var target = raw[0].position
        var current = target
        var out: [Key] = []
        for k in raw {
            if abs(k.position - target) > 0.12 { target = k.position }
            current += (target - current) * 0.35
            if out.last.map({ abs($0.position - current) > 0.004 }) ?? true {
                out.append(Key(time: k.time, position: current))
            }
        }
        if let last = raw.last, out.last?.time != last.time { out.append(Key(time: last.time, position: current)) }
        return out
    }
}

// MARK: - Cover frame

public enum CompCover {
    /// A still from the source at `time`, shaped like the output, written as JPEG.
    public static func make(source: URL, job: CompJob, time: Double, to url: URL) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        let shaped = shape(image, job: job)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CompError.cannotWrite("Couldn't create the cover image.")
        }
        CGImageDestinationAddImage(dest, shaped, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CompError.cannotWrite("Couldn't save the cover image.") }
    }

    static func shape(_ image: CGImage, job: CompJob) -> CGImage {
        let src = CGSize(width: image.width, height: image.height)
        guard let w = job.preset.width, let h = job.preset.height, let aspect = job.preset.aspect else { return image }
        let target = CGSize(width: w, height: h)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { return image }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: target))
        ctx.interpolationQuality = .high
        switch job.framing {
        case .fit:
            ctx.draw(image, in: CompMath.fitRect(source: src, target: target))
        case .fill, .follow:
            let crop = CompMath.cropRect(source: src, aspect: aspect, position: job.cropPosition)
            // CGImage crop rects are top-left based, which matches cropRect's y.
            if let cropped = image.cropping(to: crop.integral) {
                ctx.draw(cropped, in: CGRect(origin: .zero, size: target))
            }
        }
        return ctx.makeImage() ?? image
    }
}
