import SwiftUI
import AVFoundation

/// First-second frame of a video, cached in memory.
@MainActor
enum CompThumbnails {
    private static var cache: [URL: CGImage] = [:]

    static func image(for url: URL, maxSide: CGFloat = 600) async -> CGImage? {
        if let hit = cache[url] { return hit }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        let image = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        if let image { cache[url] = image }
        return image
    }
}

struct CompThumbnailView: View {
    let url: URL
    let isAudio: Bool
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: isAudio ? "waveform" : "film")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(.rect(cornerRadius: 8))
        .task(id: url) { if !isAudio { image = await CompThumbnails.image(for: url, maxSide: 200) } }
        .accessibilityHidden(true)
    }
}
