import Foundation

/// Commit settings and the replacement together; late preparations cannot win.
@MainActor
final class ScreenshotMonitoring {
    private(set) var watcher: ScreenshotWatcher?
    private var safety: ScreenshotWatcher?
    private var pending: ScreenshotWatcher?
    private var generation = UUID()
    var folder: URL? { watcher?.folder }
    private let defaults: UserDefaults
    private let launchedAt = Date()
    private var extras: [URL: ScreenshotWatcher] = [:]
    private var preparingExtras: [URL: ScreenshotWatcher] = [:]
    static let maxExtraFolders = 3

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var extraFolders: [URL] {
        var unique: [URL] = []
        for path in defaults.stringArray(forKey: "extraFolders") ?? [] {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            if !unique.contains(url) { unique.append(url) }
        }
        return Array(unique.prefix(Self.maxExtraFolders))
    }

    func addExtra(_ folder: URL, includeRecent: Bool = false,
                  onNew: @escaping (URL) -> Bool, onChange: @escaping () -> Void) async throws {
        guard folder.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let url = folder.resolvingSymlinksInPath().standardizedFileURL
        guard extras[url] == nil, preparingExtras[url] == nil else { return }
        let reserved = Set(extraFolders).union(preparingExtras.keys)
        guard reserved.contains(url) || reserved.count < Self.maxExtraFolders else {
            throw CocoaError(.validationMultipleErrors)
        }
        let next = ScreenshotWatcher(folder: url, startedAt: includeRecent ? launchedAt : Date(), anyImage: true, recordings: true, onNew: onNew, onChange: onChange)
        preparingExtras[url] = next
        do {
            try await next.prepare(includeRecent: includeRecent)
            guard preparingExtras[url] === next, !Task.isCancelled else { throw CancellationError() }
            var folders = extraFolders
            if !folders.contains(url) { folders.append(url) }
            defaults.set(folders.map(\.path), forKey: "extraFolders")
            preparingExtras[url] = nil
            extras[url] = next
            next.start()
        } catch {
            next.stop()
            if preparingExtras[url] === next { preparingExtras[url] = nil }
            throw error
        }
    }

    func removeExtra(_ folder: URL) {
        let url = folder.resolvingSymlinksInPath().standardizedFileURL
        preparingExtras.removeValue(forKey: url)?.stop()
        extras.removeValue(forKey: url)?.stop()
        defaults.set(extraFolders.filter { $0 != url }.map(\.path), forKey: "extraFolders")
    }

    private func begin() -> UUID {
        generation = UUID()
        pending?.stop()
        pending = nil
        return generation
    }

    func replace(folder: URL, includeRecent: Bool = false, recordings: Bool = false,
                 validate: ((URL) throws -> URL)? = nil,
                 configure: () throws -> Void = {},
                 onNew: @escaping (URL) -> Bool, onChange: @escaping () -> Void) async throws {
        let token = begin()
        let startedAt = Date()
        let validation = await Task.detached(priority: .userInitiated) { Result { try validate?(folder) ?? folder } }.value
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        let destination = try validation.get()
        let next = ScreenshotWatcher(folder: destination, startedAt: startedAt, recordings: recordings, onNew: onNew, onChange: onChange)
        pending = next
        do {
            try await next.prepare(includeRecent: includeRecent)
            guard generation == token, !Task.isCancelled else { throw CancellationError() }
            try configure()
            watcher?.stop()
            safety?.stop()
            safety = nil
            watcher = next
            pending = nil
            next.start()
        } catch {
            next.stop()
            if generation == token { pending = nil }
            throw error
        }
    }

    func validateSelection(_ folder: URL, validate: @escaping (URL) throws -> URL,
                           commit: (URL) throws -> Void) async throws {
        let token = begin()
        let validation = await Task.detached(priority: .userInitiated) { Result { try validate(folder) } }.value
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        try commit(validation.get())
    }

    func watchDesktopIfNeeded(enabled: Bool, onNew: @escaping (URL) -> Bool, onChange: @escaping () -> Void) {
        safety?.stop()
        safety = nil
        guard enabled, folder != ScreenshotWatcher.desktop.resolvingSymlinksInPath().standardizedFileURL else { return }
        let next = ScreenshotWatcher(folder: ScreenshotWatcher.desktop, onNew: onNew, onChange: onChange)
        safety = next
        next.start()
    }

    func stop() {
        for value in Array(extras.values) + Array(preparingExtras.values) { value.stop() }
        extras = [:]
        preparingExtras = [:]
        _ = begin()
        watcher?.stop()
        watcher = nil
        safety?.stop()
        safety = nil
    }
}
