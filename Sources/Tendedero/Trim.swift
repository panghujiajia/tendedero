import AppKit
import AVKit
import Combine

/// 裁剪录屏后保存为独立副本，原文件始终保留。
@MainActor
final class Trim: NSObject, NSWindowDelegate {
    static let shared = Trim()

    /// 成功保存后，把新副本交给绳子。
    var onSaved: (URL) -> Void = { _ in }

    private var window: NSWindow?
    private var ready: AnyCancellable?

    func edit(_ url: URL, size: CGSize) {
        window?.close()

        let item = AVPlayerItem(url: url)
        let playerView = AVPlayerView()
        playerView.player = AVPlayer(playerItem: item)
        playerView.controlsStyle = .inline

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.windowSize(for: size)),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = url.lastPathComponent
        window.contentView = playerView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // The trimming bar can only come up once the recording has loaded.
        ready = item.publisher(for: \.status)
            .first { $0 != .unknown }
            .receive(on: RunLoop.main)
            .sink { [weak self, weak playerView] status in
                guard let self, let playerView, status == .readyToPlay, playerView.canBeginTrimming else {
                    log.error("Could not trim \(url.lastPathComponent, privacy: .public)")
                    return
                }
                playerView.beginTrimming { result in
                    DispatchQueue.main.async {
                        guard self.window === window else { return }
                        if result == .okButton { self.save(item, source: url) }
                        window.close()
                    }
                }
            }
    }

    /// The recording at its own proportions, as large as fits comfortably.
    private static func windowSize(for size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 720, height: 450) }
        let scale = min(720 / size.width, 520 / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        (window?.contentView as? AVPlayerView)?.player?.pause()
        ready = nil
        window = nil
    }

    private func save(_ item: AVPlayerItem, source: URL) {
        let start = item.reversePlaybackEndTime.isNumeric ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime : item.duration
        Task {
            do { onSaved(try await Self.exportCopy(of: source, range: CMTimeRange(start: start, end: end))) }
            catch {
                log.error("Could not save trimmed copy: \(error.localizedDescription, privacy: .public)")
                NSSound.beep()
            }
        }
    }

    static func exportCopy(of source: URL, range: CMTimeRange) async throws -> URL {
        guard isRecordingFile(source), range.start.isNumeric, range.duration.isNumeric,
              range.start >= .zero, range.duration > .zero,
              let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough)
        else { throw CocoaError(.fileReadCorruptFile) }
        let folder = source.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".trimming-\(UUID().uuidString)")
            .appendingPathExtension(source.pathExtension)
        let target = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent
            + " — " + L("Trimmed") + " " + UUID().uuidString)
            .appendingPathExtension(source.pathExtension)
        defer { try? FileManager.default.removeItem(at: temporary) }
        export.outputURL = temporary
        export.outputFileType = source.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        export.timeRange = range
        await export.export()
        guard export.status == .completed else {
            throw export.error ?? CocoaError(.fileWriteUnknown)
        }
        // moveItem 不覆盖已有目标；只发布完整导出的副本。
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }
}
