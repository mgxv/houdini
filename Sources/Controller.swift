// Fuses Now Playing state and frontmost-fullscreen state into one
// decision, only writing the menu-bar pref when that decision
// actually changes.

import Cocoa

/// Hide the menu bar iff the frontmost app is fullscreen *and* is
/// itself the source of the current Now Playing track. This is the
/// single source of truth for the decision — both the daemon's
/// evaluation loop and the `status` subcommand call it, so they can't
/// drift apart.
///
/// Two identity checks run in parallel for the "same app" test:
///   1. Responsibility-PID mapping via the kernel syscall
///      (`FrontmostPID.isSameProcess(as:)`), which handles helper
///      processes for any framework without adapter cooperation.
///   2. The frontmost app's bundle identifier matches the Now Playing
///      source's `parentApplicationBundleIdentifier`. This is a direct
///      assertion from MediaRemote about who owns the media, so it
///      keeps houdini working for browsers even if the private
///      responsibility syscall regresses.
func shouldHideMenuBar(
    fullScreen: Bool,
    isPlaying: Bool,
    frontPID: FrontmostPID?,
    frontBundle: String?,
    nowPlayingPID: NowPlayingPID?,
    nowPlayingParentBundle: String?,
) -> Bool {
    guard fullScreen, isPlaying, let frontPID, let nowPlayingPID else {
        return false
    }
    if frontPID.isSameProcess(as: nowPlayingPID) { return true }
    if let frontBundle, let parent = nowPlayingParentBundle,
       !parent.isEmpty, parent == frontBundle
    {
        return true
    }
    return false
}

@MainActor
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
        let frontBundle: String?
        let fullScreen: Bool
        let isPlaying: Bool
        let nowPlayingPID: NowPlayingPID?
        let nowPlayingBundle: String?
        let nowPlayingParentBundle: String?

        var shouldHide: Bool {
            shouldHideMenuBar(
                fullScreen: fullScreen,
                isPlaying: isPlaying,
                frontPID: frontPID,
                frontBundle: frontBundle,
                nowPlayingPID: nowPlayingPID,
                nowPlayingParentBundle: nowPlayingParentBundle,
            )
        }
    }

    private let menuBar: MenuBarToggler
    private var isPlaying: Bool = false
    private var nowPlayingPID: NowPlayingPID?
    private var nowPlayingBundle: String?
    private var nowPlayingParentBundle: String?
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(onSpaceChange(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
        )
        evaluate()
    }

    @objc private func onFrontAppChange(_: Notification) {
        evaluate()
    }

    @objc private func onSpaceChange(_: Notification) {
        evaluate()
    }

    /// Called by AdapterClient whenever the Now Playing state changes,
    /// and once at startup from the priming `fetchNowPlayingOnce` call.
    func updateMedia(_ snapshot: NowPlayingSnapshot) {
        isPlaying = snapshot.playing
        nowPlayingPID = snapshot.pid
        nowPlayingBundle = snapshot.bundle
        nowPlayingParentBundle = snapshot.parentBundle
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
        let frontBundle = frontApp?.bundleIdentifier
        axWatcher.attach(pid: frontPID?.rawValue)

        return Snapshot(
            frontPID: frontPID,
            frontName: frontName,
            frontBundle: frontBundle,
            fullScreen: isFocusedWindowFullScreen(pid: frontPID?.rawValue),
            isPlaying: isPlaying,
            nowPlayingPID: nowPlayingPID,
            nowPlayingBundle: nowPlayingBundle,
            nowPlayingParentBundle: nowPlayingParentBundle,
        )
    }

    /// Two-slot structured headline plus a flat, peer-keyed detail
    /// line. Leading `\n` puts the unified-log prefix on its own line;
    /// trailing `\n` adds a blank line between events. Each slot
    /// attributes its state words to the correct subject —
    /// `fullscreen`/`windowed` to the frontmost app, `playing`/`paused`
    /// to the Now Playing source, which may be a different app.
    private func logSnapshot(_ snap: Snapshot) {
        let label = snap.shouldHide ? "HIDE" : "SHOW"
        let fsWord = snap.fullScreen ? "fullscreen" : "windowed"
        let front = "front=\(snap.frontName)[\(fsWord)]"

        let frontPIDStr = snap.frontPID?.description ?? "-"
        let np: String
        let details: String
        if let nowPlayingPID = snap.nowPlayingPID {
            let playWord = snap.isPlaying ? "playing" : "paused"
            let npName = snap.nowPlayingParentBundle.flatMap { $0.isEmpty ? nil : $0 }
                ?? snap.nowPlayingBundle
                ?? "pid\(nowPlayingPID)"
            np = "np=\(npName)[\(playWord)]"

            let respStr = nowPlayingPID.responsiblePID.map(String.init) ?? "-"
            let parentStr = snap.nowPlayingParentBundle ?? "-"
            let npBundle = snap.nowPlayingBundle ?? "-"
            details = "frontPID=\(frontPIDStr)"
                + "  npPID=\(nowPlayingPID.description)"
                + "  npBundle=\(npBundle)"
                + "  resp=\(respStr)"
                + "  parent=\(parentStr)"
        } else {
            np = "np=-"
            details = "frontPID=\(frontPIDStr)  (no Now Playing source)"
        }

        let message = "\n\(label)  \(front)  \(np)\n\(details)\n"
        Log.controller.info("\(message, privacy: .public)")
    }
}
