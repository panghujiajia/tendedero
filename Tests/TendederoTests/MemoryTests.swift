import AppKit
import ImageIO
import Testing
@testable import Tendedero

extension IntegrationSuite {
final class MemoryTests {
    private func image(width: Int = 4000, height: Int = 3000) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try image(), nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    @MainActor
    @Test
    func testDefaultThumbnailMatchesDisplayBudget() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let thumb = try #require(makeThumbnail(url))
        let cg = try #require(thumb.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        #expect((cg.width) <= (Int(ceil((Layout.cardWidth - 14) * scale))))
        #expect(abs((Double(cg.width) / Double(cg.height)) - (4.0 / 3.0)) <= 0.01)
    }

    @MainActor
    @Test
    func testExplicitThumbnailBudgetAndInvalidInput() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let thumb = try #require(makeThumbnail(url, maxPixels: 160))
        let cg = try #require(thumb.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect((cg.width) == (160))
        #expect((cg.height) == (120))
        #expect(makeThumbnail(url.appendingPathExtension("missing")) == nil)
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TENDEDERO_UI_TESTS"] == "1"))
    func testConcurrentFallsShareCroppedWindowAndReleaseIt() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let cg = try image(width: 100, height: 80)
        let card = CGRect(x: screen.frame.midX, y: screen.frame.midY, width: 100, height: 80)
        weak var overlay: NSWindow?
        autoreleasepool {
            for n in 0..<3 {
                CaptureFlight.fall(image: cg, card: card.offsetBy(dx: CGFloat(n * 110), dy: 0), tilt: 2, on: screen)
            }
            #expect((NSApp.windows.filter { !existing.contains(ObjectIdentifier($0)) }.count) == (1))
            overlay = NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) }
            #expect((overlay?.frame.width ?? screen.frame.width) < (screen.frame.width))
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        }
        #expect(overlay == nil, "Idle overlays must release their window and backing surfaces")
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TENDEDERO_UI_TESTS"] == "1"))
    func testArrivalCompletesOnceAndReleasesOverlayAfterFade() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let rect = CGRect(x: screen.frame.midX, y: screen.frame.midY, width: 100, height: 80)
        var completions = 0
        weak var overlay: NSWindow?
        try autoreleasepool {
            CaptureFlight.fly(image: try image(width: 100, height: 80), from: rect,
                              to: rect.offsetBy(dx: 20, dy: 50), tilt: 2, on: screen) { completions += 1 }
            overlay = NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) }
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        }
        #expect((completions) == (1))
        #expect(overlay == nil)
    }
    @Test
    func testPNGEncodingPreservesPixelsAndTransparency() throws {
        let c = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        c.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let original = try #require(c.makeImage())
        let data = try #require(pngData(original))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect((decoded.width) == (64))
        #expect((decoded.height) == (32))
        let comparison = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
            bytesPerRow: c.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        comparison.draw(decoded, in: CGRect(x: 0, y: 0, width: 64, height: 32))
        let length = c.bytesPerRow * c.height
        #expect((Data(bytes: try #require(c.data), count: length)) == (Data(bytes: try #require(comparison.data), count: length)))
    }

    @Test
    func testPNGOriginalIsCopiedWithoutReencoding() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect((try #require(pngData(url))) == (try Data(contentsOf: url)))
    }

    @MainActor
    @Test
    func testRotatedJPEGKeepsOrientationAndFullResolutionWhenCopied() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let colored = try #require(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        colored.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        colored.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        colored.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        colored.fill(CGRect(x: 200, y: 0, width: 200, height: 300))
        CGImageDestinationAddImage(dest, try #require(colored.makeImage()),
                                  [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let data = try #require(pngData(url))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect((decoded.width) == (300))
        #expect((decoded.height) == (400))
        // Compare rendered colors with AppKit's established orientation handling.
        let tiff = try #require(NSImage(contentsOf: url)?.tiffRepresentation)
        let reference = try #require(NSBitmapImageRep(data: tiff)?.cgImage)
        #expect((reference.width) == (decoded.width))
        #expect((reference.height) == (decoded.height))
        func rgba(_ image: CGImage) throws -> Data {
            let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Data(bytes: try #require(context.data), count: context.bytesPerRow * context.height)
        }
        let expectedPixels = try rgba(reference)
        let actualPixels = try rgba(decoded)
        for (x, y) in [(30, 30), (270, 30), (30, 370), (270, 370)] {
            let offset = (y * decoded.width + x) * 4
            for component in 0..<3 {
                #expect(abs((Int(actualPixels[offset + component])) - (Int(expectedPixels[offset + component]))) <= 3)
            }
        }
        let thumb = try #require(makeThumbnail(url))
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        #expect((thumb.size.height) <= (ceil(104 * scale)))
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TENDEDERO_UI_TESTS"] == "1"))
    func testCaptureBurstBoundsArrivalsAndStillCompletesEveryCard() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let rect = CGRect(x: screen.frame.midX, y: screen.frame.midY, width: 100, height: 80)
        let cg = try image(width: 100, height: 80)
        var completions = 0
        autoreleasepool {
            for _ in 0..<10 {
                CaptureFlight.fly(image: cg, from: rect, to: rect, tilt: 0, on: screen) { completions += 1 }
            }
            #expect(!(CaptureFlight.canFly))
            #expect((completions) == (8), "Excess captures must land without retaining more flight images")
            RunLoop.main.run(until: Date().addingTimeInterval(1))
        }
        #expect((completions) == (10))
        #expect(CaptureFlight.canFly)
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TENDEDERO_UI_TESTS"] == "1"))
    func testCompletionCanStartAnotherFlightInSameOverlay() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let rect = CGRect(x: screen.frame.midX, y: screen.frame.midY, width: 100, height: 80)
        let cg = try image(width: 100, height: 80)
        var completions = 0
        autoreleasepool {
            CaptureFlight.fly(image: cg, from: rect, to: rect, tilt: 0, on: screen) {
                completions += 1
                CaptureFlight.fly(image: cg, from: rect, to: rect, tilt: 0, on: screen) { completions += 1 }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1.7))
        }
        #expect((completions) == (2))
        #expect(CaptureFlight.canFly)
    }

    @MainActor
    @Test
    func testWatcherOnlyReportsNewImagesInCreationOrder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appendingPathComponent("existing.png")
        try Data([1]).write(to: old)
        try FileManager.default.setAttributes([.creationDate: Date.distantPast], ofItemAtPath: old.path)
        var received: [String] = []
        let watcher = ScreenshotWatcher(folder: folder, onNew: { received.append($0.lastPathComponent); return true }, onChange: {})
        for name in ["first.png", "notes.txt", "second.jpg"] {
            try Data([1]).write(to: folder.appendingPathComponent(name))
        }
        try await watcher.prepare(includeRecent: true)
        watcher.start()
        defer { watcher.stop() }
        #expect((received) == (["first.png", "second.jpg"]))
        try Data([1]).write(to: folder.appendingPathComponent("third.png"))
        try await Task.sleep(for: .milliseconds(500))
        #expect((received) == (["first.png", "second.jpg", "third.png"]))
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TENDEDERO_UI_TESTS"] == "1"))
    func testCroppedOverlayPreservesScreenCoordinatesWhenGrowingAndShrinking() throws {
        _ = NSApplication.shared
        for screen in NSScreen.screens {
            try autoreleasepool {
                let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
                let cg = try image(width: 100, height: 80)
                let firstCard = CGRect(x: screen.frame.midX + 100, y: screen.frame.midY, width: 100, height: 80)
                let firstBefore = CACurrentMediaTime()
                CaptureFlight.fall(image: cg, card: firstCard, tilt: 2, on: screen)
                let firstAfter = CACurrentMediaTime()
                let window = try #require(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) })
                let root = try #require(window.contentView?.layer)
                let firstLayer = try #require(root.sublayers?.first)
                #expect(abs((window.frame.minX + firstLayer.position.x) - (firstCard.midX)) <= 0.1)
                #expect(abs((window.frame.minY + firstLayer.position.y) - (firstCard.maxY)) <= 0.1)
                #expect((firstLayer.bounds.size) == (firstCard.size))
                #expect(abs((firstLayer.affineTransform().b) - (sin(-2 * .pi / 180))) <= 0.0001)
                let initialOrigin = window.frame.origin
                RunLoop.main.run(until: Date().addingTimeInterval(0.12))
                let secondCard = firstCard.offsetBy(dx: -350, dy: 0)
                let secondBefore = CACurrentMediaTime()
                CaptureFlight.fall(image: cg, card: secondCard, tilt: -2, on: screen)
                let secondAfter = CACurrentMediaTime()
                let secondLayer = try #require(root.sublayers?.last)
                #expect((window.frame.origin) != (initialOrigin))
                #expect(abs((window.frame.minX + firstLayer.position.x) - (firstCard.midX)) <= 0.1)
                let y = window.frame.minY + firstLayer.position.y
                let earliestY = firstCard.maxY - 520 * pow((secondAfter - firstBefore) / 0.55, 3)
                let latestY = firstCard.maxY - 520 * pow((secondBefore - firstAfter) / 0.55, 3)
                #expect((y) >= (earliestY - 1))
                #expect((y) <= (latestY + 1))
                #expect(abs((window.frame.minX + secondLayer.position.x) - (secondCard.midX)) <= 0.1)
                #expect(abs((window.frame.minY + secondLayer.position.y) - (secondCard.maxY)) <= 0.1)
                let expandedWidth = window.frame.width
                RunLoop.main.run(until: Date().addingTimeInterval(0.48))
                #expect(firstLayer.superlayer == nil)
                #expect(secondLayer.superlayer === root)
                #expect((window.frame.width) < (expandedWidth))
                #expect(abs((window.frame.minX + secondLayer.position.x) - (secondCard.midX)) <= 0.1)
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            }
        }
    }

    @MainActor
    @Test
    func testMarkupWritesPNGDirectlyAndReplacesExistingFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("edited.png")
        try Data([1, 2, 3]).write(to: target)
        let cg = try image(width: 64, height: 32)
        try writePNG(NSImage(cgImage: cg, size: CGSize(width: 32, height: 16)), to: target)
        let source = try #require(CGImageSourceCreateWithURL(target as CFURL, nil))
        let result = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect((result.width) == (64))
        #expect((result.height) == (32))
        #expect((try FileManager.default.contentsOfDirectory(atPath: folder.path)) == (["edited.png"]))
    }

    @Test
    func testAtomicFileCopyPreservesSourceAndTargetOnFailure() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.png")
        let target = folder.appendingPathComponent("target.png")
        let original = Data([1, 2, 3]), edited = Data([4, 5, 6])
        try original.write(to: target)
        #expect(throws: (any Error).self) { try replaceFileContents(from: source, to: target) }
        #expect((try Data(contentsOf: target)) == (original))
        try edited.write(to: source)
        try replaceFileContents(from: source, to: target)
        #expect((try Data(contentsOf: target)) == (edited))
        #expect((try Data(contentsOf: source)) == (edited))
        try FileManager.default.removeItem(at: target)
        try replaceFileContents(from: source, to: target)
        #expect((try Data(contentsOf: target)) == (edited))
        #expect((Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))) == (["source.png", "target.png"]))
    }

    @MainActor
    @Test
    func testDeferredClipboardKeepsSnapshotAfterOriginalChangesOrIsDeleted() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = try Data(contentsOf: url)
        let board = NSPasteboard.withUniqueName()
        defer { board.clearContents(); board.releaseGlobally() }
        #expect(ClipboardImage.copy(url, to: board))
        #expect(board.types?.contains(.png) == true)
        #expect((board.string(forType: .fileURL)) == (url.absoluteString))
        try Data([1, 2, 3]).write(to: url)
        try FileManager.default.removeItem(at: url)
        #expect((board.data(forType: .png)) == (expected))
    }

    @MainActor
    @Test
    func testDeferredClipboardMaterializesBeforeQuit() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = try Data(contentsOf: url)
        let board = NSPasteboard.withUniqueName()
        defer { board.clearContents(); board.releaseGlobally() }
        #expect(ClipboardImage.copy(url, to: board))
        ClipboardImage.materializeForExit()
        try FileManager.default.removeItem(at: url)
        #expect((board.data(forType: .png)) == (expected))
    }

    @MainActor
    @Test
    func testDeferredClipboardDoesNotOverwriteNewOwnersContentsOnQuit() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let board = NSPasteboard.withUniqueName()
        defer { board.clearContents(); board.releaseGlobally() }
        #expect(ClipboardImage.copy(url, to: board))
        board.clearContents()
        board.setString("new owner", forType: .string)
        ClipboardImage.materializeForExit()
        #expect((board.string(forType: .string)) == ("new owner"))
        #expect(board.data(forType: .png) == nil)
    }

    @MainActor
    @Test
    func testDeferredClipboardReplacesSnapshotsAndCleansUpWhenCleared() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        func snapshots() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
                .filter { $0.hasPrefix("tendedero-clipboard-") })
        }
        let existing = try snapshots()
        let board = NSPasteboard.withUniqueName()
        defer { board.clearContents(); board.releaseGlobally() }
        #expect(ClipboardImage.copy(url, to: board))
        #expect((try snapshots().subtracting(existing).count) == (1))
        #expect(ClipboardImage.copy(url, to: board))
        #expect((try snapshots().subtracting(existing).count) == (1))
        // Old completion cleanup must not forget the latest promised image.
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        ClipboardImage.materializeForExit()
        #expect((board.data(forType: .png)) == (try Data(contentsOf: url)))
        #expect(try snapshots().subtracting(existing).isEmpty)
        #expect(ClipboardImage.copy(url, to: board))
        board.clearContents()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        #expect(try snapshots().subtracting(existing).isEmpty)
    }

    @MainActor
    @Test
    func testDeferredJPEGClipboardPreservesFullResolution() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try image(width: 400, height: 300), nil)
        #expect(CGImageDestinationFinalize(dest))
        let board = NSPasteboard.withUniqueName()
        defer { board.clearContents(); board.releaseGlobally() }
        #expect(ClipboardImage.copy(url, to: board))
        try FileManager.default.removeItem(at: url)
        let data = try #require(board.data(forType: .png))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let result = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect((result.width) == (400))
        #expect((result.height) == (300))
    }

    @MainActor
    @Test
    func testDeferredClipboardSnapshotsRelativeSymlinkContents() throws {
        let url = try fixture()
        let link = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: link); try? FileManager.default.removeItem(at: url) }
        let expected = try Data(contentsOf: url)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: url.lastPathComponent)
        let board = NSPasteboard.withUniqueName()
        defer { board.clearContents(); board.releaseGlobally() }
        #expect(ClipboardImage.copy(link, to: board))
        #expect((board.string(forType: .fileURL)) == (link.absoluteString))
        try FileManager.default.removeItem(at: url)
        #expect((board.data(forType: .png)) == (expected))
    }

    @Test
    func testAtomicFileCopyResolvesRelativeSymlink() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.png")
        let link = folder.appendingPathComponent("link.png")
        let destinationFolder = folder.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let target = destinationFolder.appendingPathComponent("target.png")
        let data = Data([1, 2, 3])
        try data.write(to: source)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: source.lastPathComponent)
        try replaceFileContents(from: link, to: target)
        try FileManager.default.removeItem(at: source)
        #expect((try Data(contentsOf: target)) == (data))
    }

}

}
