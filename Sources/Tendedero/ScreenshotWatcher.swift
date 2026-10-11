import Foundation

/// Directory I/O never runs on the main thread, including the permission wait.
/// A prepared watcher has a baseline, but delivers nothing until committed.
@MainActor
final class ScreenshotWatcher {
    let folder: URL
    private let onNew: (URL) -> Bool
    private let onChange: () -> Void
    private let launchDate: Date
    private var generation = UUID()
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var known = Set<String>()
    private var initial: [Entry] = []
    private var rejected: [String: Rejected] = [:]
    private let listing: @Sendable (URL) throws -> [Entry]
    private let retryPolicy: RetryPolicy
    private var active = false
    private var starting = false
    private var scanning = false
    private var missed = false

    nonisolated static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp", "bmp"]
    nonisolated static let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")

    struct RetryPolicy: Sendable {
        var delays: [TimeInterval] = [0.2, 0.4, 0.8]
        var recheckInterval: TimeInterval = 5
        var batchSize: Int = 16
    }

    private struct Rejected {
        let revision: Revision
        var attempts = 0
        var nextAttempt = Date.distantPast
    }

    init(folder: URL? = nil, startedAt: Date = Date(),
         retryPolicy: RetryPolicy = RetryPolicy(),
         anyImage: Bool = false, recordings: Bool = false,
         listing: (@Sendable (URL) throws -> [Entry])? = nil,
         onNew: @escaping (URL) -> Bool, onChange: @escaping () -> Void) {
        self.folder = (folder ?? Self.screenshotFolder()).resolvingSymlinksInPath().standardizedFileURL
        launchDate = startedAt
        self.onNew = onNew
        self.onChange = onChange
        self.listing = listing ?? { try Self.list($0, anyImage: anyImage, recordings: recordings) }
        self.retryPolicy = retryPolicy
    }

    nonisolated static func screenshotFolder(settings: [String: Any]? = nil) -> URL {
        let values = settings ?? SystemScreenshotPreferences().read()
        if let raw = (values["locationScreenshot"] as? String) ?? (values["location"] as? String), !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        return desktop
    }

    /// Selection adopts existing images without importing them. Startup may
    /// include captures created while access to the directory was pending.
    func prepare(includeRecent: Bool = false) async throws {
        stop()
        starting = true
        let token = generation
        let folder = folder
        let listing = listing
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(Int32, [Entry]), Error> in
            let fd = open(folder.path, O_EVTONLY)
            guard fd >= 0 else { return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)) }
            do { return .success((fd, try listing(folder))) }
            catch { close(fd); return .failure(error) }
        }.value
        guard generation == token, !Task.isCancelled else {
            if case let .success((fd, _)) = result { close(fd) }
            throw CancellationError()
        }
        starting = false
        let (fd, entries) = try result.get()
        known = Set(entries.map { $0.url.path })
        initial = includeRecent ? entries.filter { $0.created >= launchDate && $0.candidate } : []
        known.subtract(initial.map { $0.url.path })
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, self.generation == token else { return }
            self.scheduleScan()
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    func start() {
        guard !active, !starting else { return }
        if source == nil {
            starting = true
            let token = generation
            Task { [weak self] in
                guard let self, self.generation == token else { return }
                do { try await self.prepare(includeRecent: true); self.start() }
                catch is CancellationError {} catch { NSLog("Tendedero: cannot watch \(self.folder.path): \(error)") }
            }
            return
        }
        active = true
        let captures = initial
        initial = []
        adopt(captures, reconcile: false)
        // Covers the gap between the baseline listing and installing the source,
        // and captures written after preparation but before changing settings.
        scan()
    }

    func stop() {
        generation = UUID()
        active = false
        starting = false
        scanning = false
        missed = false
        pending?.cancel()
        pending = nil
        retry?.cancel()
        retry = nil
        source?.cancel()
        source = nil
        known = []
        initial = []
        rejected = [:]
    }

    deinit { pending?.cancel(); retry?.cancel(); source?.cancel() }

    private func scheduleScan() {
        guard active else { return }
        pending?.cancel()
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.scan()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func scan() {
        guard active else { return }
        guard !scanning else { missed = true; return }
        scanning = true
        let token = generation
        let folder = folder
        let listing = listing
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { try? listing(folder) }.value
            guard let self, self.generation == token, self.active else { return }
            self.scanning = false
            if let entries = result {
                self.adopt(entries)
                guard self.generation == token, self.active else { return }
                self.onChange()
            }
            self.scheduleRetry()
            if self.missed { self.missed = false; self.scan() }
        }
    }

    private func adopt(_ entries: [Entry], reconcile: Bool = true) {
        guard active else { return }
        let token = generation
        if reconcile {
            let paths = Set(entries.map { $0.url.path })
            known.formIntersection(paths)
            rejected = rejected.filter { paths.contains($0.key) }
        }
        let now = Date()
        let candidates = entries.filter { !known.contains($0.url.path) && $0.candidate }
        for entry in candidates where rejected[entry.url.path]?.revision != entry.revision {
            // Only this file changing starts a fresh retry budget.
            rejected[entry.url.path] = Rejected(revision: entry.revision)
        }
        let due = candidates.filter {
            guard let state = rejected[$0.url.path] else { return false }
            return state.attempts <= retryPolicy.delays.count && state.nextAttempt <= now
        }.sorted {
            let a = rejected[$0.url.path]!.nextAttempt, b = rejected[$1.url.path]!.nextAttempt
            if a != b { return a < b }
            return $0.created == $1.created ? $0.url.path < $1.url.path : $0.created < $1.created
        }
        for entry in due.prefix(retryPolicy.batchSize) {
            guard generation == token, active else { return }
            let accepted = onNew(entry.url)
            guard generation == token, active else { return }
            if accepted {
                known.insert(entry.url.path)
                rejected[entry.url.path] = nil
            } else if var state = rejected[entry.url.path] {
                state.attempts += 1
                state.nextAttempt = state.attempts <= retryPolicy.delays.count
                    ? now.addingTimeInterval(retryPolicy.delays[state.attempts - 1]) : .distantFuture
                rejected[entry.url.path] = state
            }
        }
        scheduleRetry()
    }

    private func scheduleRetry() {
        retry?.cancel()
        retry = nil
        guard active, !rejected.isEmpty else { return }
        // One shared wake-up and one directory descriptor, regardless of failed
        // file count. Exhausted files only decode again when metadata changes.
        let next = rejected.values.map(\.nextAttempt).min() ?? .distantFuture
        let delay = max(0.05, min(retryPolicy.recheckInterval, next.timeIntervalSinceNow))
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.active else { return }
            self.retry = nil
            self.scan()
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    struct Entry: Sendable {
        let url: URL
        let created: Date
        let candidate: Bool
        let revision: Revision
    }

    struct Revision: Equatable, Sendable {
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }

    nonisolated static func list(_ folder: URL, anyImage: Bool = false, recordings: Bool = false) throws -> [Entry] {
        let fm = FileManager.default
        var readError: Error?
        guard let iterator = fm.enumerator(at: folder, includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants], errorHandler: { _, error in
                readError = error; return false
            }) else { throw CocoaError(.fileReadNoPermission) }
        let taggedOnly = !anyImage && folder == desktop.resolvingSymlinksInPath().standardizedFileURL
        var images: [Entry] = []
        while let url = autoreleasepool(invoking: { iterator.nextObject() as? URL }) {
            guard imageExtensions.contains(url.pathExtension.lowercased()) || (recordings && isRecordingFile(url)) else { continue }
            let values = try url.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            var info = stat()
            guard stat(url.path, &info) == 0 else { continue }
            let tagged = !taggedOnly || (recordings && isRecordingFile(url)) || url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return false }
                return getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
            }
            let revision = Revision(inode: info.st_ino, size: info.st_size,
                modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
            images.append(Entry(url: url.resolvingSymlinksInPath().standardizedFileURL,
                created: values.creationDate ?? .distantPast, candidate: tagged, revision: revision))
        }
        if let readError { throw readError }
        return images.sorted { $0.created == $1.created ? $0.url.path < $1.url.path : $0.created < $1.created }
    }
}
