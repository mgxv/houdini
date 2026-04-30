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
    case showWindowMismatch

    var shouldHide: Bool {
        if case .hide = self { return true }
        return false
    }

    var tag: String {
        switch self {
        case .hide: "→ HIDE"
        case .showNotFullScreen: "→ SHOW(not_fullscreen)"
        case .showNotPlaying: "→ SHOW(not_playing)"
        case .showNoFrontPid: "→ SHOW(no_front_pid)"
        case .showNoNowPlayingPid: "→ SHOW(no_now_playing_pid)"
        case .showFrontNotFsOwner: "→ SHOW(front_not_fs_owner)"
        case .showAppMismatch: "→ SHOW(app_mismatch)"
        case .showWindowMismatch: "→ SHOW(window_mismatch)"
        }
    }
}

enum EvalTrigger: String {
    case start
    case frontApp = "front_app"
    case dockFs = "dock_fs"
    case dockStay = "dock_stay"
    case adapter
    case window
}

/// `frontPID.isSameApp(asFSOwnerPID: dockFs.pid)` is the multi-display
/// gate: if FS Chrome is on display 2 but the user is focused on a
/// windowed app on display 1, the front PID won't resolve to the same
/// responsible app as the Dock-reported FS owner and we keep the menu
/// bar visible.
///
/// Same-app-as-Now-Playing tests (process-level — either is sufficient):
///   1. Responsibility-PID mapping via the kernel syscall
///      (`FrontmostPID.isSameProcess(as:)`), which handles helper
///      processes (WebKit.GPU resolves to Safari) without adapter
///      cooperation.
///   2. Frontmost bundle id matches Now Playing's
///      `parentApplicationBundleIdentifier` — MediaRemote's direct
///      assertion of the owning app, a fallback if the responsibility
///      syscall regresses.
///
/// Window-level refinement runs only after the process check passes:
/// case-sensitive substring match between Now Playing's `title` and
/// the focused window's title. Catches the "two FS Chrome windows,
/// only one playing" case where process equality alone says hide.
/// Lenient on missing data — if either side's title is nil/empty,
/// fall through to hide so we don't flicker on title-lag right after
/// focus changes.
func menuBarDecision(
    dockFs: DockFullScreenState,
    isPlaying: Bool,
    frontPID: FrontmostPID?,
    frontBundle: String?,
    frontWindowTitle: String?,
    nowPlayingPID: NowPlayingPID?,
    nowPlayingParentBundle: String?,
    nowPlayingTitle: String?,
) -> MenuBarDecision {
    guard dockFs.isFullScreen else { return .showNotFullScreen }
    guard isPlaying else { return .showNotPlaying }
    guard let frontPID else { return .showNoFrontPid }
    guard let nowPlayingPID else { return .showNoNowPlayingPid }

    guard let dockFsPID = dockFs.pid else { return .showFrontNotFsOwner }
    guard frontPID.isSameApp(asFSOwnerPID: dockFsPID) else { return .showFrontNotFsOwner }

    let processMatch = frontPID.isSameProcess(as: nowPlayingPID)
    let bundleMatch: Bool = {
        guard let parent = nowPlayingParentBundle, !parent.isEmpty else { return false }
        return parent == frontBundle
    }()
    guard processMatch || bundleMatch else { return .showAppMismatch }

    if let npTitle = nowPlayingTitle, !npTitle.isEmpty,
       let winTitle = frontWindowTitle, !winTitle.isEmpty,
       !winTitle.contains(npTitle)
    {
        return .showWindowMismatch
    }
    return .hide
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
        let frontWindowTitle: String?
        let dockFs: DockFullScreenState
        let isPlaying: Bool
        let nowPlayingPID: NowPlayingPID?
        let nowPlayingBundle: String?
        let nowPlayingParentBundle: String?
        let nowPlayingTitle: String?

        var decision: MenuBarDecision {
            menuBarDecision(
                dockFs: dockFs,
                isPlaying: isPlaying,
                frontPID: frontPID,
                frontBundle: frontBundle,
                frontWindowTitle: frontWindowTitle,
                nowPlayingPID: nowPlayingPID,
                nowPlayingParentBundle: nowPlayingParentBundle,
                nowPlayingTitle: nowPlayingTitle,
            )
        }
    }

    private let menuBar: MenuBarToggler
    private var dockFs: DockFullScreenState = .initial
    private var isPlaying: Bool = false
    private var nowPlayingPID: NowPlayingPID?
    private var nowPlayingBundle: String?
    private var nowPlayingParentBundle: String?
    private var nowPlayingTitle: String?
    private var lastSnapshot: Snapshot?

    private lazy var dockSpaceWatcher = DockSpaceWatcher { [weak self] event in
        self?.handleDockEvent(event)
    }

    /// AX events fire `evaluate(.window)` so within-app focus and
    /// title changes (tab switches, page navigation) refresh the
    /// window-title check without requiring a front-app change.
    /// AX permission isn't load-bearing — when it isn't granted, the
    /// watcher is a no-op and the daemon degrades to process-level
    /// matching only.
    ///
    /// Each event is logged as `→ AX_EVENT` for diagnostics — useful
    /// when the daemon's decision and the user's perception disagree
    /// (e.g. background-tab webview activity firing focus events
    /// against a non-visible window in Chrome).
    private lazy var axWatcher = AXWatcher { [weak self] name, element in
        guard let self else { return }
        Log.controller.debug(
            "\(Self.formatAXEvent(name: name, element: element), privacy: .public)",
        )
        evaluate(trigger: .window)
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
        axWatcher.attach(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        evaluate(trigger: .start)
    }

    /// Called from the daemon's signal handler so the watcher's
    /// termination handler doesn't `die` on graceful shutdown.
    func stop() {
        dockSpaceWatcher.stop()
        axWatcher.detach()
    }

    @objc private func onFrontAppChange(_: Notification) {
        let app = NSWorkspace.shared.frontmostApplication
        Log.controller.debug("\(Self.formatFrontChange(app), privacy: .public)")
        axWatcher.attach(pid: app?.processIdentifier)
        evaluate(trigger: .frontApp)
    }

    func updateMedia(_ snapshot: NowPlayingSnapshot) {
        isPlaying = snapshot.playing
        nowPlayingPID = snapshot.pid
        nowPlayingBundle = snapshot.bundle
        nowPlayingParentBundle = snapshot.parentBundle
        nowPlayingTitle = snapshot.title
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

        // AX events fire on every UI focus move; the focused
        // element's window often reads as nil-title for ~50–500ms
        // during normal interaction. Suppress AX-driven nil-title
        // evaluations so the menu bar doesn't flicker on every
        // keystroke / focus shift. Non-AX triggers (front_app,
        // dock_fs, dock_stay, adapter, start) still go through with
        // nil so legitimate app/state changes aren't lost.
        if trigger == .window, snap.frontWindowTitle == nil {
            Log.controller.debug(
                "eval_suppressed_null_window trig=\(trigger.rawValue, privacy: .public)",
            )
            return
        }

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
        // Skip the AX/CGWindow walk when an earlier gate will
        // short-circuit anyway. Pulled fresh otherwise — AX state
        // drifts within an app (tab switches, page nav) so the title
        // can't be cached on `frontApp` change alone.
        let needsTitle = dockFs.isFullScreen
            && isPlaying
            && frontPID != nil
            && nowPlayingPID != nil
        let frontWindowTitle = needsTitle
            ? visibleWindowTitle(for: frontApp?.processIdentifier)
            : nil

        return Snapshot(
            frontPID: frontPID,
            frontName: frontName,
            frontBundle: frontBundle,
            frontWindowTitle: frontWindowTitle,
            dockFs: dockFs,
            isPlaying: isPlaying,
            nowPlayingPID: nowPlayingPID,
            nowPlayingBundle: nowPlayingBundle,
            nowPlayingParentBundle: nowPlayingParentBundle,
            nowPlayingTitle: nowPlayingTitle,
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
        → NP=\(formatNowPlaying(snap))
        """
    }

    private static func formatFrontChange(_ app: NSRunningApplication?) -> String {
        let pid = formatNullable(app?.processIdentifier)
        let bundle = formatNullableString(app?.bundleIdentifier)
        let name = quoteString(app?.localizedName ?? "(unknown)")
        return "front_change pid=\(pid) bundle=\(bundle) name=\(name)"
    }

    /// One line per AX notification, with the focused element's
    /// containing window title surfaced — lets you correlate a
    /// HIDE/SHOW decision to the AX event that triggered it.
    private static func formatAXEvent(name: String, element: AXUIElement) -> String {
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier ?? 0
        let appName = quoteString(app?.localizedName ?? "(unknown)")
        let title = quoteString(windowTitle(forElement: element) ?? "")
        return "→ AX_EVENT name=\(name) app=\(appName) pid=\(pid) window=\(title)"
    }

    private static func formatFront(_ snap: Snapshot) -> String {
        let head = bundleShort(snap.frontBundle) ?? ""
        let pid = formatNullable(snap.frontPID?.rawValue)
        let name = quoteString(snap.frontName)
        let bundle = formatNullableString(snap.frontBundle)
        let resp = formatNullable(snap.frontPID?.responsiblePID)
        let fs = snap.dockFs.isFullScreen ? "yes" : "no"
        let fsPid = formatNullable(snap.dockFs.pid)
        let win = formatNullableString(snap.frontWindowTitle)
        return "\(head)[pid=\(pid),name=\(name),bundle=\(bundle),resp=\(resp),fs=\(fs),fsPid=\(fsPid),win=\(win)]"
    }

    private static func formatNowPlaying(_ snap: Snapshot) -> String {
        let head = bundleShort(snap.nowPlayingBundle) ?? ""
        let pid = formatNullable(snap.nowPlayingPID?.rawValue)
        let bundle = formatNullableString(snap.nowPlayingBundle)
        let parent = formatNullableString(snap.nowPlayingParentBundle)
        let resp = formatNullable(snap.nowPlayingPID?.responsiblePID)
        let play = snap.isPlaying ? "yes" : "no"
        let title = formatNullableString(snap.nowPlayingTitle)
        return "\(head)[pid=\(pid),bundle=\(bundle),parent=\(parent),resp=\(resp),play=\(play),title=\(title)]"
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
    /// Quotes spaces / empty / embedded `"`; embedded `"` is escaped
    /// so the quoted span tokenizes as one field.
    private static func formatNullableString(_ value: String?) -> String {
        guard let value else { return "null" }
        let needsQuoting = value.isEmpty || value.contains(" ") || value.contains("\"")
        guard needsQuoting else { return value }
        return "\"\(escapeQuotes(value))\""
    }

    /// Always quote — `name` is a free-form display string that may
    /// contain spaces, parens, or LTR markers. Embedded `"` is escaped.
    private static func quoteString(_ value: String) -> String {
        "\"\(escapeQuotes(value))\""
    }

    private static func escapeQuotes(_ value: String) -> String {
        value.contains("\"")
            ? value.replacingOccurrences(of: "\"", with: "\\\"")
            : value
    }
}
