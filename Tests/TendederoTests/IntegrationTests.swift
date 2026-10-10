import AppKit
import Testing
@testable import Tendedero

@Suite(.serialized)
struct IntegrationSuite {}

extension IntegrationSuite {
@MainActor
final class IntegrationTests: TestFiles {
    private func image(_ folder: URL, _ name: String = "image.png") throws -> URL {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let url = folder.appendingPathComponent(name)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "Timed out waiting for the asynchronous result")
    }

    @Test func selectionBaselinesOldFilesAndCatchesCaptureDuringCommit() async throws {
        let folder = try directory("Custom")
        let old = try image(folder, "old.png")
        var captures: [URL] = []
        let watcher = ScreenshotWatcher(folder: folder, onNew: { captures.append($0); return true }, onChange: {})
        try await watcher.prepare()
        let fresh = try image(folder, "fresh.png")
        watcher.start()
        watcher.start()
        defer { watcher.stop() }
        try await eventually { captures.count == 1 }
        #expect(captures == [fresh])
        #expect(FileManager.default.fileExists(atPath: old.path))
    }

    @Test func startupIncludesCaptureWhileValidationIsPending() async throws {
        let folder = try directory("Startup")
        let old = try image(folder, "old.png")
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        let manager = ScreenshotMonitoring()
        let gate = TestGate()
        var captures: [URL] = []
        let startup = Task {
            try await manager.replace(folder: folder, includeRecent: true,
                validate: { url in gate.wait(); return url }, onNew: { captures.append($0); return true }, onChange: {})
        }
        try await eventually { gate.entered }
        let fresh = try image(folder, "fresh.png")
        gate.release()
        try await startup.value
        defer { manager.stop() }
        try await eventually { captures == [fresh] }
    }

    @Test func startStopBeforeOpenAndRestartIgnoreStaleWork() async throws {
        let folder = try directory("Watch")
        var captures: [URL] = []
        let watcher = ScreenshotWatcher(folder: folder, onNew: { captures.append($0); return true }, onChange: {})
        for _ in 0..<15 { watcher.start(); watcher.stop() }
        try await watcher.prepare()
        watcher.start()
        let fresh = try image(folder)
        defer { watcher.stop() }
        try await eventually { captures.count == 1 }
        #expect(captures == [fresh])
        let pending = try image(folder, "pending.png")
        watcher.stop()
        try await Task.sleep(for: .milliseconds(350))
        #expect(!captures.contains(pending))
    }

    @Test func stopDuringPreparationClosesLateResult() async throws {
        let folder = try directory("Large")
        for n in 0..<300 { try Data().write(to: folder.appendingPathComponent("\(n).txt")) }
        let watcher = ScreenshotWatcher(folder: folder, onNew: { _ in Issue.record("Stopped watcher delivered"); return true }, onChange: {})
        let opening = Task { try await watcher.prepare() }
        await Task.yield()
        watcher.stop()
        do { try await opening.value } catch is CancellationError {}
        watcher.stop()
        try await Task.sleep(for: .milliseconds(100))
    }

    @Test func failedReplacementKeepsOldWatcherAndSettings() async throws {
        let folder = try directory("Old")
        let manager = ScreenshotMonitoring()
        var captures: [URL] = []
        var writes = 0
        try await manager.replace(folder: folder, onNew: { captures.append($0); return true }, onChange: {})
        defer { manager.stop() }
        do {
            try await manager.replace(folder: root.appendingPathComponent("Missing"), configure: { writes += 1 },
                                      onNew: { _ in Issue.record("Invalid watcher delivered"); return true }, onChange: {})
            Issue.record("Missing directory should fail")
        } catch {}
        #expect(manager.folder == folder)
        #expect(writes == 0)
        let fresh = try image(folder)
        try await eventually { captures == [fresh] }
        do {
            try await manager.replace(folder: directory("Next"), configure: { throw CocoaError(.fileWriteUnknown) },
                                      onNew: { _ in Issue.record("Failed commit delivered"); return true }, onChange: {})
            Issue.record("Configuration should fail")
        } catch {}
        #expect(manager.folder == folder)
        let second = try image(folder, "second.png")
        try await eventually { captures.contains(second) }
    }

    @Test func latestSwitchWinsEvenWhenEarlierValidationFinishesLast() async throws {
        let first = try directory("First"), second = try directory("Second")
        let gate = TestGate()
        let manager = ScreenshotMonitoring()
        var committed: [String] = []
        var captures: [URL] = []
        let slow = Task {
            try await manager.replace(folder: first, validate: { url in gate.wait(); return url },
                configure: { committed.append("first") }, onNew: { _ in Issue.record("Old request delivered"); return true }, onChange: {})
        }
        try await eventually { gate.entered }
        try await manager.replace(folder: second, configure: { committed.append("second") },
                                  onNew: { captures.append($0); return true }, onChange: {})
        gate.release()
        defer { manager.stop() }
        do { try await slow.value; Issue.record("Superseded request committed") } catch is CancellationError {}
        #expect(committed == ["second"])
        #expect(manager.folder == second)
        _ = try image(first)
        let fresh = try image(second)
        try await eventually { captures == [fresh] }
    }

    @Test func disabledSelectionCancelsPendingTakeover() async throws {
        let folder = try directory("Pending")
        let manager = ScreenshotMonitoring()
        let gate = TestGate()
        var applied = false
        let pending = Task {
            try await manager.replace(folder: folder, validate: { url in gate.wait(); return url },
                configure: { applied = true }, onNew: { _ in return true }, onChange: {})
        }
        try await eventually { gate.entered }
        var selected: URL?
        try await manager.validateSelection(folder, validate: { $0 }) { selected = $0 }
        gate.release()
        do { try await pending.value } catch is CancellationError {}
        #expect(!applied)
        #expect(selected == folder)
        #expect(manager.folder == nil)
    }

    @Test func customOwnershipCanonicalDedupAndClipboardOwnershipSurviveRestart() throws {
        defaults.set(true, forKey: "soundOff")
        let dedicated = try directory("Owned"), custom = try directory("Custom"), clipboard = try directory("Clipboard")
        let ordinary = try image(custom), generated = try image(clipboard), own = try image(dedicated)
        let line = Line(defaults: defaults, dedicatedFolder: dedicated, clipboardFolder: clipboard)
        let id = try #require(line.hang(ordinary, quietly: true))
        let link = root.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: ordinary)
        #expect(line.hang(link, quietly: true) == nil)
        let generatedID = try #require(line.hang(generated, quietly: true))
        let ownID = try #require(line.hang(own, quietly: true))
        #expect(!line.isInInbox(id))
        #expect(line.isInInbox(generatedID))
        #expect(line.isInInbox(ownID))
        let restored = Line(defaults: defaults, dedicatedFolder: dedicated, clipboardFolder: clipboard)
        let restoredGenerated = try #require(restored.items.first { $0.url == generated })
        #expect(restored.isInInbox(restoredGenerated.id))
        line.discard(id)
        #expect(FileManager.default.fileExists(atPath: ordinary.path))
        let escaped = dedicated.appendingPathComponent("escaped.png")
        try FileManager.default.createSymbolicLink(at: escaped, withDestinationURL: ordinary)
        #expect(!Inbox.owns(escaped, in: dedicated))
        #expect(!Inbox.owns(root.appendingPathComponent("Owned-extra/image.png"), in: dedicated))
    }

    @Test func restoreKeepsTwelveItemsAndPersistenceUntilActualCapacityIsKnown() throws {
        defaults.set(true, forKey: "soundOff")
        let custom = try directory("Custom")
        let urls = try (0..<12).map { try image(custom, "\($0).png") }
        let alias = root.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: urls[0])
        let invalid = root.appendingPathComponent("broken.png")
        try Data("invalid".utf8).write(to: invalid)
        let saved = urls.map(\.path) + [alias.path, invalid.path, root.appendingPathComponent("missing.png").path]
        defaults.set(saved, forKey: "pegged")
        let line = Line(defaults: defaults)
        #expect(line.maxItems == 8)
        #expect(line.items.map(\.url) == urls)
        #expect(line.items.allSatisfy { !$0.falling && !$0.flying })
        #expect(defaults.stringArray(forKey: "pegged") == saved, "Restore must not rewrite or truncate persistence")
        line.maxItems = 12
        let fresh = try image(custom, "fresh.png")
        _ = line.hang(fresh, quietly: true)
        #expect(line.liveCount == 12)
        #expect(line.items.filter { !$0.falling }.map(\.url) == Array(urls.dropFirst()) + [fresh])
        #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let restarted = Line(defaults: defaults)
        #expect(restarted.liveCount == 12)
    }

    @Test func overflowAndClearKeepCustomDedicatedAndClipboardFiles() async throws {
        defaults.set(true, forKey: "soundOff")
        let custom = try directory("Custom"), owned = try directory("Owned"), clipboard = try directory("Clipboard")
        let line = Line(defaults: defaults, dedicatedFolder: owned, clipboardFolder: clipboard)
        line.maxItems = 3
        let urls = try (0..<6).map { try image([owned, clipboard, custom][$0 % 3], "\($0).png") }
        for url in urls { _ = line.hang(url, quietly: true) }
        #expect(line.liveCount == 3)
        #expect(line.items.filter { !$0.falling }.map(\.url) == Array(urls.suffix(3)))
        line.clear()
        try await eventually { line.liveCount == 0 }
        #expect(defaults.stringArray(forKey: "pegged") == [])
        #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func clipboardSkipsExistingPrivateOwnCopiesAndFinderIcons() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.clearContents(); board.releaseGlobally() }
        let source = try image(root)
        let data = try Data(contentsOf: source)
        board.setData(data, forType: .png)
        var captures: [URL] = []
        let folder = try directory("Generated")
        let watcher = ClipboardWatcher(board: board, folder: folder) { captures.append($0) }
        watcher.start()
        defer { watcher.stop() }
        watcher.check()
        #expect(captures.isEmpty)
        for type in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"] {
            board.clearContents()
            board.setData(data, forType: .png)
            board.setString("", forType: .init(type))
            watcher.check()
        }
        #expect(ClipboardImage.copy(source, to: board))
        watcher.check()
        ClipboardImage.materializeForExit()
        let textFile = root.appendingPathComponent("notes.txt")
        try Data().write(to: textFile)
        let finder = NSPasteboardItem()
        finder.setString(textFile.absoluteString, forType: .fileURL)
        finder.setData(data, forType: .png)
        board.clearContents(); board.writeObjects([finder]); watcher.check()
        #expect(captures.isEmpty)
        board.clearContents(); board.writeObjects([source as NSURL]); watcher.check(); watcher.check()
        #expect(captures == [source])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        board.clearContents(); board.setData(data, forType: .png); watcher.check(); watcher.check()
        try await eventually { captures.count == 2 }
        #expect(captures[1].deletingLastPathComponent() == folder)
        #expect(try Data(contentsOf: captures[1]) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
    }

    @Test func clipboardStopCancelsPendingImageAndRemovesOnlyItsOwnFile() async throws {
        let folder = try directory("Generated")
        let existing = try image(folder, "existing.png")
        let board = NSPasteboard.withUniqueName()
        defer { board.clearContents(); board.releaseGlobally() }
        let watcher = ClipboardWatcher(board: board, folder: folder) { _ in Issue.record("Stopped clipboard delivered") }
        watcher.start()
        board.clearContents(); board.setData(try Data(contentsOf: existing), forType: .png)
        watcher.check(); watcher.stop()
        try await Task.sleep(for: .milliseconds(350))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["existing.png"])
    }

    @Test func hideRevealHideUsesOnlyLatestDeadline() async throws {
        let hide = DelayedHide()
        var orderedOut = 0
        hide.schedule(after: 0.06) { orderedOut += 1 }
        hide.cancel()
        hide.schedule(after: 0.20) { orderedOut += 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(orderedOut == 0)
        try await eventually { orderedOut == 1 }
        hide.schedule(after: 0.03) { orderedOut += 1 }
        hide.cancel()
        try await Task.sleep(for: .milliseconds(60))
        #expect(orderedOut == 1)
    }

    @Test func zoomFrameUsesSameRopePositionAndNeighbourShiftOnOffsetScreen() throws {
        defaults.set(true, forKey: "zoomOnHover")
        defaults.set(true, forKey: "soundOff")
        let line = Line(defaults: defaults)
        let ids = try (0..<3).map { try #require(line.hang(image(root, "\($0).png"), quietly: true)) }
        let panel = CGRect(x: -1800, y: 1200, width: 1600, height: 470)
        let base = try #require(line.cardFrame(for: ids[0], in: panel))
        line.hoveredID = ids[1]
        line.zoomLevel = 3.5
        let center = try #require(line.cardFrame(for: ids[1], in: panel))
        let left = try #require(line.cardFrame(for: ids[0], in: panel))
        let right = try #require(line.cardFrame(for: ids[2], in: panel))
        let push = Layout.push(for: line.items[1].thumb.size, zoom: 3.5)
        #expect(abs(left.midX - (base.midX - push)) < 0.001)
        #expect(center.midX == panel.midX)
        #expect(left.maxX < center.minX && right.minX > center.maxX)
        #expect(center.size == PeggedView.cardSize(for: line.items[1].thumb.size, zoom: 3.5))
        let rope = Layout.ropeY(x: left.midX - panel.minX, width: panel.width)
        #expect(abs(left.maxY - (panel.maxY - rope + Layout.pinAbove - PeggedView.cardOffsetBelowTop)) < 0.001)
        #expect(line.zoomPreview != nil)
        line.pressedID = ids[1]
        #expect(line.cardFrame(for: ids[1], in: panel) == center, "Pressing before drag keeps the enlarged hit area")
        line.hoveredID = nil
        #expect(line.zoomPreview == nil)
        #expect(line.cardFrame(for: ids[0], in: panel) == base)
    }

    @Test func topEdgeHandlesVerticallyStackedPartiallyOverlappingScreens() {
        let lower = CGRect(x: -1000, y: -900, width: 1800, height: 900)
        let upper = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let bar = CGRect(x: -1000, y: -30, width: 1800, height: 30)
        let exposed = EdgeReveal.zone(screen: lower, menuBar: bar, displays: [lower, upper], x: -500)
        #expect(exposed.height == 2)
        #expect(NSMouseInRect(CGPoint(x: -500, y: 0), exposed, false))
        #expect(!NSMouseInRect(CGPoint(x: -500, y: -4), exposed, false))
        #expect(EdgeReveal.zone(screen: lower, menuBar: bar, displays: [lower, upper], x: 200) == bar)
        #expect(EdgeReveal.zone(screen: lower, menuBar: bar, displays: [lower], x: 200).height == 2)
    }
}
}

final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private let semaphore = DispatchSemaphore(value: 0)
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return started }
    func wait() {
        lock.lock(); started = true; lock.unlock()
        _ = semaphore.wait(timeout: .now() + 5)
    }
    func release() { semaphore.signal() }
}
