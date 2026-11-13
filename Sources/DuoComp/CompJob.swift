import Foundation
import AVFoundation
import CoreGraphics

/// What the app learned about a file when it was added.
public struct CompSourceInfo: Codable, Equatable, Sendable {
    public var duration: Double
    /// Display size (rotation applied); zero when there is no video.
    public var width: Double
    public var height: Double
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var bytes: Int64

    public var size: CGSize { CGSize(width: width, height: height) }
    public var aspect: Double? { hasVideo && height > 0 ? width / height : nil }

    public init(duration: Double, width: Double, height: Double, hasVideo: Bool, hasAudio: Bool, bytes: Int64) {
        self.duration = duration; self.width = width; self.height = height
        self.hasVideo = hasVideo; self.hasAudio = hasAudio; self.bytes = bytes
    }

    public static func probe(_ url: URL) async throws -> CompSourceInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        var size = CGSize.zero
        if let video {
            let (natural, transform) = try await video.load(.naturalSize, .preferredTransform)
            let r = CGRect(origin: .zero, size: natural).applying(transform)
            size = CGSize(width: abs(r.width), height: abs(r.height))
        }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        return CompSourceInfo(duration: duration.isFinite ? duration : 0, width: size.width, height: size.height,
                              hasVideo: video != nil, hasAudio: audio != nil, bytes: bytes)
    }
}

public struct CompJob: Identifiable, Codable, Equatable, Sendable {
    public enum State: Codable, Equatable, Sendable {
        case waiting
        case encoding
        case done
        case failed(String)
        case cancelled
    }

    public let id: UUID
    /// The name people recognize (the original file name, without extension).
    public var name: String
    /// File name inside the app's Sources folder (the queue's own copy).
    public var sourceFile: String
    public var source: CompSourceInfo
    public var presetID: String
    public var framing: CompFraming
    /// Crop position along the axis with room to spare; 0.5 is centered.
    public var cropPosition: Double
    public var trimStart: Double
    /// nil = to the end.
    public var trimEnd: Double?
    public var state: State
    public var progress: Double
    /// File name inside Documents/DuoComp once done.
    public var outputFile: String?
    public var outputBytes: Int64?
    public let added: Date

    public var preset: CompPreset { CompPreset.named(presetID) }
    public var outputDuration: Double { (trimEnd ?? source.duration) - trimStart }

    public init(name: String, sourceFile: String, source: CompSourceInfo, preset: CompPreset,
                framing: CompFraming = .fill, cropPosition: Double = 0.5, trimStart: Double = 0, trimEnd: Double? = nil) {
        id = UUID()
        self.name = name; self.sourceFile = sourceFile; self.source = source; presetID = preset.id
        self.framing = framing; self.cropPosition = cropPosition; self.trimStart = trimStart; self.trimEnd = trimEnd
        state = .waiting; progress = 0; added = Date()
    }

    /// Rough output size, for the row before encoding finishes.
    public var estimatedBytes: Int64 {
        let p = preset
        let video: Double
        if p.isAudioOnly { video = 0 }
        else if let rate = p.videoBitrate { video = Double(rate) }
        else { video = source.duration > 0 ? Double(source.bytes) * 8 / source.duration * 0.5 : 0 }
        return Int64((video + Double(p.audioBitrate)) / 8 * outputDuration)
    }

    /// "−91%" once done.
    public var savedPercent: Int? {
        guard let out = outputBytes, source.bytes > 0 else { return nil }
        return Int((1 - Double(out) / Double(source.bytes)) * 100)
    }
}
