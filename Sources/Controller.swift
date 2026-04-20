// Fuses Now Playing state and frontmost-fullscreen state into one
// decision, only writing the menu-bar pref when that decision
// actually changes.

import Cocoa

final class Controller: NSObject {
    private struct Snapshot: Equatable {
        let frontPID: pid_t
        let frontName: String
        let fullScreen: Bool
        let isPlaying: Bool
        let nowPlayingPID: pid_t
        let shouldHide: Bool
    }

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private let menuBar: MenuBarToggler?
    private var isPlaying = false
    private var nowPlayingPID: pid_t = 0
    private var nowPlayingBundle: String?
    private var lastSnapshot: Snapshot?

    private lazy var axWatcher = AXWatcher { [weak self] in
        self?.evaluate()
    }

    init(menuBar: MenuBarToggler?) {
        self.menuBar = menuBar
        super.init()
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(onFrontAppChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
        )
        evaluate()
    }

    @objc private func onFrontAppChange(_: Notification) {
        evaluate()
    }

    /// Called by AdapterClient whenever the Now Playing state changes.
    func updateMedia(playing: Bool, pid: pid_t, bundle: String?) {
        isPlaying = playing
        nowPlayingPID = pid
        nowPlayingBundle = bundle
        evaluate()
    }

    private func evaluate() {
        let snap = currentSnapshot()
        guard snap != lastSnapshot else { return }
        lastSnapshot = snap

        menuBar?.apply(shouldHide: snap.shouldHide)
        logSnapshot(snap)
    }

    private func currentSnapshot() -> Snapshot {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontPID = frontApp?.processIdentifier ?? 0
        let frontName = frontApp?.localizedName ?? "(unknown)"
        axWatcher.attach(pid: frontPID)

        let fullScreen = isProcessFrontmostFullScreen(pid: frontPID)
        let shouldHide =
            fullScreen
                && isPlaying
                && frontPID != 0
                && frontPID == nowPlayingPID

        return Snapshot(
            frontPID: frontPID, frontName: frontName,
            fullScreen: fullScreen, isPlaying: isPlaying,
            nowPlayingPID: nowPlayingPID, shouldHide: shouldHide,
        )
    }

    private func logSnapshot(_ snap: Snapshot) {
        let label = snap.shouldHide ? "HIDE" : "SHOW"
        let ts = timeFormatter.string(from: Date())
        let nowPlaying = nowPlayingBundle ?? "-"
        print("[\(ts)] \(label)  front=\(snap.frontName)  fullScreen=\(snap.fullScreen)  playing=\(snap.isPlaying)  frontPID=\(snap.frontPID)  nowPlaying=\(nowPlaying)(pid=\(snap.nowPlayingPID))")
    }
}
