import SwiftUI

/// Choices made once for every file added together.
public struct CompBatchOptions: Sendable {
    public var presets: [CompPreset]
    public var captions: CompCaptionSettings?
    public var levelAudio: Bool
    public var compressorRatio = 0.8
    public var compressorEfficient = false
}

struct CompPresetPicker: View {
    let count: Int
    let onChoose: (CompBatchOptions) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable private var queue = CompQueue.shared
    @State private var selected: Set<String> = []

    init(count: Int, onChoose: @escaping (CompBatchOptions) -> Void) {
        self.count = count
        self.onChoose = onChoose
        _selected = State(initialValue: Set(CompQueue.shared.lastPresetIDs))
    }

    private var chosen: [CompPreset] { CompPreset.all.filter { selected.contains($0.id) } }
    private var anyVideo: Bool { chosen.contains { !$0.isAudioOnly } }
    private var jobCount: Int { chosen.count * count }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(CompPreset.all) { preset in
                        presetRow(preset)
                    }
                } header: {
                    Text("Make Versions For")
                } footer: {
                    Text("Choose one or more. Each makes its own file.")
                }

                if selected.contains(CompPreset.custom.id) {
                    Section {
                        Picker("Quality", selection: $queue.compressorEfficient) {
                            Text("Standard").tag(false)
                            Text("Efficient").tag(true)
                        }
                        .pickerStyle(.segmented)
                        VStack(alignment: .leading) {
                            Text("Compression Ratio (\(Int((queue.compressorRatio * 100).rounded()))%)")
                            Slider(value: $queue.compressorRatio, in: 0.1...1) { Text("Compression Ratio") }
                        }
                        Button("Reset", role: .cancel) { queue.compressorRatio = 0.8; queue.compressorEfficient = false }
                    } header: {
                        Text("Compressor")
                    } footer: {
                        Text("Each file's output aims for this share of its own size. Efficient (HEVC) looks better at the same size but some older players can't open it. You'll see each file's size estimate next.")
                    }
                }
                if anyVideo {
                    CompVideoOptionSections(queue: queue)
                }
            }
            .formStyle(.grouped)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1), value: queue.captionsOn)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1), value: anyVideo)
            .navigationTitle(count > 1 ? "\(count) Files" : "Compress")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(jobCount > 1 ? "Add \(jobCount)" : "Add") {
                        queue.lastPresetIDs = chosen.map(\.id)
                        onChoose(CompBatchOptions(presets: chosen,
                                                  captions: queue.captionsOn ? queue.captionSettings : nil,
                                                  levelAudio: queue.levelAudio,
                                                  compressorRatio: queue.compressorRatio,
                                                  compressorEfficient: queue.compressorEfficient))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty)
                }
            }
        }
    }

    private func presetRow(_ preset: CompPreset) -> some View {
        let on = selected.contains(preset.id)
        return Button {
            if on { selected.remove(preset.id) } else { selected.insert(preset.id) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: preset.symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.title).foregroundStyle(.primary)
                    Text(preset.detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: on)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Captions and Level Audio: shown when adding files and in Settings, so the
/// defaults can be set without adding a video first.
struct CompVideoOptionSections: View {
    @Bindable var queue: CompQueue

    var body: some View {
        captionsSection
        Section {
            Toggle("Level Audio", isOn: $queue.levelAudio)
        } footer: {
            Text("Brings the sound to the loudness Instagram, TikTok and YouTube expect, without clipping.")
        }
    }

    private var captionsSection: some View {
        Section {
            Toggle("Captions", isOn: $queue.captionsOn)
            if queue.captionsOn {
                CompCaptionStylePicker(settings: $queue.captionSettings)
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                Picker("Position", selection: $queue.captionSettings.placement) {
                    ForEach(CompCaptionPlacement.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                accentPicker
            }
        } footer: {
            if queue.captionsOn {
                Text("Words are found on this device, then you check them before the video is made.")
            }
        }
    }

    private var accentPicker: some View {
        LabeledContent("Accent") {
            HStack(spacing: 10) {
                ForEach(CompCaptionSettings.accents, id: \.name) { accent in
                    let on = queue.captionSettings.accent == accent.rgb
                    Button {
                        queue.captionSettings.accent = accent.rgb
                    } label: {
                        Circle()
                            .fill(Color(red: accent.rgb[0], green: accent.rgb[1], blue: accent.rgb[2]))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(.primary.opacity(on ? 0.9 : 0.15), lineWidth: on ? 2.5 : 1))
                            .frame(width: 44, height: 44)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accent.name)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }
}

/// Horizontally scrolling style cards, each a real render of that style.
struct CompCaptionStylePicker: View {
    @Binding var settings: CompCaptionSettings

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(CompCaptionStyle.allCases) { style in
                    let on = settings.style == style
                    Button {
                        settings.style = style
                    } label: {
                        VStack(spacing: 6) {
                            CompCaptionSample(settings: { var s = settings; s.style = style; return s }())
                                .frame(width: 92, height: 140)
                                .clipShape(.rect(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? Color.accentColor : .clear, lineWidth: 3))
                                .scaleEffect(on ? 1 : 0.96)
                            Text(style.title)
                                .font(.footnote.weight(on ? .semibold : .regular))
                                .foregroundStyle(on ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(style.title) captions")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .animation(.spring(response: 0.3, dampingFraction: 1), value: settings.style)
        }
        .sensoryFeedback(.selection, trigger: settings.style)
    }
}

/// A sample frame rendered with the real caption renderer.
struct CompCaptionSample: View {
    let settings: CompCaptionSettings
    var body: some View {
        if let image = CompCaptionPreview.sample(settings: settings) {
            Image(decorative: image, scale: 1).resizable().scaledToFill()
        } else {
            Color.gray
        }
    }
}

enum CompCaptionPreview {
    static let sampleWords: [CompWord] = ["Grace", "changes", "everything"].enumerated().map {
        CompWord(text: $0.element, start: Double($0.offset) * 0.4, end: Double($0.offset) * 0.4 + 0.35)
    }

    static func sample(settings: CompCaptionSettings) -> CGImage? {
        let size = CGSize(width: 270, height: 420)
        guard let ctx = context(size) else { return nil }
        let colors = [CGColor(srgbRed: 0.18, green: 0.24, blue: 0.36, alpha: 1), CGColor(srgbRed: 0.42, green: 0.3, blue: 0.36, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
        draw(words: sampleWords, active: 1, settings: settings, in: ctx, size: size)
        return ctx.makeImage()
    }

    /// `frame` (already shaped like the output) with one line of captions on it.
    static func frame(_ frame: CGImage, words: [CompWord], settings: CompCaptionSettings) -> CGImage? {
        let size = CGSize(width: frame.width, height: frame.height)
        guard let ctx = context(size) else { return nil }
        ctx.draw(frame, in: CGRect(origin: .zero, size: size))
        draw(words: words, active: 0, settings: settings, in: ctx, size: size)
        return ctx.makeImage()
    }

    private static func draw(words: [CompWord], active: Int, settings: CompCaptionSettings, in ctx: CGContext, size: CGSize) {
        guard !words.isEmpty else { return }
        let renderer = CompCaptionRenderer(settings: settings, words: words)
        let chunk = CompCaptionChunk(words: words, start: words[0].start, end: words.last!.end)
        renderer.render(chunk: chunk, key: UUID().uuidString, active: settings.style == .highlight ? active : -1, in: ctx, size: size)
    }

    private static func context(_ size: CGSize) -> CGContext? {
        CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }
}
