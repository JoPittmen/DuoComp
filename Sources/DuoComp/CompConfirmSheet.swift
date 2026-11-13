import SwiftUI

/// A file waiting on the reframe/trim question before it joins the queue.
public struct CompPending: Identifiable {
    public let id = UUID()
    public var job: CompJob
    public var advice: CompAdvice
}

/// Shown only when the app judges it worth asking: the shape differs from the
/// preset's, or the file runs longer than the platform allows.
struct CompConfirmSheet: View {
    @State var pending: CompPending
    /// Position in a batch, for the title ("2 of 3").
    let index: Int
    let count: Int
    let onAdd: (CompJob) -> Void
    let onSkip: () -> Void

    enum TrimChoice: Hashable { case first, range, full }
    @State private var trimChoice: TrimChoice = .first
    @State private var thumbnail: CGImage?

    private var job: CompJob { pending.job }
    private var preset: CompPreset { job.preset }
    private var limit: Double { pending.advice.maxDuration ?? job.source.duration }

    var body: some View {
        NavigationStack {
            Form {
                if pending.advice.needsReframe { reframeSection }
                if pending.advice.needsTrim { trimSection }
            }
            .formStyle(.grouped)
            .navigationTitle(count > 1 ? "\(job.name) (\(index) of \(count))" : job.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(count > 1 ? "Skip" : "Cancel", role: .cancel, action: onSkip)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to Queue") { onAdd(finalJob) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .task {
            thumbnail = await CompThumbnails.image(for: CompStore.sources.appending(path: job.sourceFile))
        }
        .onAppear { applyTrimChoice(.first) }
    }

    // MARK: Reframe

    private var reframeSection: some View {
        Section {
            CompReframePreview(image: thumbnail,
                               sourceAspect: pending.advice.sourceAspect ?? 16.0 / 9,
                               targetAspect: pending.advice.targetAspect ?? 9.0 / 16,
                               framing: pending.job.framing,
                               position: $pending.job.cropPosition)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            Picker("Reframe", selection: $pending.job.framing) {
                Text("Crop to Fill").tag(CompFraming.fill)
                Text("Fit with Bars").tag(CompFraming.fit)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } header: {
            Text("Reframe")
        } footer: {
            Text(reframeFooter)
        }
    }

    private var reframeFooter: String {
        let from = pending.advice.sourceAspect.map(CompFormat.aspect) ?? "This video"
        let to = pending.advice.targetAspect.map(CompFormat.aspect) ?? ""
        let shape = "This video is \(from). \(preset.title) is \(to)."
        return job.framing == .fill
            ? "\(shape) Drag the picture to choose what stays in the frame."
            : "\(shape) The whole picture is kept, with black bars."
    }

    // MARK: Trim

    private var trimSection: some View {
        Section {
            Picker("Length", selection: Binding(get: { trimChoice }, set: applyTrimChoice)) {
                Text("Use First \(CompFormat.duration(limit))").tag(TrimChoice.first)
                Text("Choose Range").tag(TrimChoice.range)
                Text("Keep Full Length").tag(TrimChoice.full)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if trimChoice == .range {
                rangeControls
            }
        } header: {
            Text("Trim")
        } footer: {
            Text(trimFooter)
        }
    }

    private var rangeControls: some View {
        let total = job.source.duration
        let start = Binding<Double>(
            get: { pending.job.trimStart },
            set: { v in
                pending.job.trimStart = min(v, (pending.job.trimEnd ?? total) - 1)
            })
        let end = Binding<Double>(
            get: { pending.job.trimEnd ?? total },
            set: { v in
                pending.job.trimEnd = max(v, pending.job.trimStart + 1)
            })
        return Group {
            LabeledContent("Start") {
                Slider(value: start, in: 0...total) { Text("Start") }
                Text(CompFormat.duration(start.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 56, alignment: .trailing)
            }
            LabeledContent("End") {
                Slider(value: end, in: 0...total) { Text("End") }
                Text(CompFormat.duration(end.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 56, alignment: .trailing)
            }
        }
    }

    private var trimFooter: String {
        let base = "This video is \(CompFormat.duration(job.source.duration)). \(preset.title) allows up to \(CompFormat.duration(limit))."
        switch trimChoice {
        case .first: return "\(base) The rest is left out."
        case .range:
            let length = job.outputDuration
            return length > limit + 1
                ? "\(base) The range you chose is \(CompFormat.duration(length)), so the upload may be refused."
                : "\(base) New length: \(CompFormat.duration(length))."
        case .full: return "\(base) A full-length file may be refused when you upload it."
        }
    }

    private func applyTrimChoice(_ choice: TrimChoice) {
        guard pending.advice.needsTrim else { return }
        trimChoice = choice
        switch choice {
        case .first:
            pending.job.trimStart = 0
            pending.job.trimEnd = limit
        case .range:
            if pending.job.trimEnd == nil { pending.job.trimEnd = limit }
        case .full:
            pending.job.trimStart = 0
            pending.job.trimEnd = nil
        }
    }

    private var finalJob: CompJob {
        var j = pending.job
        if !pending.advice.needsReframe { j.framing = .fill; j.cropPosition = 0.5 }
        return j
    }
}

/// The result frame: the picture inside the preset's shape. In Fill, drag to pan
/// (1:1 with the finger, rubber-banding at the edges, settling with a spring).
struct CompReframePreview: View {
    let image: CGImage?
    let sourceAspect: Double
    let targetAspect: Double
    let framing: CompFraming
    @Binding var position: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var dragging = false
    @State private var dragStart: Double?
    /// Live offset while dragging, in points, including rubber-band overshoot.
    @State private var liveOffset: CGFloat?

    private let maxSide: CGFloat = 280

    private var box: CGSize {
        targetAspect >= 1
            ? CGSize(width: maxSide, height: maxSide / targetAspect)
            : CGSize(width: maxSide * targetAspect, height: maxSide)
    }

    /// Picture size when filling the box.
    private var filled: CGSize {
        let b = box
        return sourceAspect > targetAspect
            ? CGSize(width: b.height * sourceAspect, height: b.height)
            : CGSize(width: b.width, height: b.width / sourceAspect)
    }
    private var horizontal: Bool { sourceAspect > targetAspect }
    private var overflow: CGFloat { horizontal ? filled.width - box.width : filled.height - box.height }

    private func offset(for p: Double) -> CGFloat { (0.5 - p) * overflow }

    var body: some View {
        ZStack {
            Color.black
            picture
        }
        .frame(width: box.width, height: box.height)
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            if framing == .fill {
                RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(dragging ? 0.9 : 0.35), lineWidth: 1)
                thirdsGrid.opacity(dragging ? 1 : 0)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: dragging)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1), value: framing)
        .padding(.vertical, 8)
        .gesture(framing == .fill ? panGesture : nil)
        .accessibilityElement()
        .accessibilityLabel("Frame position")
        .accessibilityValue(positionDescription)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: position = min(1, position + 0.1)
            case .decrement: position = max(0, position - 0.1)
            @unknown default: break
            }
        }
        .sensoryFeedback(.alignment, trigger: position == 0.5) { _, centered in centered && dragStart != nil }
    }

    @ViewBuilder private var picture: some View {
        if let image {
            let img = Image(decorative: image, scale: 1).resizable()
            switch framing {
            case .fill:
                let o = liveOffset ?? offset(for: position)
                img.frame(width: filled.width, height: filled.height)
                    .offset(x: horizontal ? o : 0, y: horizontal ? 0 : o)
            case .fit:
                img.scaledToFit()
            }
        } else {
            ProgressView()
        }
    }

    private var thirdsGrid: some View {
        Canvas { ctx, size in
            var path = Path()
            for i in 1...2 {
                let x = size.width * CGFloat(i) / 3, y = size.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(path, with: .color(.white.opacity(0.4)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                guard overflow > 0 else { return }
                let start = dragStart ?? position
                if dragStart == nil { dragStart = start }
                let d = horizontal ? value.translation.width : value.translation.height
                // Track the finger 1:1 from where it grabbed, resisting past the edges.
                let raw = offset(for: start) + d
                let limit = overflow / 2
                let clamped = min(max(raw, -limit), limit)
                let over = raw - clamped
                liveOffset = clamped + rubberband(over, dimension: horizontal ? box.width : box.height)
                var p = 0.5 - Double(clamped / overflow)
                if abs(p - 0.5) < 0.02 { p = 0.5 }   // gentle detent at center
                position = p
            }
            .onEnded { _ in
                dragStart = nil
                withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 1)) {
                    liveOffset = nil
                }
            }
    }

    private func rubberband(_ x: CGFloat, dimension: CGFloat, c: CGFloat = 0.55) -> CGFloat {
        guard x != 0 else { return 0 }
        return (x * dimension * c) / (dimension + c * abs(x))
    }

    private var positionDescription: String {
        if abs(position - 0.5) < 0.01 { return "Centered" }
        let pct = Int((abs(position - 0.5) * 2 * 100).rounded())
        let side = horizontal ? (position < 0.5 ? "left" : "right") : (position < 0.5 ? "top" : "bottom")
        return "\(pct)% toward the \(side)"
    }
}
