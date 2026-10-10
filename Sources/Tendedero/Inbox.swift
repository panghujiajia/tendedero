import Foundation

/// The three settings we borrow from macOS. Keeping this small boundary
/// injectable lets tests exercise takeover without touching system preferences.
protocol ScreenshotPreferences {
    func read() -> [String: Any]
    func write(_ values: [String: Any]) throws
}

struct SystemScreenshotPreferences: ScreenshotPreferences {
    private let domain = "com.apple.screencapture" as CFString
    // macOS 27 uses location-screenshot; older versions use location.
    private let keys = ["location": "location", "locationScreenshot": "location-screenshot",
                        "thumbnail": "show-thumbnail"]

    func read() -> [String: Any] {
        CFPreferencesAppSynchronize(domain)
        return keys.compactMapValues { CFPreferencesCopyAppValue($0 as CFString, domain) }
    }

    func write(_ values: [String: Any]) throws {
        for (name, key) in keys {
            CFPreferencesSetAppValue(key as CFString, values[name] as CFPropertyList?, domain)
        }
        guard CFPreferencesAppSynchronize(domain) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// Inbox mode borrows the screenshot location and floating-thumbnail setting.
/// The selected folder is separate from the dedicated folder whose files the
/// app owns. Changing a destination never gives us ownership of its contents.
final class Inbox {
    static let shared = Inbox()
    static let defaultFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Tendedero/Screenshots", isDirectory: true)

    private let defaults: UserDefaults
    private let preferences: ScreenshotPreferences
    private let defaultDestination: URL
    private let enabledKey = "inboxEnabled"
    private let offeredKey = "inboxOffered"
    private let savedKey = "inboxSavedSettings"
    private let appliedKey = "inboxAppliedSettings"
    private let folderKey = "inboxFolder"

    init(defaults: UserDefaults = .standard,
         preferences: ScreenshotPreferences = SystemScreenshotPreferences(),
         defaultFolder: URL = Inbox.defaultFolder) {
        self.defaults = defaults
        self.preferences = preferences
        defaultDestination = defaultFolder
    }

    var folder: URL {
        guard let path = defaults.string(forKey: folderKey) else { return defaultDestination }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    var wasOffered: Bool {
        get { defaults.bool(forKey: offeredKey) }
        set { defaults.set(newValue, forKey: offeredKey) }
    }

    /// Only the built-in, dedicated folder has the original discard-to-Trash
    /// behavior, even after switching destinations or restarting the app.
    static func owns(_ url: URL, in dedicatedFolder: URL = defaultFolder) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL.path
            .hasPrefix(dedicatedFolder.resolvingSymlinksInPath().standardizedFileURL.path + "/")
    }

    /// Check both reading and actually creating a file before changing any
    /// preferences. Missing custom folders must not be silently recreated.
    func validateFolder(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        if url == defaultDestination.resolvingSymlinksInPath().standardizedFileURL {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        _ = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        let probe = url.appendingPathComponent(".tendedero-write-check-\(UUID().uuidString)")
        try Data().write(to: probe, options: .withoutOverwriting)
        try fm.removeItem(at: probe)
        return url
    }

    func selectFolder(_ url: URL) throws {
        let destination = try validateFolder(url)
        try selectValidatedFolder(destination)
    }

    /// Called only after asynchronous folder validation and watcher preparation.
    func selectValidatedFolder(_ destination: URL) throws {
        if isEnabled { try applyValidated(to: destination) }
        defaults.set(destination.resolvingSymlinksInPath().standardizedFileURL.path, forKey: folderKey)
    }

    func apply(to destination: URL? = nil) throws {
        let destination = try validateFolder(destination ?? folder)
        try applyValidated(to: destination)
    }

    func applyValidated(to destination: URL) throws {
        let before = preferences.read()
        let saved = defaults.dictionary(forKey: savedKey)
        // One snapshot for the whole takeover, not one per destination. An
        // existing snapshot also survives a crash or an upgrade from v1.
        if saved == nil { defaults.set(before, forKey: savedKey) }
        let applied: [String: Any] = ["location": destination.path,
                                      "locationScreenshot": destination.path, "thumbnail": false]
        let previousApplied = defaults.dictionary(forKey: appliedKey)
        // Persist recovery information before writing through cfprefsd.
        defaults.set(applied, forKey: appliedKey)
        do {
            try preferences.write(applied)
        } catch {
            try preferences.write(before)
            if let previousApplied { defaults.set(previousApplied, forKey: appliedKey) }
            else { defaults.removeObject(forKey: appliedKey) }
            if saved == nil { defaults.removeObject(forKey: savedKey) }
            throw error
        }
    }

    func restoredSettings() -> [String: Any] {
        guard let saved = defaults.dictionary(forKey: savedKey) else { return preferences.read() }
        // Older releases saved the snapshot but not their last write. They
        // could only have written the built-in destination and false.
        let applied = defaults.dictionary(forKey: appliedKey) ?? [
            "location": defaultDestination.path, "locationScreenshot": defaultDestination.path,
            "thumbnail": false,
        ]
        let before = preferences.read()
        var restored = before
        for (key, value) in applied {
            // Compare each key independently: an external change to either
            // location (or the thumbnail) belongs to the user and stays put.
            if let current = before[key] as? NSObject, current.isEqual(value) {
                restored[key] = saved[key]
            }
        }
        return restored
    }

    func restore(expectedSettings: [String: Any]? = nil) throws {
        guard defaults.dictionary(forKey: savedKey) != nil else { return }
        let before = preferences.read()
        let restored = restoredSettings()
        // The replacement watcher was prepared asynchronously. If the user
        // changed settings meanwhile, leave them alone and let them retry.
        if let expectedSettings, !(restored as NSDictionary).isEqual(to: expectedSettings) {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            try preferences.write(restored)
        } catch {
            try preferences.write(before)
            throw error
        }
        defaults.removeObject(forKey: savedKey)
        defaults.removeObject(forKey: appliedKey)
    }
}
