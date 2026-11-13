import Foundation
import Observation
import Photos
#if canImport(UIKit)
import UIKit
#endif

/// Where Duo Comp keeps things.
/// - Sources: the queue's own copies of added files (Application Support, removed with the job).
/// - Outputs: finished files in Documents/DuoComp, so they show in the Files app.
public enum CompStore {
    static var root: URL {
        let url = URL.applicationSupportDirectory.appending(path: "DuoComp", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    public static var sources: URL {
        let url = root.appending(path: "Sources", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    public static var outputs: URL {
        let url = URL.documentsDirectory.appending(path: "DuoComp", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var queueFile: URL { root.appending(path: "queue.json") }

    /// Copies a picked file into Sources under a unique name; returns that name.
    public static func importCopy(of url: URL) throws -> String {
        let name = UUID().uuidString.prefix(8) + "-" + url.lastPathComponent
        try FileManager.default.copyItem(at: url, to: sources.appending(path: String(name)))
        return String(name)
    }
}

@MainActor @Observable
public final class CompQueue {
    public static let shared = CompQueue()

    public private(set) var jobs: [CompJob] = []
    public var saveToPhotos: Bool {
        didSet { UserDefaults.standard.set(saveToPhotos, forKey: "duocomp.saveToPhotos") }
    }
    public var lastPresetID: String {
        didSet { UserDefaults.standard.set(lastPresetID, forKey: "duocomp.lastPreset") }
    }
    /// Set when saving to Photos failed (for example, access was turned off).
    public var photosMessage: String?

    /// Set when iOS ran out of background time; cleared on return to the foreground.
    private var pausedInBackground = false
    private var encoder: CompEncoder?
    private var runningID: UUID?
    #if canImport(UIKit)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    init() {
        let d = UserDefaults.standard
        saveToPhotos = d.object(forKey: "duocomp.saveToPhotos") as? Bool ?? true
        lastPresetID = d.string(forKey: "duocomp.lastPreset") ?? CompPreset.vertical.id
        if let data = try? Data(contentsOf: CompStore.queueFile),
           let saved = try? JSONDecoder().decode([CompJob].self, from: data) {
            // An encode cut off when the app was closed starts over.
            jobs = saved.map { job in
                var job = job
                if job.state == .encoding { job.state = .waiting; job.progress = 0 }
                return job
            }
        }
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                CompQueue.shared.pausedInBackground = false
                CompQueue.shared.runNext()
            }
        }
        #endif
        runNext()
    }

    public var hasWork: Bool { jobs.contains { $0.state == .waiting || $0.state == .encoding } }
    public var hasFinished: Bool { jobs.contains { $0.state != .waiting && $0.state != .encoding } }

    public func sourceURL(_ job: CompJob) -> URL { CompStore.sources.appending(path: job.sourceFile) }
    public func outputURL(_ job: CompJob) -> URL? { job.outputFile.map { CompStore.outputs.appending(path: $0) } }

    public func add(_ job: CompJob) {
        jobs.append(job)
        save()
        runNext()
    }

    public func cancel(_ id: UUID) {
        if id == runningID { encoder?.cancel() }
        update(id) { $0.state = .cancelled; $0.progress = 0 }
    }

    public func retry(_ id: UUID) {
        update(id) { $0.state = .waiting; $0.progress = 0 }
        runNext()
    }

    /// Removes the row and the queue's copy of the source. Finished files stay in Files.
    public func remove(_ id: UUID) {
        if id == runningID { encoder?.cancel() }
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        jobs.removeAll { $0.id == id }
        if !jobs.contains(where: { $0.sourceFile == job.sourceFile }) {
            try? FileManager.default.removeItem(at: sourceURL(job))
        }
        save()
    }

    public func clearFinished() {
        for job in jobs where job.state != .waiting && job.state != .encoding { remove(job.id) }
    }

    // MARK: Running

    private func runNext() {
        guard !pausedInBackground, runningID == nil, let job = jobs.first(where: { $0.state == .waiting }) else {
            endBackgroundTask()
            return
        }
        let id = job.id
        runningID = id
        update(id) { $0.state = .encoding; $0.progress = 0 }
        beginBackgroundTask()

        let output = uniqueOutputURL(for: job)
        let request = CompRequest(job: job, source: sourceURL(job), output: output)
        let encoder = CompEncoder()
        self.encoder = encoder
        Task {
            do {
                try await encoder.run(request) { p in
                    Task { @MainActor in CompQueue.shared.setProgress(id, p) }
                }
                let bytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init)
                update(id) { $0.state = .done; $0.progress = 1; $0.outputFile = output.lastPathComponent; $0.outputBytes = bytes }
                if saveToPhotos && !job.preset.isAudioOnly { await saveVideoToPhotos(output) }
            } catch is CancellationError {
                // Already marked cancelled (or removed).
            } catch {
                update(id) { $0.state = .failed(error.localizedDescription); $0.progress = 0 }
            }
            self.encoder = nil
            runningID = nil
            runNext()
        }
    }

    private func setProgress(_ id: UUID, _ p: Double) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == .encoding else { return }
        jobs[i].progress = p
    }

    private func update(_ id: UUID, _ change: (inout CompJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
        save()
    }

    private func uniqueOutputURL(for job: CompJob) -> URL {
        let base = "\(job.name) (\(job.preset.title.components(separatedBy: ",").first ?? job.preset.title))"
            .replacingOccurrences(of: "/", with: "-")
        var url = CompStore.outputs.appending(path: "\(base).\(job.preset.fileExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = CompStore.outputs.appending(path: "\(base) \(n).\(job.preset.fileExtension)")
            n += 1
        }
        return url
    }

    private func save() {
        if let data = try? JSONEncoder().encode(jobs) { try? data.write(to: CompStore.queueFile, options: .atomic) }
    }

    private func saveVideoToPhotos(_ url: URL) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            photosMessage = "Duo Comp can't save to Photos. Turn on Photos access for Duo Control in Settings, or use Share."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
            }
        } catch {
            photosMessage = "Couldn't save to Photos: \(error.localizedDescription)"
        }
    }

    // MARK: Background time

    private func beginBackgroundTask() {
        #if canImport(UIKit)
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "DuoComp") { [weak self] in
            // Out of time: stop cleanly; the job waits and starts over next launch.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pausedInBackground = true
                if let id = self.runningID {
                    self.encoder?.cancel()
                    self.update(id) { $0.state = .waiting; $0.progress = 0 }
                }
                self.endBackgroundTask()
            }
        }
        #endif
    }

    private func endBackgroundTask() {
        #if canImport(UIKit)
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        #endif
    }
}
