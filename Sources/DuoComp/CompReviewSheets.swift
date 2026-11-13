import SwiftUI
import AVFoundation

/// One output-shaped still from the source.
@MainActor
enum CompFrames {
    static func still(_ job: CompJob, at time: Double, maxSide: CGFloat = 900) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: CompQueue.shared.sourceURL(job)))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide * 2, height: maxSide * 2)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image else { return nil }
        let shaped = CompCover.shape(image, job: job)
        // Previews don't need full size.
        let scale = min(1, maxSide / CGFloat(max(shaped.width, shaped.height)))
        guard scale < 1, let ctx = CGContext(data: nil, width: Int(CGFloat(shaped.width) * scale), height: Int(CGFloat(shaped.height) * scale),
                                             bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return shaped }
        ctx.interpolationQuality = .high
        ctx.draw(shaped, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        return ctx.makeImage() ?? shaped
    }
}

// MARK: - Caption review

struct CompReviewSheet: View {
    let job: CompJob
    let onDone: ([CompWord]) -> Void
    @Environment(\.dismiss) private var dismiss

    struct Line: Identifiable {
        let id = UUID()
        var text: String
        let original: String
        let words: [CompWord]
        var start: Double { words.first?.start ?? 0 }
        var end: Double { words.last?.end ?? 0 }
    }

    @State private var lines: [Line] = []
    @State private var selected: Line.ID?
    @State private var preview: CGImage?
    @FocusState private var focused: Line.ID?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                previewArea
                List {
                    Section {
                        ForEach($lines) { $line in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(CompFormat.duration(line.start))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .leading)
                                TextField("Caption", text: $line.text, axis: .vertical)
                                    .focused($focused, equals: line.id)
                            }
                            .listRowBackground(selected == line.id ? Color.accentColor.opacity(0.12) : nil)
                            .contentShape(.rect)
                            .onTapGesture { selected = line.id; focused = line.id }
                        }
                    } footer: {
                        Text("Fix any words that came out wrong. Clear a line to leave it out.")
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #endif
            }
            .navigationTitle("Check Captions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Make Video") { onDone(editedWords()); dismiss() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: focused) { _, id in if let id { selected = id } }
        .task(id: previewKey) { await renderPreview() }
    }

    private var previewArea: some View {
        ZStack {
            if let preview {
                Image(decorative: preview, scale: 1).resizable().scaledToFit()
                    .clipShape(.rect(cornerRadius: 10))
                    .transition(.opacity)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .padding(.vertical, 12)
        .accessibilityLabel("Preview of the selected caption")
    }

    private var previewKey: String {
        guard let line = lines.first(where: { $0.id == selected }) else { return "none" }
        return "\(line.id)-\(line.text)"
    }

    private func load() {
        guard lines.isEmpty, let settings = job.captions else { return }
        var s = settings
        s.style = .classic   // review a full line at a time
        lines = CompCaptionLayout.chunks(job.words ?? [], style: s.style).map { chunk in
            let text = chunk.words.map(\.text).joined(separator: " ")
            return Line(text: text, original: text, words: chunk.words)
        }
        selected = lines.first?.id
    }

    private func renderPreview() async {
        guard let line = lines.first(where: { $0.id == selected }), let settings = job.captions else { return }
        guard let still = await CompFrames.still(job, at: line.start + 0.05, maxSide: 700) else { return }
        let words = retimed(line)
        preview = CompCaptionPreview.frame(still, words: words, settings: settings) ?? still
    }

    /// Unchanged lines keep their timings; edited ones spread new words across the line's time.
    private func retimed(_ line: Line) -> [CompWord] {
        if line.text == line.original { return line.words }
        let tokens = line.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let step = max(0.05, (line.end - line.start) / Double(tokens.count))
        return tokens.enumerated().map { i, t in
            CompWord(text: t, start: line.start + Double(i) * step, end: line.start + Double(i + 1) * step)
        }
    }

    private func editedWords() -> [CompWord] { lines.flatMap(retimed) }
}

// MARK: - Cover frame

struct CompCoverSheet: View {
    let job: CompJob
    let onUse: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var time: Double = 0
    @State private var image: CGImage?

    private var range: ClosedRange<Double> {
        let end = job.trimEnd ?? job.source.duration
        return job.trimStart...max(job.trimStart + 0.1, end - 0.05)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ZStack {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                            .clipShape(.rect(cornerRadius: 12))
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Cover preview")

                VStack(spacing: 6) {
                    Slider(value: $time, in: range) { Text("Frame") }
                    Text(CompFormat.duration(time - job.trimStart))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle("Cover")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Frame") { onUse(time); dismiss() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .onAppear { time = min(max(job.defaultCoverTime, range.lowerBound), range.upperBound) }
        // Rounded so scrubbing doesn't queue a frame for every tiny move.
        .task(id: (time * 4).rounded()) {
            try? await Task.sleep(for: .milliseconds(60))
            if let still = await CompFrames.still(job, at: time, maxSide: 900) { image = still }
        }
    }
}
