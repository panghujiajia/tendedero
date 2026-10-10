import AppKit
import Testing
@testable import Tendedero

private final class ControlledListing: @unchecked Sendable {
    private let lock = NSLock()
    private var failures = 0
    private var gate: TestGate?
    func failNext() { lock.lock(); failures += 1; lock.unlock() }
    func blockNext(_ gate: TestGate) { lock.lock(); self.gate = gate; lock.unlock() }
    func list(_ folder: URL) throws -> [ScreenshotWatcher.Entry] {
        lock.lock()
        let fail = failures > 0
        if fail { failures -= 1 }
        let gate = self.gate
        self.gate = nil
        lock.unlock()
        gate?.wait()
        if fail { throw CocoaError(.fileReadNoPermission) }
        return try ScreenshotWatcher.list(folder)
    }
}

extension IntegrationSuite {
@MainActor
final class ScreenshotRetryTests: TestFiles {
    private let fast = ScreenshotWatcher.RetryPolicy(delays: [0.05, 0.1], recheckInterval: 0.1, batchSize: 8)

    private func image(_ folder: URL, _ name: String) throws -> URL {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let url = folder.appendingPathComponent(name)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "Timed out waiting for isolated watcher")
    }

    @Test func rejectedCaptureRetriesWithoutFileEventAndAcceptedCopyIsNotReplayed() async throws {
        let folder = try directory("Watch")
        var attempts = 0
        let watcher = ScreenshotWatcher(folder: folder, retryPolicy: fast, onNew: { _ in
            attempts += 1
            return attempts > 1
        }, onChange: {})
        try await watcher.prepare()
        _ = try image(folder, "new.png")
        watcher.start()
        defer { watcher.stop() }
        try await eventually { attempts == 2 }
        _ = try image(folder, "new.png")
        try Data().write(to: folder.appendingPathComponent("unrelated.txt"))
        try await Task.sleep(for: .milliseconds(350))
        #expect(attempts == 2)
    }

    @Test func exhaustedFileRecoversOnInPlaceWriteButUnrelatedEventsDoNotResetBudget() async throws {
        let folder = try directory("Watch"), url = folder.appendingPathComponent("slow.png")
        var attempts = 0, accepted = 0
        let watcher = ScreenshotWatcher(folder: folder, retryPolicy: fast, onNew: {
            attempts += 1
            if makeThumbnail($0) == nil { return false }
            accepted += 1
            return true
        }, onChange: {})
        try await watcher.prepare()
        try Data().write(to: url)
        watcher.start()
        defer { watcher.stop() }
        try await eventually { attempts == 3 }
        for n in 0..<5 {
            try Data().write(to: folder.appendingPathComponent("\(n).txt"))
            try await Task.sleep(for: .milliseconds(70))
        }
        #expect(attempts == 3)
        _ = try image(folder, "slow.png") // An in-place write need not emit a directory event.
        try await eventually { accepted == 1 }
        #expect(attempts == 4)
    }

    @Test func manyBrokenFilesHaveOneDirectoryWatchAndBoundedBatches() async throws {
        let folder = try directory("Many")
        func descriptors() -> Int { (0..<min(getdtablesize(), 4096)).filter { fcntl($0, F_GETFD) >= 0 }.count }
        let before = descriptors()
        var attempts: [String: Int] = [:]
        var sinceScan = 0, maximumBatch = 0
        let policy = ScreenshotWatcher.RetryPolicy(delays: [], recheckInterval: 0.1, batchSize: 8)
        let watcher = ScreenshotWatcher(folder: folder, retryPolicy: policy, onNew: {
            attempts[$0.path, default: 0] += 1
            sinceScan += 1
            return false
        }, onChange: { maximumBatch = max(maximumBatch, sinceScan); sinceScan = 0 })
        try await watcher.prepare()
        for n in 0..<100 { try Data().write(to: folder.appendingPathComponent("\(n).png")) }
        watcher.start()
        defer { watcher.stop() }
        try await eventually { attempts.count == 100 }
        #expect(descriptors() - before < 8, "Rejected files must not each keep a descriptor")
        #expect(maximumBatch <= 8)
        try Data().write(to: folder.appendingPathComponent("unrelated.txt"))
        try await Task.sleep(for: .milliseconds(350))
        #expect(attempts.values.allSatisfy { $0 == 1 })
        _ = try image(folder, "99.png")
        try await eventually { attempts[folder.appendingPathComponent("99.png").path] == 2 }
        #expect(attempts.filter { $0.value > 1 }.count == 1)
    }

    @Test func initialListingFailureNeverAdoptsEmptyBaseline() async throws {
        let folder = try directory("Watch")
        let old = try image(folder, "old.png")
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        let listing = ControlledListing()
        var received: [URL] = []
        let watcher = ScreenshotWatcher(folder: folder, retryPolicy: fast, listing: { try listing.list($0) },
            onNew: { received.append($0); return true }, onChange: {})
        listing.failNext()
        do { try await watcher.prepare(includeRecent: true); Issue.record("Expected listing failure") } catch {}
        #expect(received.isEmpty)
        let fresh = try image(folder, "fresh.png")
        try await watcher.prepare(includeRecent: true)
        watcher.start()
        defer { watcher.stop() }
        try await eventually { received == [fresh] }
        try Data().write(to: folder.appendingPathComponent("event.txt"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(received == [fresh])
    }

    @Test func staleListingAfterStopAndRestartCannotAffectNewGeneration() async throws {
        let folder = try directory("Watch")
        let listing = ControlledListing(), gate = TestGate()
        defer { gate.release() }
        var received: [URL] = []
        let watcher = ScreenshotWatcher(folder: folder, retryPolicy: fast, listing: { try listing.list($0) },
            onNew: { received.append($0); return true }, onChange: {})
        try await watcher.prepare()
        listing.blockNext(gate)
        watcher.start()
        try await eventually { gate.entered }
        watcher.stop()
        let old = try image(folder, "old-generation.png")
        try await watcher.prepare()
        watcher.start()
        gate.release()
        defer { watcher.stop(); gate.release() }
        let fresh = try image(folder, "new-generation.png")
        try await eventually { received.contains(fresh) }
        #expect(!received.contains(old))
        try await Task.sleep(for: .milliseconds(300))
        #expect(received == [fresh])
    }

    @Test func stopInsideRejectionCannotResurrectRetryWork() async throws {
        let folder = try directory("Watch")
        var attempts = 0
        var watcher: ScreenshotWatcher!
        watcher = ScreenshotWatcher(folder: folder, retryPolicy: fast, onNew: { _ in
            attempts += 1
            watcher.stop()
            return false
        }, onChange: {})
        try await watcher.prepare()
        _ = try image(folder, "new.png")
        watcher.start()
        try await eventually { attempts == 1 }
        _ = try image(folder, "new.png")
        try await Task.sleep(for: .milliseconds(350))
        #expect(attempts == 1)
        watcher = nil
    }

    @Test func rapidDirectorySwitchInvalidatesOldRetries() async throws {
        let a = try directory("A"), b = try directory("B"), c = try directory("C")
        let manager = ScreenshotMonitoring()
        var oldAttempts = 0, received: [URL] = []
        try await manager.replace(folder: a, onNew: { _ in oldAttempts += 1; return false }, onChange: {})
        try Data().write(to: a.appendingPathComponent("unfinished.png"))
        try await eventually { oldAttempts > 0 }
        try await manager.replace(folder: b, onNew: { _ in Issue.record("Middle watcher delivered"); return true }, onChange: {})
        try await manager.replace(folder: c, onNew: { received.append($0); return true }, onChange: {})
        let stoppedAt = oldAttempts
        defer { manager.stop() }
        _ = try image(a, "unfinished.png")
        let fresh = try image(c, "fresh.png")
        try await eventually { received == [fresh] }
        try await Task.sleep(for: .milliseconds(500))
        #expect(oldAttempts == stoppedAt)
    }
}
}
