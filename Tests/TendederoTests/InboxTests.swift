import Foundation
import Testing
@testable import Tendedero

/// No test reads or writes com.apple.screencapture, starts the application,
/// changes login items, or moves a file into the user's Trash.
final class MemoryScreenshotPreferences: ScreenshotPreferences {
    var values: [String: Any] = [:]
    var writes = 0
    var failNextWrite = false
    var writesToFail = 0

    func read() -> [String: Any] { values }
    func write(_ values: [String: Any]) throws {
        writes += 1
        self.values = values // Model a partially applied write too.
        if failNextWrite || writesToFail > 0 {
            failNextWrite = false
            writesToFail = max(0, writesToFail - 1)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

class TestFiles {
    var root: URL!
    var defaults: UserDefaults!
    private var suite: String!

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("TendederoTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath().standardizedFileURL
        suite = "TendederoTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

final class InboxTests: TestFiles {
    private var system: MemoryScreenshotPreferences!
    private var inbox: Inbox!
    private var dedicated: URL!

    override init() throws {
        try super.init()
        system = MemoryScreenshotPreferences()
        dedicated = root.appendingPathComponent("Dedicated", isDirectory: true)
        inbox = Inbox(defaults: defaults, preferences: system, defaultFolder: dedicated)
    }

    @Test func testDisabledSelectionPersistsWithoutChangingSystem() throws {
        let custom = try directory("Custom")
        try inbox.selectFolder(custom)
        #expect((inbox.folder) == (custom))
        #expect((system.writes) == (0))
        #expect(defaults.dictionary(forKey: "inboxSavedSettings") == nil)
        let restarted = Inbox(defaults: defaults, preferences: system, defaultFolder: dedicated)
        #expect((restarted.folder) == (custom))
        #expect(!(restarted.isEnabled))
        #expect((try FileManager.default.contentsOfDirectory(atPath: custom.path)) == ([]))
    }

    @Test func testMultipleSwitchesAndResetKeepOriginalSnapshotAndFiles() throws {
        let original: [String: Any] = ["location": "/previous/legacy", "locationScreenshot": "/previous/modern", "thumbnail": true]
        system.values = original
        try inbox.apply()
        inbox.isEnabled = true
        let oldFile = dedicated.appendingPathComponent("old.png")
        try Data([1]).write(to: oldFile)
        for destination in [try directory("One"), try directory("Two"), dedicated!] {
            try inbox.selectFolder(destination)
            #expect((system.values["location"] as? String) == (destination.path))
            #expect((system.values["locationScreenshot"] as? String) == (destination.path))
            #expect((defaults.dictionary(forKey: "inboxSavedSettings")! as NSDictionary) == (original as NSDictionary))
        }
        #expect((try Data(contentsOf: oldFile)) == (Data([1])))
        try inbox.restore()
        #expect((system.values as NSDictionary) == (original as NSDictionary))
        #expect(defaults.object(forKey: "inboxSavedSettings") == nil)
        #expect(defaults.object(forKey: "inboxAppliedSettings") == nil)
    }

    @Test func testAbsentPreferencesAreRemovedOnRestore() throws {
        try inbox.apply()
        try inbox.restore()
        #expect(system.values.isEmpty)
    }

    @Test func testRestartDuringTakeoverDoesNotResnapshotAppValues() throws {
        system.values = ["location": "/original", "thumbnail": true]
        try inbox.apply()
        inbox.isEnabled = true
        let custom = try directory("Custom")
        try inbox.selectFolder(custom)
        let restarted = Inbox(defaults: defaults, preferences: system, defaultFolder: dedicated)
        #expect(restarted.isEnabled)
        #expect((restarted.folder) == (custom))
        try restarted.apply()
        try restarted.restore()
        #expect((system.values as NSDictionary) == (["location": "/original", "thumbnail": true] as NSDictionary))
    }

    @Test func testNormalQuitAndRelaunchTakesFreshSnapshot() throws {
        system.values = ["location": "/first"]
        try inbox.apply()
        inbox.isEnabled = true
        try inbox.selectFolder(directory("Custom"))
        try inbox.restore()
        system.values = ["locationScreenshot": "/changed-while-quit"]
        let restarted = Inbox(defaults: defaults, preferences: system, defaultFolder: dedicated)
        try restarted.apply()
        try restarted.restore()
        #expect((system.values as NSDictionary) == (["locationScreenshot": "/changed-while-quit"] as NSDictionary))
    }

    @Test func testEachExternallyChangedKeySurvivesRestore() throws {
        for changed in ["location", "locationScreenshot", "thumbnail"] {
            let original: [String: Any] = ["location": "/original-legacy", "locationScreenshot": "/original-modern", "thumbnail": false]
            system.values = original
            try inbox.apply()
            let external: Any = changed == "thumbnail" ? true : "/external"
            system.values[changed] = external
            var expected = original
            expected[changed] = external
            try inbox.restore()
            #expect((system.values as NSDictionary) == (expected as NSDictionary))
        }
    }

    @Test func testExternallyRemovedKeysStayRemoved() throws {
        for key in ["location", "locationScreenshot", "thumbnail"] {
            let original: [String: Any] = ["location": "/old", "locationScreenshot": "/old", "thumbnail": true]
            system.values = original
            try inbox.apply()
            system.values.removeValue(forKey: key)
            var expected = original
            expected.removeValue(forKey: key)
            try inbox.restore()
            #expect(system.values as NSDictionary == expected as NSDictionary)
        }
    }

    @Test func testLegacySnapshotRestoresEachKeyIndependently() throws {
        defaults.set(["location": "/original", "thumbnail": true], forKey: "inboxSavedSettings")
        system.values = ["location": "/external", "locationScreenshot": dedicated.path, "thumbnail": false]
        try inbox.restore()
        #expect((system.values as NSDictionary) == (["location": "/external", "thumbnail": true] as NSDictionary))
    }

    @Test func testInvalidAndUnwritableSelectionLeaveConfigurationIntact() throws {
        try inbox.apply()
        inbox.isEnabled = true
        let original = system.values
        let file = root.appendingPathComponent("file.png")
        try Data([1]).write(to: file)
        let locked = try directory("Locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        for invalid in [root.appendingPathComponent("Missing"), file, locked, URL(string: "https://example.com")!] {
            #expect(throws: (any Error).self) { try inbox.selectFolder(invalid) }
            #expect((inbox.folder) == (dedicated))
            #expect((system.values as NSDictionary) == (original as NSDictionary))
            #expect(inbox.isEnabled)
        }
    }

    @Test func testDisconnectedCustomFolderIsNotRecreatedAtRestart() throws {
        let custom = try directory("Volume")
        try inbox.selectFolder(custom)
        inbox.isEnabled = true
        try FileManager.default.removeItem(at: custom)
        let restarted = Inbox(defaults: defaults, preferences: system, defaultFolder: dedicated)
        #expect(throws: (any Error).self) { try restarted.apply() }
        #expect((system.writes) == (0))
        #expect((restarted.folder) == (custom))
        #expect(!(FileManager.default.fileExists(atPath: custom.path)))
    }

    @Test func testFailedSystemWriteRollsBackDestinationAndSnapshot() throws {
        system.values = ["location": "/original"]
        try inbox.apply()
        inbox.isEnabled = true
        let original = system.values
        let snapshot = defaults.dictionary(forKey: "inboxSavedSettings")!
        system.failNextWrite = true
        #expect(throws: (any Error).self) { try inbox.selectFolder(directory("Custom")) }
        #expect((inbox.folder) == (dedicated))
        #expect((system.values as NSDictionary) == (original as NSDictionary))
        #expect((defaults.dictionary(forKey: "inboxSavedSettings")! as NSDictionary) == (snapshot as NSDictionary))
        try inbox.restore()
        #expect((system.values as NSDictionary) == (["location": "/original"] as NSDictionary))
    }

    @Test func testFailedFirstApplyAndRestoreCanBeRetried() throws {
        system.values = ["location": "/original"]
        system.failNextWrite = true
        #expect(throws: (any Error).self) { try inbox.apply() }
        #expect(defaults.object(forKey: "inboxSavedSettings") == nil)
        #expect((system.values as NSDictionary) == (["location": "/original"] as NSDictionary))
        try inbox.apply()
        system.failNextWrite = true
        #expect(throws: (any Error).self) { try inbox.restore() }
        #expect(defaults.object(forKey: "inboxSavedSettings") != nil)
        #expect((system.values["location"] as? String) == (dedicated.path))
        try inbox.restore()
        #expect((system.values as NSDictionary) == (["location": "/original"] as NSDictionary))
    }
    @Test func failedWriteAndRollbackKeepRecoverySnapshot() throws {
        system.values = ["location": "/original", "thumbnail": true]
        system.writesToFail = 2
        #expect(throws: (any Error).self) { try inbox.apply() }
        #expect(defaults.dictionary(forKey: "inboxSavedSettings") != nil)
        #expect(defaults.dictionary(forKey: "inboxAppliedSettings") != nil)
        try inbox.restore()
        #expect(system.values as NSDictionary == ["location": "/original", "thumbnail": true] as NSDictionary)
        #expect(defaults.dictionary(forKey: "inboxSavedSettings") == nil)
    }

    @Test func externalChangeDuringWatcherPreparationAbortsRestoreWithoutWriting() throws {
        system.values = ["location": "/original", "thumbnail": true]
        try inbox.apply()
        let planned = inbox.restoredSettings()
        system.values["locationScreenshot"] = "/external-during-prepare"
        let writes = system.writes
        #expect(throws: (any Error).self) { try inbox.restore(expectedSettings: planned) }
        #expect(system.writes == writes)
        #expect(defaults.dictionary(forKey: "inboxSavedSettings") != nil)
        try inbox.restore()
        #expect(system.values["locationScreenshot"] as? String == "/external-during-prepare")
    }

}
