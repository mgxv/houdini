// Fuses Now Playing state and frontmost-fullscreen state into one
// decision, only writing the menu-bar pref when that decision
// actually changes.

import Cocoa

final class Controller: NSObject {
    /// Immutable view of the inputs that drive the hide/show decision.
    /// `shouldHide` is derived — two snapshots compare equal iff every
    /// input matches, so Equatable avoids redundant writes without
    /// caching the decision itself.
    ///
    /// `frontPID` and `nowPlayingPID` are distinct types (not just
    /// distinct values) so the compiler blocks accidentally swapping
    /// them.
    private struct Snapshot: Equatable {
        let frontPID: FrontmostPID?
        let frontName: String
        let fullScreen: Bool
        let isPlaying: Bool
        let nowPlayingPID: NowPlayingPID?

        /// Hide the menu bar only when the frontmost app is fullscreen
        /// *and* is itself the source of the current Now Playing track.
        var shouldHide: Bool {
            guard fullScreen,
                  isPlaying,
                  let frontPID,
                  let nowPlayingPID,
                  frontPID.isSameProcess(as: nowPlayingPID)
            else { return false }
            return true
        }
    }

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private let menuBar: MenuBarToggler
    private var isPlaying: Bool = false
    private var nowPlayingPID: NowPlayingPID?
    private var nowPlayingBundle: String?
    private var lastSnapshot: Snapshot?

    private lazy var axWatcher = AXWatcher { [weak self] in
        self?.evaluate()
    }

    init(menuBar: MenuBarToggler) {
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
    /// `pid` is nil when Now Playing has no current source.
    func updateMedia(playing: Bool, pid: NowPlayingPID?, bundle: String?) {
        isPlaying = playing
        nowPlayingPID = pid
        nowPlayingBundle = bundle
        evaluate()
    }

    private func evaluate() {
        let snap = takeSnapshot()
        guard snap != lastSnapshot else { return }
        lastSnapshot = snap

        menuBar.apply(shouldHide: snap.shouldHide)
        logSnapshot(snap)
    }

    /// Read the current frontmost app, (re-)subscribe the AX watcher to
    /// it, and sample its fullscreen state. Called on every evaluation
    /// tick because the frontmost PID can change at any time.
    private func takeSnapshot() -> Snapshot {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontPID = frontApp.map { FrontmostPID($0.processIdentifier) }
        let frontName = frontApp?.localizedName ?? "(unknown)"
        axWatcher.attach(pid: frontPID?.rawValue)

        return Snapshot(
            frontPID: frontPID,
            frontName: frontName,
            fullScreen: isFocusedWindowFullScreen(pid: frontPID?.rawValue),
            isPlaying: isPlaying,
            nowPlayingPID: nowPlayingPID,
        )
    }

    private func logSnapshot(_ snap: Snapshot) {
        let label = snap.shouldHide ? "HIDE" : "SHOW"
        let ts = timeFormatter.string(from: Date())
        let nowPlaying = nowPlayingBundle ?? "-"
        let frontPIDStr = snap.frontPID?.description ?? "-"
        let nowPlayingPIDStr = snap.nowPlayingPID?.description ?? "-"
        print(
            "[\(ts)] \(label)  "
                + "front=\(snap.frontName)  "
                + "fullScreen=\(snap.fullScreen)  "
                + "playing=\(snap.isPlaying)  "
                + "frontPID=\(frontPIDStr)  "
                + "nowPlaying=\(nowPlaying)(pid=\(nowPlayingPIDStr))",
        )
    }
}
