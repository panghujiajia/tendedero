import Foundation

/// Commit settings and the replacement together; late preparations cannot win.
@MainActor
final class ScreenshotMonitoring {
    private(set) var watcher: ScreenshotWatcher?
    private var safety: ScreenshotWatcher?
    private var pending: ScreenshotWatcher?
    private var generation = UUID()
    var folder: URL? { watcher?.folder }

    private func begin() -> UUID {
        generation = UUID()
        pending?.stop()
        pending = nil
        return generation
    }

    func replace(folder: URL, includeRecent: Bool = false,
                 validate: ((URL) throws -> URL)? = nil,
                 configure: () throws -> Void = {},
                 onNew: @escaping (URL) -> Bool, onChange: @escaping () -> Void) async throws {
        let token = begin()
        let startedAt = Date()
        let validation = await Task.detached(priority: .userInitiated) { Result { try validate?(folder) ?? folder } }.value
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        let destination = try validation.get()
        let next = ScreenshotWatcher(folder: destination, startedAt: startedAt, onNew: onNew, onChange: onChange)
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
        _ = begin()
        watcher?.stop()
        watcher = nil
        safety?.stop()
        safety = nil
    }
}
