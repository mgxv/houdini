// Fuses Now Playing state and Dock-reported fullscreen-Space state
// into one decision, only writing the menu-bar pref when that decision
// actually changes.

import Cocoa

/// Hide the menu bar iff Dock reports the active Space as fullscreen,
/// the frontmost app is the FS app, *and* the frontmost app is the
/// source of the current Now Playing track. Called once per evaluation
/// tick via `Snapshot.shouldHide`.
///
/// `frontPID.rawValue == dockFs.pid` is the multi-display gate: if
/// the user has FS Chrome on display 2 but is currently focused on a
/// windowed app on display 1, we'd see `dockFs.isFullScreen=true,
/// dockFs.pid=Chrome` from the most recent Dock event, but the front
/// PID would not match, so we keep the menu bar visible. Only when
/// the focused app is the FS app do we proceed to the same-app-as-
/// Now-Playing identity check.
///
/// Two identity checks run in parallel for the "same app as Now
/// Playing" test:
///   1. Responsibility-PID mapping via the kernel syscall
///      (`FrontmostPID.isSameProcess(as:)`), which handles helper
///      processes (e.g. WebKit.GPU resolves to Safari) without
///      adapter cooperation.
///   2. The frontmost app's bundle identifier matches the Now Playing
///      source's `parentApplicationBundleIdentifier`. Direct assertion
///      from MediaRemote about who owns the media; keeps houdini
///      working for browsers even if the responsibility syscall
///      regresses.
func shouldHideMenuBar(
    dockFs: DockFullScreenState,
    isPlaying: Bool,
    frontPID: FrontmostPID?,
    frontBundle: String?,
    nowPlayingPID: NowPlayingPID?,
    nowPlayingParentBundle: String?,
) -> Bool {
    guard dockFs.isFullScreen,
          isPlaying,
          let frontPID,
          let nowPlayingPID,
          let dockFsPID = dockFs.pid,
          frontPID.rawValue == dockFsPID
    else {
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
        let dockFs: DockFullScreenState
        let isPlaying: Bool
        let nowPlayingPID: NowPlayingPID?
        let nowPlayingBundle: String?
        let nowPlayingParentBundle: String?

        var shouldHide: Bool {
            shouldHideMenuBar(
                dockFs: dockFs,
                isPlaying: isPlaying,
                frontPID: frontPID,
                frontBundle: frontBundle,
                nowPlayingPID: nowPlayingPID,
                nowPlayingParentBundle: nowPlayingParentBundle,
            )
        }
    }

    private let menuBar: MenuBarToggler
    private var dockFs: DockFullScreenState = .initial
    private var isPlaying: Bool = false
    private var nowPlayingPID: NowPlayingPID?
    private var nowPlayingBundle: String?
    private var nowPlayingParentBundle: String?
    private var lastSnapshot: Snapshot?

    private lazy var dockSpaceWatcher = DockSpaceWatcher { [weak self] event in
        self?.handleDockEvent(event)
    }

    init(menuBar: MenuBarToggler) {
        self.menuBar = menuBar
        super.init()
    }

    /// Throws if the dock-space watcher fails to spawn — that channel
    /// is load-bearing for fullscreen detection, so the caller dies
    /// rather than continuing in a degraded state.
    func start() throws {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(onFrontAppChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
        )
        try dockSpaceWatcher.start()
        evaluate()
    }

    /// Tear down the dock-space watcher's subprocess. Called from the
    /// daemon's signal handler so unexpected-exit detection in the
    /// termination handler doesn't fire `die` during graceful
    /// shutdown.
    func stop() {
        dockSpaceWatcher.stop()
    }

    @objc private func onFrontAppChange(_: Notification) {
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

    private func handleDockEvent(_ event: DockSpaceEvent) {
        switch event {
        case let .fullScreenState(state):
            updateDockFullScreen(state)
        case .staySpaceChange:
            onStaySpaceChange()
        }
    }

    private func updateDockFullScreen(_ state: DockFullScreenState) {
        dockFs = state
        evaluate()
    }

    /// Refreshes `dockFs.pid` from `frontmostApplication` so
    /// `shouldHideMenuBar`'s multi-display gate doesn't reject FS↔FS
    /// hops with a stale pid. Guarded on cached `isFullScreen` because
    /// the no-op fires for non-FS hops too; the line's `state` field
    /// is unreliable across transition phases, so we trust the cache.
    /// `frontmostApplication` is fresh here — the log subprocess
    /// pipeline serializes after AppKit propagates the new frontmost.
    private func onStaySpaceChange() {
        guard dockFs.isFullScreen,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else { return }
        dockFs = DockFullScreenState(isFullScreen: true, pid: pid)
        evaluate()
    }

    private func evaluate() {
        let snap = takeSnapshot()
        guard snap != lastSnapshot else { return }
        lastSnapshot = snap

        menuBar.apply(shouldHide: snap.shouldHide)
        logSnapshot(snap)
    }

    /// Sample the frontmost app and combine with the cached Now
    /// Playing and Dock-FS state into an immutable snapshot.
    private func takeSnapshot() -> Snapshot {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontPID = frontApp.map { FrontmostPID($0.processIdentifier) }
        let frontName = frontApp?.localizedName ?? "(unknown)"
        let frontBundle = frontApp?.bundleIdentifier

        return Snapshot(
            frontPID: frontPID,
            frontName: frontName,
            frontBundle: frontBundle,
            dockFs: dockFs,
            isPlaying: isPlaying,
            nowPlayingPID: nowPlayingPID,
            nowPlayingBundle: nowPlayingBundle,
            nowPlayingParentBundle: nowPlayingParentBundle,
        )
    }

    /// Renders the snapshot as two scannable lines for the unified log:
    /// decision + frontmost on the first row, Now Playing on the second.
    /// Format:
    ///
    ///   {HIDE|SHOW}  front=<head>[pid=<pid>,name=<name>,bundle=<bundle>,fs=<yes|no>,fsPid=<pid>]
    ///   np=<head>[pid=<pid>,bundle=<bundle>,parent=<parent>,resp=<resp>,play=<yes|no>]
    ///
    /// `<head>` is the bundle's last 1–2 dot components (`Chrome`,
    /// `WebKit.GPU`) — a cheap visual anchor for scanning. Empty when
    /// the bundle is nil. The bracketed body emits every original
    /// field; missing optionals are explicit `null` (so absent vs.
    /// empty stays distinguishable from the log alone). String values
    /// with spaces are double-quoted so a downstream space-tokenizing
    /// parser sees them as one field.
    ///
    /// `fs` is the dock-reported fullscreen state of the active Space;
    /// `fsPid` is the FS app's PID from the same Dock event, or `null`
    /// when not fullscreen.
    ///
    /// Example:
    ///   HIDE  front=Safari[pid=37860,name="Safari",bundle=com.apple.Safari,fs=yes,fsPid=37860]
    ///   np=WebKit.GPU[pid=37865,bundle=com.apple.WebKit.GPU,parent=com.apple.Safari,resp=37860,play=yes]
    ///
    /// Leading `\n` pushes the body onto its own row under the
    /// unified-log timestamp/category prefix.
    private func logSnapshot(_ snap: Snapshot) {
        Log.controller.info("\n\(Self.formatSnapshot(snap), privacy: .public)")
    }

    private static func formatSnapshot(_ snap: Snapshot) -> String {
        let decision = snap.shouldHide ? "HIDE" : "SHOW"
        // Decision + front on one line, np on the next. Long lines (full
        // bundles, parent, resp) made the single-line form wrap on most
        // terminals; splitting keeps each half readable without dropping
        // any fields.
        return "\(decision)  front=\(formatFront(snap))\nnp=\(formatNowPlaying(snap))"
    }

    private static func formatFront(_ snap: Snapshot) -> String {
        let head = bundleShort(snap.frontBundle) ?? ""
        let fields = [
            "pid=\(formatNullable(snap.frontPID?.rawValue))",
            "name=\(quoteString(snap.frontName))",
            "bundle=\(formatNullableString(snap.frontBundle))",
            "fs=\(snap.dockFs.isFullScreen ? "yes" : "no")",
            "fsPid=\(formatNullable(snap.dockFs.pid))",
        ]
        return "\(head)[\(fields.joined(separator: ","))]"
    }

    private static func formatNowPlaying(_ snap: Snapshot) -> String {
        let head = bundleShort(snap.nowPlayingBundle) ?? ""
        let fields = [
            "pid=\(formatNullable(snap.nowPlayingPID?.rawValue))",
            "bundle=\(formatNullableString(snap.nowPlayingBundle))",
            "parent=\(formatNullableString(snap.nowPlayingParentBundle))",
            "resp=\(formatNullable(snap.nowPlayingPID?.responsiblePID))",
            "play=\(snap.isPlaying ? "yes" : "no")",
        ]
        return "\(head)[\(fields.joined(separator: ","))]"
    }

    /// `com.apple.Safari` → `Safari`, `com.apple.WebKit.GPU` →
    /// `WebKit.GPU`. Trims the reverse-DNS prefix and keeps the
    /// app-identifying tail. Returns nil for nil/empty input so the
    /// caller can omit the head entirely.
    private static func bundleShort(_ bundle: String?) -> String? {
        guard let bundle, !bundle.isEmpty else { return nil }
        let parts = bundle.split(separator: ".")
        return parts.count >= 3
            ? parts.dropFirst(2).joined(separator: ".")
            : bundle
    }

    /// pid_t nil → "null"; non-nil → its decimal representation.
    /// Specialized to pid_t (the only nullable numeric we log) so
    /// interpolation goes through Int32's direct path rather than
    /// `String(describing:)`'s reflection-based fallback.
    private static func formatNullable(_ value: pid_t?) -> String {
        value.map { "\($0)" } ?? "null"
    }

    /// Three-state string formatting: nil → `null`, empty → `""`,
    /// value with a space → double-quoted, value without a space →
    /// bare. Bundles (reverse-DNS) hit the bare path; localized names
    /// like "Google Chrome" are quoted. The nil vs empty distinction
    /// is preserved so a reader can tell "field absent" from "field
    /// present but empty" — the underlying optionals can mean
    /// genuinely different things (e.g. a nil parentBundle is "no
    /// helper relationship," an empty string is "MediaRemote reported
    /// the field as empty.").
    private static func formatNullableString(_ value: String?) -> String {
        guard let value else { return "null" }
        return value.contains(" ") || value.isEmpty
            ? "\"\(value)\""
            : value
    }

    /// Always quote — used for `name`, which is a free-form display
    /// string that may contain spaces, parens, or LTR markers.
    private static func quoteString(_ value: String) -> String {
        "\"\(value)\""
    }
}
