import AppKit
import Testing
@testable import Tendedero

extension IntegrationSuite {
@MainActor
final class CaptureNotificationTests: TestFiles {
    private func image(_ name: String) throws -> URL {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let url = root.appendingPathComponent(name)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    @Test func everyAcceptedCaptureNotifiesAfterPersistenceAtAndBelowCapacity() throws {
        defaults.set(true, forKey: "soundOff")
        let line = Line(defaults: defaults)
        line.maxItems = 2
        defer { line.onCapture = nil }
        var notifications: [[URL]] = []
        line.onCapture = { shouldPeek in
            let live = line.items.filter { !$0.falling }
            #expect(shouldPeek)
            #expect(live.count <= 2)
            #expect(self.defaults.stringArray(forKey: "pegged") == live.map(\.url.path))
            notifications.append(live.map(\.url))
        }
        let urls = try (0..<10).map { try image("\($0).png") }
        for url in urls {
            _ = try #require(line.hang(url, flying: true))
            #expect(notifications.last?.last == url, "Capture event is synchronous")
        }
        #expect(notifications.count == 10)
        #expect(notifications.last == Array(urls.suffix(2)))
        #expect(line.items.filter { !$0.falling }.allSatisfy { $0.flying }, "The event must not start or finish a second flight")
    }

    @Test func previewSwitchIsReadForEachCaptureAndSurvivesRestore() throws {
        defaults.set(true, forKey: "soundOff")
        let line = Line(defaults: defaults)
        var previewRequests: [Bool] = []
        line.onCapture = { previewRequests.append($0) }
        for (n, enabled) in [false, true, false, true].enumerated() {
            line.peeksAtNew = enabled
            _ = try #require(line.hang(image("\(n).png")))
            let restored = Line(defaults: defaults)
            #expect(restored.peeksAtNew == enabled, "Initial restored preview uses the same preference")
        }
        #expect(previewRequests == [false, true, false, true])
    }

    @Test func duplicatesUnreadableQuietRestoreAndThumbnailUpdatesDoNotNotify() throws {
        defaults.set(true, forKey: "soundOff")
        let line = Line(defaults: defaults)
        let url = try image("capture.png")
        var count = 0
        line.onCapture = { _ in count += 1 }
        let id = try #require(line.hang(url))
        #expect(line.hang(url) == nil)
        let alias = root.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        #expect(line.hang(alias) == nil)
        #expect(line.hang(root.appendingPathComponent("missing.png")) == nil)
        let broken = root.appendingPathComponent("unfinished.png")
        try Data().write(to: broken)
        #expect(line.hang(broken) == nil)
        line.drop(id, quietly: true)
        _ = try #require(line.hang(url, quietly: true))
        let restored = Line(defaults: defaults)
        restored.onCapture = { _ in count += 1 }
        restored.reloadThumbnail(for: url)
        #expect(restored.liveCount == 1 && count == 1)
    }
}
}
