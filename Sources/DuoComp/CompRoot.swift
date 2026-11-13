import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Another place the host app can switch to (Duo Control's other modes).
public struct CompHostApp: Identifiable {
    public let id: String
    public let title: String
    public let symbol: String
    public let action: @MainActor () -> Void
    public init(id: String, title: String, symbol: String, action: @escaping @MainActor () -> Void) {
        self.id = id; self.title = title; self.symbol = symbol; self.action = action
    }
}

/// A picked movie, copied into the queue's Sources folder as it arrives.
struct CompPickedMovie: Transferable {
    let file: String
    let name: String
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let file = try CompStore.importCopy(of: received.file)
            return Self(file: file, name: received.file.deletingPathExtension().lastPathComponent)
        }
    }
}

public struct DuoCompRoot: View {
    let onSwitchApp: (@MainActor () -> Void)?
    let otherApps: [CompHostApp]

    public init(onSwitchApp: (@MainActor () -> Void)? = nil, otherApps: [CompHostApp] = []) {
        self.onSwitchApp = onSwitchApp
        self.otherApps = otherApps
    }

    @State private var queue = CompQueue.shared
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showsPhotos = false
    @State private var showsFiles = false
    /// Files picked, waiting for a preset.
    @State private var picked: [(file: String, name: String)] = []
    @State private var showsPresets = false
    /// Files that need the reframe/trim question, asked one at a time.
    @State private var confirming: [CompPending] = []
    @State private var confirmCount = 0
    @State private var importing = false
    @State private var importError: String?

    public var body: some View {
        NavigationStack {
            Group {
                if queue.jobs.isEmpty && !importing {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("DuoComp")
            .toolbar { toolbar }
        }
        .photosPicker(isPresented: $showsPhotos, selection: $photoItems, maxSelectionCount: 20, matching: .videos, preferredItemEncoding: .current)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await importPhotos(items) }
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.movie, .audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .sheet(isPresented: $showsPresets, onDismiss: discardPicked) {
            CompPresetPicker(count: picked.count, selected: queue.lastPresetID) { preset in
                queue.lastPresetID = preset.id
                let files = picked
                picked = []
                showsPresets = false
                Task { await prepare(files, with: preset) }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: Binding(get: { confirming.first }, set: { if $0 == nil, !confirming.isEmpty { skipCurrent() } })) { pending in
            CompConfirmSheet(pending: pending, index: confirmCount - confirming.count + 1, count: confirmCount,
                             onAdd: { job in
                                 queue.add(job)
                                 confirming.removeFirst()
                             },
                             onSkip: skipCurrent)
                .id(pending.id)
                .presentationDetents([.large])
                .interactiveDismissDisabled()
        }
        .alert("Couldn't Add File", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") {}
        } message: {
            Text(importError ?? "")
        }
        .alert("Photos", isPresented: Binding(get: { queue.photosMessage != nil }, set: { if !$0 { queue.photosMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(queue.photosMessage ?? "")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if onSwitchApp != nil || !otherApps.isEmpty {
            ToolbarItem(placement: .navigation) {
                Menu {
                    if let onSwitchApp {
                        Button("DuoControl", systemImage: "slider.horizontal.3", action: onSwitchApp)
                    }
                    ForEach(otherApps) { app in
                        Button(app.title, systemImage: app.symbol, action: app.action)
                    }
                } label: {
                    Label("Duo Apps", systemImage: "square.grid.2x2")
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            addMenu
        }
        ToolbarItem(placement: .secondaryAction) {
            Menu {
                Toggle("Save Videos to Photos", systemImage: "photo.on.rectangle", isOn: $queue.saveToPhotos)
                Button("Clear Finished", systemImage: "checkmark.circle", action: queue.clearFinished)
                    .disabled(!queue.hasFinished)
            } label: {
                Label("Options", systemImage: "ellipsis")
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Button("Photos", systemImage: "photo.on.rectangle") { showsPhotos = true }
            Button("Files", systemImage: "folder") { showsFiles = true }
        } label: {
            Label("Add", systemImage: "plus")
        }
    }

    // MARK: Content

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing in the Queue", systemImage: "rectangle.compress.vertical")
        } description: {
            Text("Add a video to make it ready for Reels, TikTok, Shorts, YouTube or X.")
        } actions: {
            Button("Add from Photos") { showsPhotos = true }
                .buttonStyle(.borderedProminent)
            Button("Add from Files") { showsFiles = true }
        }
    }

    private var list: some View {
        List {
            if importing {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Adding…").foregroundStyle(.secondary)
                }
            }
            ForEach(queue.jobs.reversed()) { job in
                CompJobRow(job: job, queue: queue)
            }
        }
        .animation(.default, value: queue.jobs.map(\.id))
    }

    // MARK: Adding

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        importing = true
        defer { importing = false }
        var files: [(String, String)] = []
        for item in items {
            do {
                if let movie = try await item.loadTransferable(type: CompPickedMovie.self) {
                    files.append((movie.file, movie.name))
                }
            } catch {
                importError = "A video couldn't be loaded from Photos. \(error.localizedDescription)"
            }
        }
        offerPresets(for: files)
    }

    private func importFiles(_ urls: [URL]) {
        var files: [(String, String)] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                files.append((try CompStore.importCopy(of: url), url.deletingPathExtension().lastPathComponent))
            } catch {
                importError = "\(url.lastPathComponent) couldn't be copied. \(error.localizedDescription)"
            }
        }
        offerPresets(for: files)
    }

    private func offerPresets(for files: [(String, String)]) {
        guard !files.isEmpty else { return }
        picked = files.map { (file: $0.0, name: $0.1) }
        showsPresets = true
    }

    /// Probes each file; files that already fit go straight to the queue,
    /// the rest wait for the reframe/trim question.
    private func prepare(_ files: [(file: String, name: String)], with preset: CompPreset) async {
        importing = true
        var asks: [CompPending] = []
        for f in files {
            let url = CompStore.sources.appending(path: f.file)
            do {
                let info = try await CompSourceInfo.probe(url)
                guard info.hasVideo || info.hasAudio else { throw CompError.noTracks }
                let job = CompJob(name: f.name, sourceFile: f.file, source: info, preset: preset)
                let advice = CompAdvice(source: info, preset: preset)
                if advice.isWorthAsking {
                    asks.append(CompPending(job: job, advice: advice))
                } else {
                    queue.add(job)
                }
            } catch {
                try? FileManager.default.removeItem(at: url)
                importError = "\(f.name) couldn't be read. \(error.localizedDescription)"
            }
        }
        importing = false
        confirmCount = asks.count
        confirming = asks
    }

    private func skipCurrent() {
        guard let first = confirming.first else { return }
        try? FileManager.default.removeItem(at: CompStore.sources.appending(path: first.job.sourceFile))
        confirming.removeFirst()
    }

    private func discardPicked() {
        for f in picked { try? FileManager.default.removeItem(at: CompStore.sources.appending(path: f.file)) }
        picked = []
    }
}

// MARK: - Preset picker

struct CompPresetPicker: View {
    let count: Int
    let selected: String
    let onChoose: (CompPreset) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(CompPreset.all) { preset in
                Button { onChoose(preset) } label: {
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
                        if preset.id == selected {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                                .accessibilityLabel("Last used")
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(count > 1 ? "Compress \(count) Files For" : "Compress For")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Row

struct CompJobRow: View {
    let job: CompJob
    let queue: CompQueue

    var body: some View {
        HStack(spacing: 12) {
            CompThumbnailView(url: queue.sourceURL(job), isAudio: !job.source.hasVideo || job.preset.isAudioOnly)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name).font(.headline).lineLimit(1)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                status
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.vertical, 4)
        .swipeActions {
            if job.state == .encoding || job.state == .waiting {
                Button("Cancel", systemImage: "xmark") { queue.cancel(job.id) }.tint(.orange)
            } else {
                Button("Remove", systemImage: "trash", role: .destructive) { queue.remove(job.id) }
            }
        }
        .contextMenu {
            if let url = queue.outputURL(job), job.state == .done {
                ShareLink(item: url)
            }
            if case .failed = job.state { Button("Try Again", systemImage: "arrow.clockwise") { queue.retry(job.id) } }
            if job.state == .cancelled { Button("Try Again", systemImage: "arrow.clockwise") { queue.retry(job.id) } }
            if job.state == .encoding || job.state == .waiting {
                Button("Cancel", systemImage: "xmark") { queue.cancel(job.id) }
            } else {
                Button("Remove", systemImage: "trash", role: .destructive) { queue.remove(job.id) }
            }
        }
    }

    private var subtitle: String {
        var parts = [job.preset.title]
        if job.trimEnd != nil || job.trimStart > 0 { parts.append(CompFormat.duration(job.outputDuration)) }
        if job.framing == .fit, job.preset.aspect != nil { parts.append("Fit") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var status: some View {
        switch job.state {
        case .waiting:
            Text("Waiting · about \(CompFormat.bytes(job.estimatedBytes))")
                .font(.footnote).foregroundStyle(.secondary)
        case .encoding:
            ProgressView(value: job.progress) {
                EmptyView()
            } currentValueLabel: {
                Text("\(Int(job.progress * 100))%").monospacedDigit()
            }
            .font(.footnote)
            .animation(.linear(duration: 0.25), value: job.progress)
        case .done:
            Text(doneText).font(.footnote).foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(.red).lineLimit(2)
        case .cancelled:
            Text("Cancelled").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var doneText: String {
        let from = CompFormat.bytes(job.source.bytes)
        let to = job.outputBytes.map(CompFormat.bytes) ?? "?"
        if let pct = job.savedPercent, pct > 0 { return "\(from) → \(to) (\(pct)% smaller)" }
        return "\(from) → \(to)"
    }

    @ViewBuilder private var trailing: some View {
        switch job.state {
        case .done:
            if let url = queue.outputURL(job) {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .frame(minWidth: 44, minHeight: 44)
            }
        case .failed, .cancelled:
            Button { queue.retry(job.id) } label: {
                Label("Try Again", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
        case .encoding, .waiting:
            Button { queue.cancel(job.id) } label: {
                Label("Cancel", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
        }
    }
}
