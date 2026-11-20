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
        /// Captions on: turning speech into words.
        case transcribing
        /// Captions ready for a look before encoding.
        case needsReview
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
    /// Burned-in captions; nil = off.
    public var captions: CompCaptionSettings?
    public var words: [CompWord]?
    /// Bring audio to −14 LUFS. Optional so queues saved by v1 still load (nil = on for video).
    public var levelAudioSetting: Bool?
    /// Cover frame time in source seconds; nil = a tenth of the way in.
    public var coverTime: Double?
    /// Compressor preset: output size as a share of the original (nil = 0.8), and HEVC ("Efficient") or H.264.
    public var targetRatio: Double?
    public var efficient: Bool?
    /// JPEG next to the output, once made.
    public var coverFile: String?

    /// Still moving through the queue (not done, failed or cancelled).
    public var isActive: Bool {
        switch state {
        case .waiting, .transcribing, .needsReview, .encoding: true
        case .done, .failed, .cancelled: false
        }
    }

    public var levelAudio: Bool {
        get { levelAudioSetting ?? !preset.isAudioOnly }
        set { levelAudioSetting = newValue }
    }
    public var defaultCoverTime: Double { coverTime ?? (trimStart + outputDuration * 0.1) }
    public var hasCaptions: Bool { captions != nil && !preset.isAudioOnly && source.hasVideo }

    public var preset: CompPreset { CompPreset.named(presetID) }
    public var outputDuration: Double { (trimEnd ?? source.duration) - trimStart }

    public init(name: String, sourceFile: String, source: CompSourceInfo, preset: CompPreset,
                framing: CompFraming = .fill, cropPosition: Double = 0.5, trimStart: Double = 0, trimEnd: Double? = nil) {
        id = UUID()
        self.name = name; self.sourceFile = sourceFile; self.source = source; presetID = preset.id
        self.framing = framing; self.cropPosition = cropPosition; self.trimStart = trimStart; self.trimEnd = trimEnd
        state = .waiting; progress = 0; added = Date()
    }

    public var ratio: Double { min(max(targetRatio ?? 0.8, 0.05), 1) }
    /// The file's overall bits per second.
    public var sourceBitrate: Double { source.duration > 0 ? Double(source.bytes) * 8 / source.duration : 0 }
    /// Compressor: the video rate that lands on the chosen share of the original size.
    public var customVideoBitrate: Int { max(300_000, Int(sourceBitrate * ratio) - preset.audioBitrate) }
    public var videoBitrate: Int? { preset.isCustom && source.hasVideo ? customVideoBitrate : preset.videoBitrate }
    public var codec: CompCodec { preset.isCustom && (efficient ?? false) ? .hevc : preset.codec }

    /// Rough output size, for the row before encoding finishes.
    public var estimatedBytes: Int64 {
        let p = preset
        let video: Double
        if p.isAudioOnly { video = 0 }
        else if let rate = videoBitrate { video = Double(rate) }
        else { video = source.duration > 0 ? Double(source.bytes) * 8 / source.duration * 0.5 : 0 }
        return Int64((video + Double(p.audioBitrate)) / 8 * outputDuration)
    }

    /// "−91%" once done.
    public var savedPercent: Int? {
        guard let out = outputBytes, source.bytes > 0 else { return nil }
        return Int((1 - Double(out) / Double(source.bytes)) * 100)
    }
}
