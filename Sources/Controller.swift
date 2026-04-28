// Fuses Now Playing state and Dock-reported fullscreen-Space state
// into one decision, only writing the menu-bar pref when that decision
// actually changes.

import Cocoa

enum MenuBarDecision {
    case hide
    case showNotFullScreen
    case showNotPlaying
    case showNoFrontPid
    case showNoNowPlayingPid
    case showFrontNotFsOwner
    case showAppMismatch

    var shouldHide: Bool {
        if case .hide = self { return true }
        return false
    }

    var tag: String {
        switch self {
        case .hide: "HIDE"
        case .showNotFullScreen: "SHOW(not_fullscreen)"
        case .showNotPlaying: "SHOW(not_playing)"
        case .showNoFrontPid: "SHOW(no_front_pid)"
        case .showNoNowPlayingPid: "SHOW(no_now_playing_pid)"
        case .showFrontNotFsOwner: "SHOW(front_not_fs_owner)"
        case .showAppMismatch: "SHOW(app_mismatch)"
        }
    }
}

enum EvalTrigger: String {
    case start
    case frontApp = "front_app"
    case dockFs = "dock_fs"
    case dockStay = "dock_stay"
    case adapter
}

/// `frontPID.rawValue == dockFs.pid` is the multi-display gate: if
/// FS Chrome is on display 2 but the user is focused on a windowed
/// app on display 1, the front PID won't match the Dock-reported FS
/// owner and we keep the menu bar visible.
///
/// The two identity checks for the same-app-as-Now-Playing test:
///   1. Responsibility-PID mapping via the kernel syscall
///      (`FrontmostPID.isSameProcess(as:)`), which handles helper
///      processes (WebKit.GPU resolves to Safari) without adapter
///      cooperation.
///   2. Frontmost bundle id matches Now Playing's
///      `parentApplicationBundleIdentifier` — MediaRemote's direct
///      assertion of the owning app, a fallback if the responsibility
///      syscall regresses.
func menuBarDecision(
    dockFs: DockFullScreenState,
    isPlaying: Bool,
    frontPID: FrontmostPID?,
    frontBundle: String?,
    nowPlayingPID: NowPlayingPID?,
    nowPlayingParentBundle: String?,
) -> MenuBarDecision {
    guard dockFs.isFullScreen else { return .showNotFullScreen }
    guard isPlaying else { return .showNotPlaying }
    guard let frontPID else { return .showNoFrontPid }
    guard let nowPlayingPID else { return .showNoNowPlayingPid }
    guard let dockFsPID = dockFs.pid, frontPID.rawValue == dockFsPID else {
        return .showFrontNotFsOwner
    }
    if frontPID.isSameProcess(as: nowPlayingPID) { return .hide }
    if let frontBundle, let parent = nowPlayingParentBundle,
       !parent.isEmpty, parent == frontBundle
    {
        return .hide
    }
    return .showAppMismatch
}

@MainActor
final class Controller: NSObject {
    /// Decision is derived, so Equatable on the inputs alone dedups
    /// redundant writes without caching it. `frontPID` and
    /// `nowPlayingPID` are distinct types so the compiler blocks
    /// accidental role swaps.
    private struct Snapshot: Equatable {
        let frontPID: FrontmostPID?
        let frontName: String
        let frontBundle: String?
        let dockFs: DockFullScreenState
        let isPlaying: Bool
        let nowPlayingPID: NowPlayingPID?
        let nowPlayingBundle: String?
        let nowPlayingParentBundle: String?

        var decision: MenuBarDecision {
            menuBarDecision(
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

    /// Throws if the dock-space watcher can't spawn — that channel
    /// is load-bearing, so the caller is expected to `die`.
    func start() throws {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(onFrontAppChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
        )
        try dockSpaceWatcher.start()
        evaluate(trigger: .start)
    }

    /// Called from the daemon's signal handler so the watcher's
    /// termination handler doesn't `die` on graceful shutdown.
    func stop() {
        dockSpaceWatcher.stop()
    }

    @objc private func onFrontAppChange(_: Notification) {
        let app = NSWorkspace.shared.frontmostApplication
        Log.controller.debug("\(Self.formatFrontChange(app), privacy: .public)")
        evaluate(trigger: .frontApp)
    }

    func updateMedia(_ snapshot: NowPlayingSnapshot) {
        isPlaying = snapshot.playing
        nowPlayingPID = snapshot.pid
        nowPlayingBundle = snapshot.bundle
        nowPlayingParentBundle = snapshot.parentBundle
        evaluate(trigger: .adapter)
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
        evaluate(trigger: .dockFs)
    }

    /// Refreshes `dockFs.pid` so the multi-display gate doesn't
    /// reject FS↔FS hops with a stale pid. Guarded on cached
    /// `isFullScreen` because the no-op fires for non-FS hops too;
    /// the line's `state` field is unreliable across transition
    /// phases. `frontmostApplication` is fresh here — the log
    /// subprocess pipeline serializes after AppKit propagates the
    /// new frontmost.
    private func onStaySpaceChange() {
        guard dockFs.isFullScreen,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else { return }
        dockFs = DockFullScreenState(isFullScreen: true, pid: pid)
        evaluate(trigger: .dockStay)
    }

    private func evaluate(trigger: EvalTrigger) {
        let snap = takeSnapshot()
        guard snap != lastSnapshot else {
            Log.controller.debug(
                "eval_suppressed trig=\(trigger.rawValue, privacy: .public)",
            )
            return
        }
        lastSnapshot = snap

        menuBar.apply(shouldHide: snap.decision.shouldHide)
        logSnapshot(snap, trigger: trigger)
    }

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

    /// Two scannable lines for the unified log:
    ///
    ///   {HIDE|SHOW(reason)}  trig=<src> front=<head>[pid=…,name=…,bundle=…,fs=…,fsPid=…]
    ///   np=<head>[pid=…,bundle=…,parent=…,resp=…,play=…]
    ///
    /// `<head>` is the bundle's last 1–2 dot components (`Chrome`,
    /// `WebKit.GPU`) — a visual anchor for scanning. Missing
    /// optionals render as `null` (preserving absent-vs-empty);
    /// values with spaces are double-quoted so downstream
    /// space-tokenizing parsers see them as one field. Leading `\n`
    /// pushes the body onto its own row under the unified-log prefix.
    private func logSnapshot(_ snap: Snapshot, trigger: EvalTrigger) {
        Log.controller.info(
            "\n\(Self.formatSnapshot(snap, trigger: trigger), privacy: .public)",
        )
    }

    private static func formatSnapshot(_ snap: Snapshot, trigger: EvalTrigger) -> String {
        // Two lines because the single-line form wrapped on most
        // terminals once full bundles + parent + resp were included.
        """
        \(snap.decision.tag)  trig=\(trigger.rawValue) front=\(formatFront(snap))
        np=\(formatNowPlaying(snap))
        """
    }

    private static func formatFrontChange(_ app: NSRunningApplication?) -> String {
        let pid = formatNullable(app?.processIdentifier)
        let bundle = formatNullableString(app?.bundleIdentifier)
        let name = quoteString(app?.localizedName ?? "(unknown)")
        return "front_change pid=\(pid) bundle=\(bundle) name=\(name)"
    }

    private static func formatFront(_ snap: Snapshot) -> String {
        let head = bundleShort(snap.frontBundle) ?? ""
        let pid = formatNullable(snap.frontPID?.rawValue)
        let name = quoteString(snap.frontName)
        let bundle = formatNullableString(snap.frontBundle)
        let resp = formatNullable(snap.frontPID?.responsiblePID)
        let fs = snap.dockFs.isFullScreen ? "yes" : "no"
        let fsPid = formatNullable(snap.dockFs.pid)
        return "\(head)[pid=\(pid),name=\(name),bundle=\(bundle),resp=\(resp),fs=\(fs),fsPid=\(fsPid)]"
    }

    private static func formatNowPlaying(_ snap: Snapshot) -> String {
        let head = bundleShort(snap.nowPlayingBundle) ?? ""
        let pid = formatNullable(snap.nowPlayingPID?.rawValue)
        let bundle = formatNullableString(snap.nowPlayingBundle)
        let parent = formatNullableString(snap.nowPlayingParentBundle)
        let resp = formatNullable(snap.nowPlayingPID?.responsiblePID)
        let play = snap.isPlaying ? "yes" : "no"
        return "\(head)[pid=\(pid),bundle=\(bundle),parent=\(parent),resp=\(resp),play=\(play)]"
    }

    /// `com.apple.Safari` → `Safari`, `com.apple.WebKit.GPU` →
    /// `WebKit.GPU`. Returns nil for nil/empty so the caller can
    /// omit the head.
    private static func bundleShort(_ bundle: String?) -> String? {
        guard let bundle, !bundle.isEmpty else { return nil }
        let parts = bundle.split(separator: ".")
        return parts.count >= 3
            ? parts.dropFirst(2).joined(separator: ".")
            : bundle
    }

    /// Specialized to pid_t so interpolation goes through Int32's
    /// direct path rather than `String(describing:)`'s reflection
    /// fallback.
    private static func formatNullable(_ value: pid_t?) -> String {
        value.map { "\($0)" } ?? "null"
    }

    /// Distinguishes nil (`null`) from empty (`""`) so the log
    /// preserves "field absent" vs. "MediaRemote reported the field
    /// as empty" — the underlying optionals mean genuinely different
    /// things (e.g. a nil parentBundle is "no helper relationship").
    private static func formatNullableString(_ value: String?) -> String {
        guard let value else { return "null" }
        return value.contains(" ") || value.isEmpty
            ? "\"\(value)\""
            : value
    }

    /// Always quote — `name` is a free-form display string that may
    /// contain spaces, parens, or LTR markers.
    private static func quoteString(_ value: String) -> String {
        "\"\(value)\""
    }
}
