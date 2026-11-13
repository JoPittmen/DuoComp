import Foundation
import CoreGraphics

public enum CompCodec: String, Codable, Sendable {
    case h264, hevc, aac
}

/// What one tap on a preset makes: a file shaped and sized for where it is going.
public struct CompPreset: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let symbol: String
    /// Output frame in pixels; nil keeps the source frame.
    public let width: Int?
    public let height: Int?
    /// Video bits per second; nil derives it from the source (half its rate).
    public let videoBitrate: Int?
    public let audioBitrate: Int
    public let maxFrameRate: Double
    public let codec: CompCodec
    /// The platform's longest allowed video, in seconds; nil means no limit worth asking about.
    public let maxDuration: Double?

    public var isAudioOnly: Bool { codec == .aac }
    public var aspect: Double? {
        guard let width, let height else { return nil }
        return Double(width) / Double(height)
    }
    public var fileExtension: String { isAudioOnly ? "m4a" : "mp4" }

    public static let vertical = CompPreset(
        id: "vertical", title: "Reels, TikTok, Shorts", detail: "9:16 · 1080×1920 · H.264", symbol: "rectangle.portrait",
        width: 1080, height: 1920, videoBitrate: 8_000_000, audioBitrate: 128_000, maxFrameRate: 30, codec: .h264, maxDuration: 180)
    public static let feed = CompPreset(
        id: "feed", title: "Instagram Feed", detail: "4:5 · 1080×1350 · H.264", symbol: "rectangle.portrait.on.rectangle.portrait",
        width: 1080, height: 1350, videoBitrate: 6_000_000, audioBitrate: 128_000, maxFrameRate: 30, codec: .h264, maxDuration: nil)
    public static let square = CompPreset(
        id: "square", title: "Square", detail: "1:1 · 1080×1080 · H.264", symbol: "square",
        width: 1080, height: 1080, videoBitrate: 6_000_000, audioBitrate: 128_000, maxFrameRate: 30, codec: .h264, maxDuration: nil)
    public static let youTube = CompPreset(
        id: "youtube", title: "YouTube, Facebook", detail: "16:9 · 1920×1080 · H.264", symbol: "rectangle",
        width: 1920, height: 1080, videoBitrate: 10_000_000, audioBitrate: 192_000, maxFrameRate: 60, codec: .h264, maxDuration: nil)
    public static let x = CompPreset(
        id: "x", title: "X", detail: "16:9 · 1280×720 · H.264", symbol: "rectangle.compress.vertical",
        width: 1280, height: 720, videoBitrate: 5_000_000, audioBitrate: 128_000, maxFrameRate: 30, codec: .h264, maxDuration: 140)
    public static let smaller = CompPreset(
        id: "smaller", title: "Smaller File", detail: "Same frame · HEVC · about half the size", symbol: "arrow.down.right.and.arrow.up.left",
        width: nil, height: nil, videoBitrate: nil, audioBitrate: 128_000, maxFrameRate: 60, codec: .hevc, maxDuration: nil)
    public static let audio = CompPreset(
        id: "audio", title: "Audio Only", detail: "AAC · 192 kbps · .m4a", symbol: "waveform",
        width: nil, height: nil, videoBitrate: nil, audioBitrate: 192_000, maxFrameRate: 0, codec: .aac, maxDuration: nil)

    public static let all: [CompPreset] = [vertical, feed, square, youTube, x, smaller, audio]
    public static func named(_ id: String) -> CompPreset { all.first { $0.id == id } ?? vertical }
}

public enum CompFraming: String, Codable, Sendable, CaseIterable {
    /// Crop to fill the preset's frame.
    case fill
    /// Scale to fit inside it, with black bars.
    case fit
    /// Crop to fill, moving the crop to keep the speaker in frame.
    case follow
}

public enum CompCaptionStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case classic, bold, highlight, minimal
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .classic: "Classic"
        case .bold: "Bold"
        case .highlight: "Highlight"
        case .minimal: "Minimal"
        }
    }
    /// Most words shown at once.
    var maxWords: Int {
        switch self {
        case .classic: 12
        case .bold: 3
        case .highlight: 5
        case .minimal: 10
        }
    }
}

public enum CompCaptionPlacement: String, Codable, Sendable, CaseIterable, Identifiable {
    case top, middle, bottom
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public struct CompCaptionSettings: Codable, Equatable, Sendable {
    public var style: CompCaptionStyle = .highlight
    public var placement: CompCaptionPlacement = .bottom
    /// Accent as RGB 0…1 (Highlight's spoken word, Classic's band edge).
    public var accent: [Double] = [1.0, 0.84, 0.04]
    public init() {}

    public static let accents: [(name: String, rgb: [Double])] = [
        ("Yellow", [1.0, 0.84, 0.04]), ("Green", [0.2, 0.84, 0.29]), ("Blue", [0.25, 0.6, 1.0]),
        ("Pink", [1.0, 0.33, 0.6]), ("White", [1, 1, 1]),
    ]
}

/// One spoken word, in source-file seconds.
public struct CompWord: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

public enum CompMath {
    /// The part of a `source` frame kept when cropping to `aspect`. `position` (0…1)
    /// slides the crop along whichever axis has room to spare; 0.5 is centered.
    public static func cropRect(source: CGSize, aspect: Double, position: Double) -> CGRect {
        let p = min(max(position, 0), 1)
        let sourceAspect = source.width / source.height
        if sourceAspect > aspect {
            let w = source.height * aspect
            return CGRect(x: (source.width - w) * p, y: 0, width: w, height: source.height)
        } else {
            let h = source.width / aspect
            return CGRect(x: 0, y: (source.height - h) * p, width: source.width, height: h)
        }
    }

    /// Frame for "fit with bars": the source scaled into `target`, centered.
    public static func fitRect(source: CGSize, target: CGSize) -> CGRect {
        let s = min(target.width / source.width, target.height / source.height)
        let w = source.width * s, h = source.height * s
        return CGRect(x: (target.width - w) / 2, y: (target.height - h) / 2, width: w, height: h)
    }

    /// Video encoders want even dimensions.
    public static func even(_ v: CGFloat) -> Int { max(2, Int(v.rounded()) / 2 * 2) }
}

/// Whether adding a file to a preset is worth a question first.
public struct CompAdvice: Equatable, Sendable {
    public var sourceAspect: Double?
    public var targetAspect: Double?
    public var duration: Double
    public var maxDuration: Double?

    /// Shapes differ by more than 4%: a crop or bars will be visible.
    public var needsReframe: Bool {
        guard let s = sourceAspect, let t = targetAspect, s > 0, t > 0 else { return false }
        return abs(s / t - 1) > 0.04
    }
    /// Longer than the platform allows (with a second of slack).
    public var needsTrim: Bool {
        guard let maxDuration else { return false }
        return duration > maxDuration + 1
    }
    public var isWorthAsking: Bool { needsReframe || needsTrim }

    public init(source: CompSourceInfo, preset: CompPreset) {
        sourceAspect = source.hasVideo && !preset.isAudioOnly ? source.aspect : nil
        targetAspect = preset.aspect
        duration = source.duration
        maxDuration = preset.isAudioOnly ? nil : preset.maxDuration
    }
}

public enum CompFormat {
    /// "1:05", "42:10", "1:02:03".
    public static func duration(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded()))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "16:9", "9:16", "4:3", or "1.85:1" when no small ratio is close.
    public static func aspect(_ a: Double) -> String {
        let known: [(Int, Int)] = [(16, 9), (9, 16), (4, 3), (3, 4), (1, 1), (4, 5), (5, 4), (21, 9), (3, 2), (2, 3)]
        if let k = known.first(where: { abs(Double($0.0) / Double($0.1) / a - 1) < 0.02 }) { return "\(k.0):\(k.1)" }
        return String(format: "%.2f:1", a)
    }

    public static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}
