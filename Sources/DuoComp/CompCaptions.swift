import Foundation
import Speech
import CoreText
import CoreGraphics
#if canImport(UIKit)
import UIKit
private typealias PlatformFont = UIFont
#else
import AppKit
private typealias PlatformFont = NSFont
#endif

// MARK: - Speech to words (on device)

public enum CompTranscriber {
    public enum Failure: LocalizedError {
        case notAllowed, unavailable, nothingHeard
        public var errorDescription: String? {
            switch self {
            case .notAllowed: "Captions need Speech Recognition. Turn it on for Duo Control in Settings."
            case .unavailable: "Speech recognition isn't available for this language on this device."
            case .nothingHeard: "No speech was found in this video."
            }
        }
    }

    public static func authorize() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return true }
        if status != .notDetermined { return false }
        return await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    /// Words spoken in `source` between `start` and `end`, in source seconds.
    public static func words(in source: URL, start: Double, end: Double?) async throws -> [CompWord] {
        guard await authorize() else { throw Failure.notAllowed }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else { throw Failure.unavailable }

        // Recognition reads audio files: pull the trimmed audio out first.
        let audio = FileManager.default.temporaryDirectory.appending(path: "duocomp-speech-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audio) }
        var req = CompRequest.audioOnly(source: source, output: audio, start: start, end: end)
        req.levelGain = nil
        try await CompEncoder().run(req) { _ in }

        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let segments: [SFTranscriptionSegment] = try await withCheckedThrowingContinuation { c in
            var finished = false
            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    c.resume(returning: result.bestTranscription.segments)
                    _ = task
                } else if let error {
                    finished = true
                    // "No speech detected" arrives as an error.
                    c.resume(returning: [])
                    _ = error
                }
            }
        }
        let words = segments.map {
            CompWord(text: $0.substring, start: start + $0.timestamp, end: start + $0.timestamp + max($0.duration, 0.1))
        }
        guard !words.isEmpty else { throw Failure.nothingHeard }
        return words
    }
}

// MARK: - Grouping words into what's on screen at once

public struct CompCaptionChunk: Equatable, Sendable {
    public var words: [CompWord]
    public var start: Double
    public var end: Double
}

public enum CompCaptionLayout {
    public static func chunks(_ words: [CompWord], style: CompCaptionStyle) -> [CompCaptionChunk] {
        var groups: [[CompWord]] = []
        var current: [CompWord] = []
        for w in words where !w.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if let last = current.last {
                let gap = w.start - last.end
                let sentenceEnded = last.text.last.map { ".?!".contains($0) } ?? false
                if current.count >= style.maxWords || gap > 0.8 || (sentenceEnded && current.count >= 2) {
                    groups.append(current); current = []
                }
            }
            current.append(w)
        }
        if !current.isEmpty { groups.append(current) }

        var chunks: [CompCaptionChunk] = []
        for (i, g) in groups.enumerated() {
            let nextStart = i + 1 < groups.count ? groups[i + 1][0].start : .infinity
            chunks.append(CompCaptionChunk(words: g, start: g[0].start, end: min(g.last!.end + 0.4, nextStart)))
        }
        return chunks
    }
}

// MARK: - Drawing onto frames

/// Draws captions into BGRA frames during the encode. Used from one queue only.
final class CompCaptionRenderer: @unchecked Sendable {
    let settings: CompCaptionSettings
    let chunks: [CompCaptionChunk]
    private var cache: [String: (CTFrame, CTFrame?, CGRect)] = [:]
    private var cursor = 0

    init(settings: CompCaptionSettings, words: [CompWord]) {
        self.settings = settings
        chunks = CompCaptionLayout.chunks(words, style: settings.style)
    }

    private func chunkIndex(at t: Double) -> Int? {
        if cursor < chunks.count, chunks[cursor].start <= t, t < chunks[cursor].end { return cursor }
        guard let i = chunks.firstIndex(where: { $0.start <= t && t < $0.end }) else { return nil }
        cursor = i
        return i
    }

    func draw(into buffer: CVPixelBuffer, at t: Double) {
        guard let ci = chunkIndex(at: t) else { return }
        let chunk = chunks[ci]
        let active = settings.style == .highlight ? chunk.words.lastIndex(where: { $0.start <= t }) ?? 0 : -1

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        render(chunk: chunk, key: "\(ci)-\(active)", active: active, in: ctx, size: CGSize(width: w, height: h))
    }

    /// Also used for the in-app preview.
    func render(chunk: CompCaptionChunk, key: String, active: Int, in ctx: CGContext, size: CGSize) {
        let (fill, stroke, band) = cached(key: key) { layout(chunk: chunk, active: active, size: size) }
        if settings.style == .classic {
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
            ctx.addPath(CGPath(roundedRect: band, cornerWidth: band.height * 0.18, cornerHeight: band.height * 0.18, transform: nil))
            ctx.fillPath()
        }
        if settings.style == .highlight || settings.style == .minimal {
            ctx.setShadow(offset: CGSize(width: 0, height: -size.height * 0.002), blur: size.height * 0.006,
                          color: CGColor(gray: 0, alpha: 0.75))
        }
        ctx.textMatrix = .identity
        if let stroke { CTFrameDraw(stroke, ctx) }
        CTFrameDraw(fill, ctx)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }

    private func cached(key: String, make: () -> (CTFrame, CTFrame?, CGRect)) -> (CTFrame, CTFrame?, CGRect) {
        if let hit = cache[key] { return hit }
        let v = make()
        if cache.count > 400 { cache.removeAll() }
        cache[key] = v
        return v
    }

    private func layout(chunk: CompCaptionChunk, active: Int, size: CGSize) -> (CTFrame, CTFrame?, CGRect) {
        let base = min(size.width, size.height)
        let (scale, weight): (CGFloat, PlatformFont.Weight) = switch settings.style {
        case .classic: (0.055, .semibold)
        case .bold: (0.09, .heavy)
        case .highlight: (0.072, .bold)
        case .minimal: (0.042, .medium)
        }
        let font = PlatformFont.systemFont(ofSize: base * scale, weight: weight) as CTFont
        let white = CGColor(gray: 1, alpha: 1)
        let accent = CGColor(srgbRed: settings.accent[0], green: settings.accent[1], blue: settings.accent[2], alpha: 1)

        let text = chunk.words.map(\.text).joined(separator: " ")
        let display = settings.style == .bold ? text.uppercased() : text
        let para: CTParagraphStyle = {
            var align = CTTextAlignment.center
            return withUnsafePointer(to: &align) { p in
                CTParagraphStyleCreate([CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: p)], 1)
            }
        }()
        func attributed(color: CGColor, strokeWidth: CGFloat?) -> CFAttributedString {
            let s = NSMutableAttributedString(string: display, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): para,
            ])
            if let strokeWidth {
                s.addAttributes([NSAttributedString.Key(kCTStrokeWidthAttributeName as String): strokeWidth,
                                 NSAttributedString.Key(kCTStrokeColorAttributeName as String): CGColor(gray: 0, alpha: 1)],
                                range: NSRange(location: 0, length: s.length))
            } else if active >= 0, active < chunk.words.count {
                var loc = 0
                for (i, w) in chunk.words.enumerated() {
                    let len = (w.text as NSString).length
                    if i == active {
                        s.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: accent,
                                       range: NSRange(location: loc, length: len))
                    }
                    loc += len + 1
                }
            }
            return s
        }

        let maxWidth = size.width * 0.84
        let fillString = attributed(color: white, strokeWidth: nil)
        let setter = CTFramesetterCreateWithAttributedString(fillString)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
                                                               CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let textSize = CGSize(width: ceil(fit.width) + 2, height: ceil(fit.height) + 2)
        let centerFromTop: CGFloat = switch settings.placement {
        case .top: 0.2
        case .middle: 0.5
        case .bottom: size.height > size.width ? 0.72 : 0.84
        }
        let cy = size.height * (1 - centerFromTop)   // CoreGraphics origin is bottom-left
        let rect = CGRect(x: (size.width - textSize.width) / 2, y: cy - textSize.height / 2,
                          width: textSize.width, height: textSize.height)
        let fillFrame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: rect, transform: nil), nil)

        var strokeFrame: CTFrame?
        if settings.style == .bold {
            let strokeSetter = CTFramesetterCreateWithAttributedString(attributed(color: white, strokeWidth: 14))
            strokeFrame = CTFramesetterCreateFrame(strokeSetter, CFRange(), CGPath(rect: rect, transform: nil), nil)
        }
        let pad = base * scale * 0.45
        return (fillFrame, strokeFrame, rect.insetBy(dx: -pad, dy: -pad * 0.6))
    }
}
