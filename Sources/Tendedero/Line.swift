import AppKit
import Combine
import os

let log = Logger(subsystem: "app.tendedero.Tendedero", category: "line")

/// One screenshot hanging on the line.
struct Pegged: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var thumb: NSImage
    /// Every photo hangs a little crooked, like on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false

    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying && a.thumb === b.thumb
    }
}

/// The line itself: what hangs on it and what you can do with each item.
/// The files never move. The line is only a view onto them.
@MainActor
final class Line: ObservableObject {
    @Published private(set) var items: [Pegged] = []
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    /// The photo under the pointer.
    @Published var hoveredID: UUID? {
        didSet { if oldValue != hoveredID { zoomPreview = nil; updateZoomPreview() } }
    }
    /// Only one expanded preview is retained; ordinary cards stay small.
    @Published private(set) var zoomPreview: NSImage?

    private func updateZoomPreview() {
        guard zoomEnabled, let id = hoveredID,
              let item = items.first(where: { $0.id == id && !$0.falling }) else { return }
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        zoomPreview = makeThumbnail(item.url, maxPixels: Int(ceil((Layout.cardWidth - 14) * Layout.maxZoom * scale)))
    }

    /// Photos grow in place while the pointer rests on them.
    nonisolated static var zoomOnHover: Bool {
        get { UserDefaults.standard.bool(forKey: "zoomOnHover") }
        set { UserDefaults.standard.set(newValue, forKey: "zoomOnHover") }
    }

    var zoomEnabled: Bool { defaults.bool(forKey: "zoomOnHover") }

    /// How large the zoomed photo is. Starts at the hover zoom, follows a
    /// scroll over the photo, and goes back when the pointer leaves.
    @Published var zoomLevel: CGFloat = Layout.zoom

    func zoom(_ id: UUID, by amount: CGFloat) {
        guard zoomEnabled else { return }
        hoveredID = id
        zoomLevel = min(Layout.maxZoom, max(1, zoomLevel * (1 + amount)))
    }

    /// The photo shown zoomed: the hovered one, unless it is being dragged.
    var zoomedID: UUID? {
        guard zoomEnabled, draggingID == nil else { return nil }
        return items.first(where: { $0.id == hoveredID && !$0.falling && !$0.flying })?.id
    }
    /// Whether the line has slid down into view.
    @Published var revealed = false

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over photos and let the rest through.
    var hitRects: [UUID: CGRect] = [:]

    var maxItems = 8

    var peeksAtNew: Bool {
        get { !defaults.bool(forKey: "quietHang") }
        set { defaults.set(!newValue, forKey: "quietHang") }
    }

    /// Emitted after acceptance and persistence, even when eviction keeps the count flat.
    var onCapture: ((_ shouldPeek: Bool) -> Void)?

    var soundOn: Bool {
        get { !defaults.bool(forKey: "soundOff") }
        set { defaults.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { items.filter { !$0.falling }.count }

    private let storeKey = "pegged"

    private let defaults: UserDefaults
    private let dedicatedFolder: URL
    private let clipboardFolder: URL

    init(defaults: UserDefaults = .standard, dedicatedFolder: URL = Inbox.defaultFolder,
         clipboardFolder: URL = ClipboardWatcher.folder) {
        self.defaults = defaults
        self.dedicatedFolder = dedicatedFolder
        self.clipboardFolder = clipboardFolder
        restore()
        scheduleGust()
    }

    func cardX(at index: Int, width: CGFloat) -> CGFloat {
        let zoomIndex = zoomedID.flatMap { id in items.firstIndex { $0.id == id } }
        let push = zoomIndex.map { Layout.push(for: items[$0].thumb.size, zoom: zoomLevel) } ?? 0
        let shift = zoomIndex.map { index < $0 ? -push : (index > $0 ? push : 0) } ?? 0
        return Layout.x(index: index, count: items.count, width: width) + shift
    }

    /// Same zoom, neighbour displacement and rope position as LineView.
    func cardFrame(for id: UUID, in panel: CGRect) -> CGRect? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let x = cardX(at: index, width: panel.width)
        let top = Layout.ropeY(x: x, width: panel.width) - Layout.pinAbove + PeggedView.cardOffsetBelowTop
        let size = PeggedView.cardSize(for: items[index].thumb.size, zoom: zoomedID == id ? zoomLevel : 1)
        return CGRect(x: panel.minX + x - size.width / 2, y: panel.maxY - top - size.height,
                      width: size.width, height: size.height)
    }

    // MARK: Hanging and dropping

    @discardableResult
    func hang(_ url: URL, quietly: Bool = false, flying: Bool = false) -> UUID? {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        guard !items.contains(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return nil }
        var item = Pegged(url: url, thumb: thumb)
        item.flying = flying
        items.append(item)
        // A full line lets the oldest photo fall off the far end.
        while liveCount > maxItems, let oldest = items.first(where: { !$0.falling }) {
            drop(oldest.id, quietly: true)
        }
        save()
        if !quietly {
            onCapture?(peeksAtNew)
            play("Tink", volume: 0.35)
        }
        return item.id
    }

    /// The capture has reached the line: the real card takes over.
    func land(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = false
    }

    /// Called just before a photo starts falling, so the fall can be drawn
    /// over the whole screen.
    var onFall: ((Pegged) -> Void)?

    func drop(_ id: UUID, quietly: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        onFall?(items[i])
        items[i].falling = true
        if hoveredID == id { hoveredID = nil }
        hitRects[id] = nil
        save()
        if !quietly { play("Pop", volume: 0.25) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.items.removeAll { $0.id == id }
        }
    }

    func clear() {
        let live = items.filter { !$0.falling }
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                self?.drop(item.id, quietly: n > 0)
            }
        }
    }

    /// Photos whose file was deleted or moved away fall off by themselves.
    func prune() {
        for item in items where !item.falling && !FileManager.default.fileExists(atPath: item.url.path) {
            drop(item.id, quietly: true)
        }
    }

    // MARK: Actions on one photo

    func copy(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        guard ClipboardImage.copy(item.url) else { return }

        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == id { self?.copiedID = nil }
        }
    }

    func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(item.url)
    }

    /// Moves the file to the Trash and takes the photo off the line. When a
    /// drag ends on the Dock's Trash, macOS only reports it: deleting the file
    /// is the source app's job, as Finder does.
    func trash(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            log.notice("Trashed \(item.url.lastPathComponent, privacy: .public)")
            if soundOn { Line.trashSound?.play() }
            drop(id, quietly: true)
        } catch {
            log.error("Could not trash \(item.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// Whether the file lives in Tendedero's own folder. Those are discarded
    /// to the Trash, or the folder would fill up with forgotten screenshots.
    /// Files anywhere else, like the Desktop, stay where they are.
    func isInInbox(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return Inbox.owns(item.url, in: dedicatedFolder) || Inbox.owns(item.url, in: clipboardFolder)
    }

    /// The corner cross and "Take down" both end up here.
    func discard(_ id: UUID) {
        if isInInbox(id) { trash(id) } else { drop(id) }
    }

    /// Inbox mode: keep a screenshot by moving it to the Desktop.
    func saveToDesktop(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let target = uniqueURL(in: desktop, for: item.url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            drop(id, quietly: true)
        } catch {
            log.error("Could not save to Desktop: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Long press: open the photo in the system Markup editor.
    func markup(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        Markup.shared.edit(item.url)
    }

    /// After editing, the photo on the line shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return }
        items[i].thumb = thumb
        if items[i].id == hoveredID { updateZoomPreview() }
    }

    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Breeze

    /// Every so often a little wind moves the line. It is the detail that
    /// makes it feel like an object and not a widget.
    private func scheduleGust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16)) { [weak self] in
            guard let self else { return }
            if !self.items.isEmpty && self.draggingID == nil { self.gust += 1 }
            self.scheduleGust()
        }
    }

    // MARK: Persistence

    private func save() {
        let paths = items.filter { !$0.falling }.map(\.url.path)
        defaults.set(paths, forKey: storeKey)
    }

    private func restore() {
        let paths = defaults.stringArray(forKey: storeKey) ?? []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            // The screen's capacity is not known yet; hang would truncate to eight.
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            guard !items.contains(where: { $0.url == url }), let thumb = makeThumbnail(url) else { continue }
            items.append(Pegged(url: url, thumb: thumb))
        }
    }

    // MARK: Helpers

    private func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

}
