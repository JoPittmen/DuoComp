import Testing
import Foundation
import AVFoundation
import CoreVideo
@testable import DuoComp

@Suite struct MathTests {
    @Test func cropWideToVerticalCentered() {
        let r = CompMath.cropRect(source: CGSize(width: 1920, height: 1080), aspect: 9.0 / 16, position: 0.5)
        #expect(abs(r.width - 607.5) < 0.01)
        #expect(r.height == 1080)
        #expect(abs(r.midX - 960) < 0.01)
    }

    @Test func cropPositionEdges() {
        let left = CompMath.cropRect(source: CGSize(width: 1920, height: 1080), aspect: 1, position: 0)
        let right = CompMath.cropRect(source: CGSize(width: 1920, height: 1080), aspect: 1, position: 1)
        #expect(left.minX == 0)
        #expect(right.maxX == 1920)
    }

    @Test func cropTallToWide() {
        let r = CompMath.cropRect(source: CGSize(width: 1080, height: 1920), aspect: 16.0 / 9, position: 0.5)
        #expect(r.width == 1080)
        #expect(abs(r.height - 607.5) < 0.01)
    }

    @Test func fitCenters() {
        let r = CompMath.fitRect(source: CGSize(width: 1920, height: 1080), target: CGSize(width: 1080, height: 1920))
        #expect(r.width == 1080)
        #expect(abs(r.midY - 960) < 0.01)
    }
}

@Suite struct AdviceTests {
    func info(_ w: Double, _ h: Double, _ d: Double) -> CompSourceInfo {
        CompSourceInfo(duration: d, width: w, height: h, hasVideo: true, hasAudio: true, bytes: 1)
    }

    @Test func sameShapeShortClipDoesNotAsk() {
        #expect(!CompAdvice(source: info(1080, 1920, 30), preset: .vertical).isWorthAsking)
    }

    @Test func iPhoneVerticalIsCloseEnough() {
        // 1080×1920 vs 1179×2556 style aspect differences under 4% don't prompt.
        #expect(!CompAdvice(source: info(1080, 1920, 30), preset: .vertical).needsReframe)
    }

    @Test func wideToVerticalAsksReframe() {
        let a = CompAdvice(source: info(1920, 1080, 30), preset: .vertical)
        #expect(a.needsReframe)
        #expect(!a.needsTrim)
    }

    @Test func longServiceAsksTrim() {
        let a = CompAdvice(source: info(1920, 1080, 4200), preset: .x)
        #expect(a.needsTrim)
        #expect(!a.needsReframe)
    }

    @Test func noLimitNoTrim() {
        #expect(!CompAdvice(source: info(1920, 1080, 4200), preset: .youTube).needsTrim)
    }

    @Test func audioOnlyNeverAsks() {
        #expect(!CompAdvice(source: info(1920, 1080, 4200), preset: .audio).isWorthAsking)
    }

    @Test func formats() {
        #expect(CompFormat.duration(4210) == "1:10:10")
        #expect(CompFormat.duration(90) == "1:30")
        #expect(CompFormat.aspect(16.0 / 9) == "16:9")
        #expect(CompFormat.aspect(9.0 / 16) == "9:16")
    }
}

@Suite(.serialized) struct EncodeTests {
    /// Writes a 1920×1080, 4-second test clip (solid frames, no third-party media).
    static func makeClip(seconds: Int = 4) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "duocomp-src-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            let buffer = pb!
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame % 255), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    @Test func encodesVerticalCropAndTrim() async throws {
        let src = try await Self.makeClip()
        let out = FileManager.default.temporaryDirectory.appending(path: "duocomp-out-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: out) }
        let info = try await CompSourceInfo.probe(src)
        var job = CompJob(name: "t", sourceFile: "", source: info, preset: .vertical)
        job.trimStart = 1; job.trimEnd = 3
        try await CompEncoder().run(CompRequest(job: job, source: src, output: out)) { _ in }
        let result = try await CompSourceInfo.probe(out)
        #expect(result.width == 1080)
        #expect(result.height == 1920)
        #expect(abs(result.duration - 2) < 0.2)
    }

    @Test func encodesFitAndHEVC() async throws {
        let src = try await Self.makeClip(seconds: 2)
        let fitOut = FileManager.default.temporaryDirectory.appending(path: "duocomp-fit-\(UUID().uuidString).mp4")
        let hevcOut = FileManager.default.temporaryDirectory.appending(path: "duocomp-hevc-\(UUID().uuidString).mp4")
        defer { [src, fitOut, hevcOut].forEach { try? FileManager.default.removeItem(at: $0) } }
        let info = try await CompSourceInfo.probe(src)
        let fit = CompJob(name: "f", sourceFile: "", source: info, preset: .square, framing: .fit)
        try await CompEncoder().run(CompRequest(job: fit, source: src, output: fitOut)) { _ in }
        let fitInfo = try await CompSourceInfo.probe(fitOut)
        #expect(fitInfo.width == 1080 && fitInfo.height == 1080)

        let hevc = CompJob(name: "h", sourceFile: "", source: info, preset: .smaller)
        try await CompEncoder().run(CompRequest(job: hevc, source: src, output: hevcOut)) { _ in }
        let hevcInfo = try await CompSourceInfo.probe(hevcOut)
        #expect(hevcInfo.width == 1920 && hevcInfo.height == 1080)
    }
}
