import AppKit
import AVFoundation
import Carbon
import Testing
@testable import Tendedero

extension IntegrationSuite {
@MainActor
final class UpstreamFeaturesTests: TestFiles {
    private func image(_ folder: URL, _ name: String) throws -> URL {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let url = folder.appendingPathComponent(name).appendingPathExtension("png")
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition())
    }

    @Test func shortcutConflictRestoresPreviousAndRemovalPersists() {
        #expect(Shortcut.load(from: defaults) == .standard)
        let wanted = Shortcut(keyCode: kVK_ANSI_K, modifiers: [.command, .shift], key: "k")
        var calls: [Shortcut?] = []
        #expect(!Shortcut.install(wanted, defaults: defaults) { calls.append($0); return $0 == .standard })
        #expect(calls == [wanted, .standard])
        #expect(Shortcut.load(from: defaults) == .standard)
        #expect(Shortcut.install(wanted, defaults: defaults) { _ in true })
        #expect(Shortcut.load(from: defaults) == wanted)
        #expect(wanted.carbonModifiers == cmdKey | shiftKey)
        #expect(Shortcut.install(nil, defaults: defaults) { $0 == nil })
        #expect(Shortcut.load(from: defaults) == nil)
    }

    @Test func invalidShortcutPreferencesDoNotRegisterTypingKeys() {
        defaults.set(["keyCode": -1, "modifiers": 0, "key": "a"], forKey: "shortcut")
        #expect(Shortcut.load(from: defaults) == nil)
        defaults.set(["keyCode": 1, "modifiers": NSEvent.ModifierFlags.shift.rawValue, "key": "a"], forKey: "shortcut")
        #expect(Shortcut.load(from: defaults) == nil)
    }

    @Test func historyRestoresOneHundredAndLoweringCapacityPreservesEveryFile() throws {
        defaults.set(true, forKey: "soundOff")
        let line = Line(defaults: defaults)
        line.keepOnLine = 100
        line.updateCapacity(width: 1600)
        var files: [URL] = []
        for n in 0..<105 {
            let url = try image(root, String(n)); files.append(url)
            #expect(line.hang(url, quietly: true) != nil)
        }
        #expect(line.liveCount == 100)
        line.scroll(by: 1_000_000)
        #expect(line.scroll == CGFloat(100 - line.visibleCount) * Layout.spacing)
        let restarted = Line(defaults: defaults)
        #expect(restarted.liveCount == 100)
        restarted.updateCapacity(width: 1600)
        restarted.keepOnLine = 25
        restarted.updateCapacity(width: 1600)
        restarted.trimToCapacity()
        #expect(restarted.liveCount == 25)
        #expect(restarted.scroll == 0)
        restarted.keepOnLine = nil
        restarted.updateCapacity(width: 1600)
        restarted.trimToCapacity()
        #expect(restarted.liveCount == restarted.visibleCount)
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(Line(defaults: defaults).liveCount == restarted.visibleCount)
    }

    @Test func bulkLeftRightAndClearKeepCustomDedicatedAndClipboardFiles() async throws {
        defaults.set(true, forKey: "soundOff")
        let dedicated = try directory("Dedicated"), clipboard = try directory("Clipboard"), custom = try directory("Custom")
        let line = Line(defaults: defaults, dedicatedFolder: dedicated, clipboardFolder: clipboard)
        var files: [URL] = [], ids: [UUID] = []
        for n in 0..<7 {
            let url = try image([dedicated, clipboard, custom][n % 3], String(n))
            files.append(url); ids.append(try #require(line.hang(url, quietly: true)))
        }
        let before = try files.map { try Data(contentsOf: $0) }
        #expect(line.neighbours(of: ids[3], toTheLeft: true).map(\.id) == Array(ids.prefix(3)))
        line.takeDown(ids[3], toTheLeft: true)
        line.takeDown(ids[3], toTheLeft: false)
        try await eventually { line.liveCount == 1 }
        #expect(line.previewURLs == [files[3]])
        line.clear()
        try await eventually { line.liveCount == 0 }
        #expect(try files.map { try Data(contentsOf: $0) } == before)
    }

    @Test func scrollDirectionsKeepHistoryAndHoverZoomSeparate() {
        #expect(Layout.scrollAction(x: 8, y: 1, overPhoto: true, zoomEnabled: true) == .history)
        #expect(Layout.scrollAction(x: 1, y: -8, overPhoto: true, zoomEnabled: true) == .zoom)
        #expect(Layout.scrollAction(x: 1, y: -8, overPhoto: false, zoomEnabled: true) == .ignore)
        #expect(Layout.scrollAction(x: 1, y: -8, overPhoto: true, zoomEnabled: false) == .ignore)
        #expect(Layout.scrollAction(x: 0, y: 0, overPhoto: true, zoomEnabled: true) == .ignore)
        #expect(Layout.Size.small.scale == 0.8 && Layout.Size.medium.scale == 1 && Layout.Size.large.scale == 1.35)
        let first = Layout.x(index: 0, count: 12, width: 800)
        let last = Layout.x(index: 11, count: 12, width: 800)
        #expect(first >= 100 && last <= 700)
        #expect(Layout.ropeY(x: -20_000, width: 800) == Layout.ropeTop)
        #expect(Layout.ropeY(x: 20_000, width: 800) == Layout.ropeTop)
        let newest = Layout.x(index: 99, count: 100, width: 1600, visible: 8, keepsHistory: true)
        #expect(newest < 1600)
    }

    @Test func extraFoldersLimitAliasesFailuresAndRemovalLeavePrimaryWorking() async throws {
        let manager = ScreenshotMonitoring(defaults: defaults)
        defer { manager.stop() }
        let primary = try directory("Primary")
        var received: [URL] = []
        let receive: (URL) -> Bool = { received.append($0); return true }
        try await manager.replace(folder: primary, onNew: receive, onChange: {})
        let first = try directory("One")
        try await manager.addExtra(first, onNew: receive, onChange: {})
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        try await manager.addExtra(alias, onNew: receive, onChange: {})
        #expect(manager.extraFolders == [first])
        do {
            try await manager.addExtra(root.appendingPathComponent("Missing"), onNew: receive, onChange: {})
            Issue.record("不可用目录不得保存")
        } catch {}
        for name in ["Two", "Three"] { try await manager.addExtra(directory(name), onNew: receive, onChange: {}) }
        do {
            try await manager.addExtra(directory("Four"), onNew: receive, onChange: {})
            Issue.record("不得超过三个额外目录")
        } catch {}
        #expect(manager.extraFolders.count == 3)
        let fresh = try image(first, "fresh")
        try await eventually { received.contains(fresh) }
        manager.removeExtra(first)
        let removed = try image(first, "after-removal")
        let mainFile = try image(primary, "main")
        try await eventually { received.contains(mainFile) }
        #expect(!received.contains(removed))
        #expect(manager.folder == primary)
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(ScreenshotMonitoring(defaults: defaults).extraFolders.count == 2)
    }

    @Test func concurrentExtraSelectionsRespectLimit() async throws {
        let manager = ScreenshotMonitoring(defaults: defaults)
        defer { manager.stop() }
        let folders = try (0..<4).map { try directory("Concurrent-\($0)") }
        let pending = folders.map { folder in Task { () -> Bool in
            do { try await manager.addExtra(folder, onNew: { _ in true }, onChange: {}); return true }
            catch { return false }
        } }
        var count = 0
        for task in pending { if await task.value { count += 1 } }
        #expect(count == 3)
        #expect(manager.extraFolders.count == 3)
    }

    @Test func failedUpgradeRestoresPreviousOwnershipSnapshot() throws {
        let dedicated = try directory("Dedicated")
        let oldSaved: [String: Any] = ["location": "/original", "thumbnail": true]
        let oldApplied: [String: Any] = ["location": dedicated.path, "locationScreenshot": dedicated.path, "thumbnail": false]
        defaults.set(oldSaved, forKey: "inboxSavedSettings")
        defaults.set(oldApplied, forKey: "inboxAppliedSettings")
        let system = MemoryScreenshotPreferences()
        system.values = oldApplied.merging(["target": "clipboard", "locationRecording": "/videos"]) { _, value in value }
        let before = system.values
        system.failNextWrite = true
        let inbox = Inbox(defaults: defaults, preferences: system, defaultFolder: dedicated)
        #expect(throws: (any Error).self) { try inbox.apply() }
        #expect(system.values as NSDictionary == before as NSDictionary)
        #expect(defaults.dictionary(forKey: "inboxSavedSettings")! as NSDictionary == oldSaved as NSDictionary)
        #expect(defaults.dictionary(forKey: "inboxAppliedSettings")! as NSDictionary == oldApplied as NSDictionary)
    }

    @Test func stopInvalidatesExtraPreparation() async throws {
        let manager = ScreenshotMonitoring(defaults: defaults)
        let folder = try directory("Pending")
        let pending = Task { try await manager.addExtra(folder, onNew: { _ in Issue.record("停用后不能交付"); return true }, onChange: {}) }
        await Task.yield()
        manager.stop()
        do { try await pending.value } catch is CancellationError {}
        manager.stop()
        #expect(manager.extraFolders.isEmpty)
    }

    @Test func upgradedSettingsSnapshotCapturesOnlyNewlyOwnedKeys() throws {
        let dedicated = try directory("Dedicated")
        let system = MemoryScreenshotPreferences()
        defaults.set(["location": "/original", "thumbnail": true], forKey: "inboxSavedSettings")
        defaults.set(["location": dedicated.path, "locationScreenshot": dedicated.path, "thumbnail": false], forKey: "inboxAppliedSettings")
        system.values = ["location": dedicated.path, "locationScreenshot": dedicated.path, "thumbnail": false,
                         "locationRecording": "/videos", "target": "clipboard", "targetScreenshot": "preview", "targetRecording": "mail"]
        let inbox = Inbox(defaults: defaults, preferences: system, defaultFolder: dedicated)
        try inbox.apply()
        #expect(system.values["target"] as? String == "file")
        #expect(system.values["locationRecording"] as? String == dedicated.path)
        let restarted = Inbox(defaults: defaults, preferences: system, defaultFolder: dedicated)
        try restarted.apply()
        system.values["targetRecording"] = "external"
        try restarted.restore()
        #expect(system.values as NSDictionary == ["location": "/original", "thumbnail": true,
            "locationRecording": "/videos", "target": "clipboard", "targetScreenshot": "preview", "targetRecording": "external"] as NSDictionary)
    }

    private func video(_ ext: String) async throws -> URL {
        let url = root.appendingPathComponent("Original").appendingPathExtension(ext)
        let writer = try AVAssetWriter(outputURL: url, fileType: ext == "mp4" ? .mp4 : .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        try #require(CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32ARGB, nil, &pixel) == kCVReturnSuccess)
        let buffer = try #require(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0x88, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for frame in 0..<30 {
            try await eventually { input.isReadyForMoreMediaData || writer.status == .failed }
            try #require(writer.status != .failed)
            try #require(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 3, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
        return url
    }

    @Test(arguments: ["mov", "mp4"])
    func recordingThumbnailCopyAndTrimPreserveOriginal(_ ext: String) async throws {
        let source = try await video(ext)
        let before = try Data(contentsOf: source)
        let thumb = try #require(makeThumbnail(source, maxPixels: 32))
        let cg = try #require(thumb.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(cg.width <= 32 && cg.height <= 32)
        defaults.set(true, forKey: "soundOff")
        let line = Line(defaults: defaults)
        #expect(line.hang(source, quietly: true) != nil)
        #expect(line.items.first?.isRecording == true)
        #expect(line.previewURLs == [source])
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(ClipboardImage.copy(source, to: board))
        #expect(board.string(forType: .fileURL) == source.absoluteString)
        #expect(board.data(forType: .png) == nil)
        #expect(board.string(forType: ClipboardWatcher.ownType) == "1")
        #expect(try ScreenshotWatcher.list(root).isEmpty)
        #expect(try ScreenshotWatcher.list(root, anyImage: true, recordings: true).map(\.url) == [source])
        let range = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600), duration: CMTime(seconds: 1, preferredTimescale: 600))
        let copy = try await Trim.exportCopy(of: source, range: range)
        let second = try await Trim.exportCopy(of: source, range: range)
        #expect(copy != source && copy != second)
        #expect(try Data(contentsOf: source) == before)
        let duration = try await AVURLAsset(url: copy).load(.duration)
        #expect(duration.seconds > 0 && duration.seconds < 2)
        #expect(makeThumbnail(copy) != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".trimming-") })
    }

    @Test func invalidRecordingRangeDoesNotCreateOrOverwriteFiles() async throws {
        let source = root.appendingPathComponent("bad.mov")
        try Data([1, 2, 3]).write(to: source)
        do {
            _ = try await Trim.exportCopy(of: source, range: CMTimeRange(start: .zero, duration: .zero))
            Issue.record("无效范围应拒绝")
        } catch {}
        #expect(try Data(contentsOf: source) == Data([1, 2, 3]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["bad.mov"])
    }
}
}
