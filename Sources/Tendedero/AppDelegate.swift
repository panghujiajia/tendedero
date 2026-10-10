import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let line = Line()
    private let inbox = Inbox.shared
    private let monitoring = ScreenshotMonitoring()
    private var clipboardWatcher: ClipboardWatcher!
    private let hiding = DelayedHide()
    private var hotZoneScreen: NSScreen?
    private var panel: LinePanel!
    private var statusItem: NSStatusItem!
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?

    /// Whether a line is available to reveal on this screen.
    private var isPresent = false
    /// Whether the line has slid down into view.
    private var isRevealed = false
    /// Opened on purpose with the shortcut or the menu: it stays down until
    /// the cursor has visited it and left, or the shortcut is pressed again.
    private var pinned = false
    /// A new screenshot shows itself for a moment, then tucks away.
    private var peekUntil = Date.distantPast
    private var hotZoneSince: Date?
    /// After a click in the menu bar the line stays up there hidden until the
    /// pointer leaves the menu bar, so it does not come back over a menu.
    private var menuBarSuppressed = false
    private var clickMonitors: [Any] = []
    private var awaySince: Date?
    /// Whether the line should be up, if nothing prevents it. A full screen
    /// app on that screen does: the line waits until you leave full screen.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false
    /// The screen a new capture was taken on: the line goes there.
    private var pendingScreen: NSScreen?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        panel = LinePanel(content: host)
        panel.placeOnScreen()
        updateCapacity()
        line.onCapture = { [weak self] shouldPeek in self?.captureAdded(shouldPeek: shouldPeek) }

        restoreSettingsOnTermination()
        startMonitoring()
        clipboardWatcher = ClipboardWatcher { [weak self] url in self?.hangCapture(url) }
        if ClipboardWatcher.isEnabled { clipboardWatcher.start() }

        hotKey = HotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey) { [weak self] in
            self?.toggle()
        }

        setUpStatusItem()
        watchMenuBarClicks()
        watchScrollZoom()

        Markup.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        line.onFall = { [weak self] item in self?.fall(item) }

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)
        if line.liveCount > 0 { captureAdded(shouldPeek: line.peeksAtNew) }

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh() }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.placeOnScreen()
                self?.updateCapacity()
                // A newly connected Retina display needs sharper thumbnails;
                // disconnecting one lets their pixel buffers shrink again.
                if let self {
                    for item in self.line.items where !item.falling {
                        self.line.reloadThumbnail(for: item.url)
                    }
                }
            }
        }

        if !inbox.wasOffered || !ClipboardWatcher.wasOffered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                if !self.inbox.wasOffered { self.offerInbox() }
                if !ClipboardWatcher.wasOffered { self.offerClipboard() }
            }
        }

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            keepOpen = true
            wanted = true
            refresh()
            reveal(pinned: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.line.liveCount == 0 else { return }
                self.keepOpen = false
                self.wanted = false
                self.refresh()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardImage.materializeForExit()
        monitoring.stop()
        restoreInbox()
    }

    // MARK: Inbox mode

    private func startMonitoring() {
        Task {
            do {
                if inbox.isEnabled {
                    try await replaceWatcher(folder: inbox.folder, validate: true, includeRecent: true) {
                        try self.inbox.applyValidated(to: self.inbox.folder)
                    }
                } else {
                    try inbox.restore()
                    try await replaceWatcher(folder: ScreenshotWatcher.screenshotFolder(), includeRecent: true)
                }
            } catch is CancellationError {
            } catch {
                restoreInbox()
                inbox.isEnabled = false
                try? await replaceWatcher(folder: ScreenshotWatcher.screenshotFolder(), includeRecent: true)
                showFolderError(error)
            }
        }
    }

    private func replaceWatcher(folder: URL, validate: Bool = false, includeRecent: Bool = false,
                                configure: @escaping () throws -> Void = {}) async throws {
        try await monitoring.replace(folder: folder, includeRecent: includeRecent,
            validate: validate ? { try self.inbox.validateFolder($0) } : nil,
            configure: configure,
            onNew: { [weak self] in self?.hangCapture($0) ?? false },
            onChange: { [weak self] in self?.line.prune() })
        monitoring.watchDesktopIfNeeded(enabled: inbox.isEnabled,
            onNew: { [weak self] in self?.hangCapture($0) ?? false },
            onChange: { [weak self] in self?.line.prune() })
    }

    private func setInbox(_ on: Bool) {
        Task {
            do {
                if on {
                    try await replaceWatcher(folder: inbox.folder, validate: true) {
                        try self.inbox.applyValidated(to: self.inbox.folder)
                        self.inbox.isEnabled = true
                    }
                } else {
                    let settings = inbox.restoredSettings()
                    let folder = ScreenshotWatcher.screenshotFolder(settings: settings)
                    try await replaceWatcher(folder: folder) {
                        try self.inbox.restore(expectedSettings: settings)
                        self.inbox.isEnabled = false
                    }
                }
            } catch is CancellationError {
            } catch { showFolderError(error) }
        }
    }

    private func chooseScreenshotFolder() {
        let picker = NSOpenPanel()
        picker.title = L("Choose screenshots folder")
        picker.message = L("New screenshots will be saved here while Handle screenshots is on. Existing files stay where they are.")
        picker.prompt = L("Choose")
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.canCreateDirectories = true
        picker.directoryURL = inbox.folder
        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK, let folder = picker.url else { return }
        selectScreenshotFolder(folder)
    }

    private func selectScreenshotFolder(_ folder: URL) {
        Task {
            do {
                if inbox.isEnabled {
                    try await replaceWatcher(folder: folder, validate: true) {
                        try self.inbox.selectValidatedFolder(folder)
                    }
                } else {
                    try await monitoring.validateSelection(folder, validate: { try self.inbox.validateFolder($0) }) {
                        try self.inbox.selectValidatedFolder($0)
                    }
                }
            } catch is CancellationError {
            } catch { showFolderError(error) }
        }
    }

    private func showFolderError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("Could not use the screenshots folder")
        alert.informativeText = L("Choose an available folder you can read and write to, then try again.")
            + "\n\n" + error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func restoreInbox() {
        do { try inbox.restore() }
        catch { log.error("Could not restore screenshot settings: \(error.localizedDescription, privacy: .public)") }
    }

    /// Asked once. Changing system settings is the user's call, never ours.
    private func offerInbox() {
        inbox.wasOffered = true
        let alert = NSAlert()
        alert.messageText = L("Let Tendedero handle your screenshots?")
        alert.informativeText = L(
            "New screenshots will be saved in the chosen folder and hang instantly, without the floating thumbnail. The cross moves files in Tendedero’s own folder to the Trash; in other folders, it only takes them down. You can turn this off from the menu bar, and your previous settings come back when Tendedero quits.")
        alert.addButton(withTitle: L("Turn on"))
        alert.addButton(withTitle: L("Not now"))
        if let icon = NSImage(named: "Tendedero") ?? NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setInbox(true) }
    }

    private func offerClipboard() {
        ClipboardWatcher.wasOffered = true
        let alert = NSAlert()
        alert.messageText = L("Hang images you copy too?")
        alert.informativeText = L("Images you copy, like a screenshot taken with Control held or Copy Image in a browser, will hang on the line as well. Tendedero only keeps images, never text, and skips anything a password manager marks as private. You can change this from the menu bar.")
        alert.addButton(withTitle: L("Turn on"))
        alert.addButton(withTitle: L("Not now"))
        if let icon = NSImage(named: "Tendedero") ?? NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            ClipboardWatcher.isEnabled = true
            clipboardWatcher.start()
        }
    }

    /// Quitting from the menu or logging out runs applicationWillTerminate.
    /// A plain kill does not, so settings are also restored on those signals.
    private func restoreSettingsOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                ClipboardImage.materializeForExit()
                self?.monitoring.stop()
                self?.restoreInbox()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Showing and hiding

    private func captureAdded(shouldPeek: Bool) {
        panel.placeOnScreen(pendingScreen)
        pendingScreen = nil
        updateCapacity()
        wanted = true
        refresh()
        if shouldPeek { reveal(peekFor: 2.5) }
    }

    private func itemsChanged() {
        if line.liveCount > 0 {
            wanted = true
            refresh()
        } else if !keepOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.line.liveCount == 0, !self.keepOpen else { return }
                self.wanted = false
                self.refresh()
            }
        }
    }

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    @discardableResult
    private func hangCapture(_ url: URL) -> Bool {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        if line.items.contains(where: { $0.url == url && !$0.falling }) { return true }
        let from = (line.peeksAtNew || isRevealed) && CaptureFlight.canFly ? captureRect(of: url) : nil
        pendingScreen = nil
        if let from {
            let center = CGPoint(x: from.midX, y: from.midY)
            pendingScreen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
        }
        guard let id = line.hang(url, flying: from != nil) else {
            pendingScreen = nil
            return false
        }
        guard let from else { return true }
        // Let the line come down and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: from)
        }
        return true
    }

    private func fly(_ id: UUID, from: CGRect) {
        guard isPresent, isRevealed, let screen = panel.screen,
              let to = cardFrame(for: id),
              let item = line.items.first(where: { $0.id == id }), !item.falling else {
            line.land(id)
            return
        }
        guard CaptureFlight.canFly else {
            line.land(id)
            return
        }
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(item.url, maxPixels: min(CaptureFlight.maxImagePixels, max(1, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            line.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt), on: screen) { [weak self] in
            self?.line.land(id)
        }
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    private func fall(_ item: Pegged) {
        guard isPresent, isRevealed, !item.flying, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let image = (line.zoomedID == item.id ? (line.zoomPreview ?? item.thumb) : item.thumb)
                .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CaptureFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), on: screen)
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        line.cardFrame(for: id, in: panel.frame)
    }

    /// Decides whether the panel is ordered in at all: something to show,
    /// and no full screen app on that screen.
    private func refresh() {
        let blocked = panel.screen.map(FullScreen.isActive(on:))
            ?? LinePanel.screenUnderPointer().map(FullScreen.isActive(on:)) ?? false
        if wanted && !blocked {
            present()
        } else {
            dismiss()
        }
        // The cursor is watched while there is a line, even tucked away,
        // to notice it pushing against the top edge.
        if wanted { startMouseTracking() } else { stopMouseTracking() }
    }

    private func present() {
        guard !isPresent else { return }
        isPresent = true
        panel.alphaValue = 1
        // The window itself only comes in while the line is down; see setRevealed.
        if isRevealed { panel.orderFrontRegardless() }
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard isPresent else { return }
        if pinned { self.pinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        hiding.cancel()
        isRevealed = on
        line.revealed = on
        // Tucked away, the line leaves no window behind: an invisible strip
        // over the top of the screen would still sit above other apps for
        // anything that checks what is on top, like screen automation.
        if on {
            if isPresent { panel.orderFrontRegardless() }
        } else {
            hiding.schedule { [weak self] in
                guard let self, !self.isRevealed else { return }
                self.panel.orderOut(nil)
            }
        }
        if !on {
            line.hoveredID = nil
            pinned = false
            peekUntil = .distantPast
            panel.ignoresMouseEvents = true
        }
    }

    @objc private func toggle() {
        if isRevealed {
            setRevealed(false)
            if line.liveCount == 0 {
                keepOpen = false
                wanted = false
                refresh()
            }
        } else {
            keepOpen = true
            wanted = true
            panel.placeOnScreen()
            updateCapacity()
            refresh()
            reveal(pinned: true)
        }
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel.ignoresMouseEvents = true
    }

    /// How long the cursor rests against the top edge before the line comes
    /// down. Short enough to feel instant, long enough that a quick trip to
    /// the menu bar does not trigger it.
    private static let revealDelay: TimeInterval = 0.25

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }

    /// Where resting the pointer brings the line down: only the very top
    /// edge, so heading into the menu bar to click something does not. Where
    /// another display sits above, the pointer crosses that edge without
    /// stopping, so there the whole menu bar counts instead.
    static func revealZone(of screen: NSScreen, at x: CGFloat) -> NSRect {
        EdgeReveal.zone(screen: screen.frame, menuBar: menuBarBand(of: screen),
                        displays: NSScreen.screens.map(\.frame), x: x)
    }

    /// A click anywhere in the top bar of any screen, a menu or an icon, puts the line away.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation
                guard NSScreen.screens.contains(where: { NSMouseInRect(p, Self.menuBarBand(of: $0), false) }) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                if self.isRevealed {
                    self.pinned = false
                    self.setRevealed(false)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }
    /// A two finger scroll over a photo zooms it in and out. Pinches only
    /// reach the active app and the line never activates, but scrolling
    /// reaches the window under the pointer.
    private func watchScrollZoom() {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            var amount = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
            // Fingers up zooms in, whichever way scrolling is set.
            if event.isDirectionInvertedFromDevice { amount = -amount }
            let used = MainActor.assumeIsolated { self?.zoomPhotoUnderPointer(by: amount) ?? false }
            return used ? nil : event
        }
        if let monitor { clickMonitors.append(monitor) }
    }

    /// Returns true when there was a photo under the pointer to zoom.
    private func zoomPhotoUnderPointer(by amount: CGFloat) -> Bool {
        guard Line.zoomOnHover, isRevealed else { return false }
        let local = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        guard let id = line.hitRects.first(where: { $0.value.insetBy(dx: -4, dy: -4).contains(flipped) })?.key
                ?? line.hoveredID else { return false }
        line.zoom(id, by: amount)
        return true
    }

    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.5

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = Date()

        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screenUnderPointer.map { NSMouseInRect(mouse, Self.menuBarBand(of: $0), false) } ?? false
        if !inMenuBar { menuBarSuppressed = false }

        guard isRevealed else {
            // Resting against the top edge brings the line down on that
            // screen. Merely visiting the menu bar does not.
            if let screen = screenUnderPointer, !menuBarSuppressed,
               NSMouseInRect(mouse, Self.revealZone(of: screen, at: mouse.x), false),
               !FullScreen.isActive(on: screen) {
                let since = hotZoneScreen == screen ? (hotZoneSince ?? now) : now
                hotZoneScreen = screen
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    if panel.screen != screen {
                        panel.placeOnScreen(screen)
                        updateCapacity()
                    }
                    refresh()
                    reveal()
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        updateMousePassThrough(mouse)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        // The room kept for zooming only counts while a photo is zoomed.
        if line.zoomedID == nil {
            zone.origin.y = zone.maxY - Layout.baseHeight
            zone.size.height = Layout.baseHeight
        }
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        if inside && pinned { pinned = false }

        let busy = pinned || GrabView.isDragging || line.pressedID != nil || now < peekUntil
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// The panel spans the whole width of the screen, so it only accepts the
    /// mouse while the cursor is over a photo. Everywhere else, clicks go to
    /// whatever is underneath.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        let overPhoto = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        if panel.ignoresMouseEvents == overPhoto {
            panel.ignoresMouseEvents = !overPhoto
        }
    }

    private func updateCapacity() {
        let usable = panel.frame.width - 200
        line.maxItems = max(3, min(12, Int(usable / Layout.spacing)))
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "tshirt", accessibilityDescription: "Tendedero")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggleItem = ClosureMenuItem(isRevealed ? L("Hide line") : L("Show line")) { [weak self] in
            self?.toggle()
        }
        toggleItem.keyEquivalent = "t"
        toggleItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(toggleItem)

        let clearItem = ClosureMenuItem(L("Take everything down")) { [weak self] in
            self?.line.clear()
        }
        clearItem.isEnabled = line.liveCount > 0
        menu.addItem(clearItem)

        let inboxItem = ClosureMenuItem(L("Handle screenshots")) { [weak self] in
            guard let self else { return }
            self.setInbox(!self.inbox.isEnabled)
        }
        inboxItem.state = inbox.isEnabled ? .on : .off
        inboxItem.toolTip = L("Save new screenshots to the chosen folder and hang them instantly")
        menu.addItem(inboxItem)

        let clipboard = ClosureMenuItem(L("Hang copied images")) { [weak self] in
            ClipboardWatcher.isEnabled.toggle()
            if ClipboardWatcher.isEnabled { self?.clipboardWatcher.start() } else { self?.clipboardWatcher.stop() }
        }
        clipboard.state = ClipboardWatcher.isEnabled ? .on : .off
        clipboard.toolTip = L("Images you copy hang on the line too")
        menu.addItem(clipboard)

        menu.addItem(ClosureMenuItem(L("Open screenshots folder")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.monitoring.folder ?? self.inbox.folder)
        })

        menu.addItem(.separator())

        let choose = ClosureMenuItem(L("Choose screenshots folder…")) { [weak self] in self?.chooseScreenshotFolder() }
        choose.toolTip = inbox.folder.path
        menu.addItem(choose)
        let reset = ClosureMenuItem(L("Use default screenshots folder")) { [weak self] in
            self?.selectScreenshotFolder(Inbox.defaultFolder)
        }
        reset.isEnabled = inbox.folder.standardizedFileURL != Inbox.defaultFolder.standardizedFileURL
        menu.addItem(reset)

        let peek = ClosureMenuItem(L("Show new items")) { [weak self] in self?.line.peeksAtNew.toggle() }
        peek.state = line.peeksAtNew ? .on : .off
        peek.toolTip = L("The line comes down for a moment when something new hangs")
        menu.addItem(peek)

        let zoom = ClosureMenuItem(L("Zoom on hover")) { [weak self] in
            guard let self else { return }
            Line.zoomOnHover.toggle()
            self.line.hoveredID = nil
            self.panel.placeOnScreen(self.panel.screen)
        }
        zoom.state = Line.zoomOnHover ? .on : .off
        zoom.toolTip = L("Rest the pointer on a photo to see it larger")
        menu.addItem(zoom)

        let sound = ClosureMenuItem(L("Sounds")) { [weak self] in
            guard let self else { return }
            self.line.soundOn.toggle()
        }
        sound.state = line.soundOn ? .on : .off
        menu.addItem(sound)

        let login = ClosureMenuItem(L("Open at login")) {
            AppDelegate.toggleLaunchAtLogin()
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Quit Tendedero"), key: "q") {
            NSApp.terminate(nil)
        })
    }

    private static func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting")
            alert.informativeText = L("Move Tendedero to the Applications folder and try again.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
