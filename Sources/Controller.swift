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

    /// The reason as a short identifier — `hide` or
    /// `show(<reason>)`. The `→ ` log prefix is added by the
    /// formatter, not stored here, so consumers that want the bare
    /// reason (e.g. for a non-log surface) don't have to strip it.
    var tag: String {
        switch self {
        case .hide: "hide"
        case .showNotFullScreen: "show(not_fullscreen)"
        case .showNotPlaying: "show(not_playing)"
        case .showNoFrontPid: "show(no_front_pid)"
        case .showNoNowPlayingPid: "show(no_now_playing_pid)"
        case .showFrontNotFsOwner: "show(front_not_fs_owner)"
        case .showAppMismatch: "show(app_mismatch)"
        case .showWindowMismatch: "show(window_mismatch)"
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
    case hotkey
}

enum Overrule: String {
    /// Daemon-driven (no manual override active). Spelled `.auto`
    /// rather than `.none` to avoid shadowing `Optional.none` if
    /// `Overrule` ever appears wrapped in an Optional.
    case auto
    case forceHide = "force_hide"
    case forceShow = "force_show"
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
///
/// Front-window-title `nil` = AX unknown → lenient hide; `""` =
/// probe-confirmed no titled window → show(window_mismatch).
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
       let winTitle = frontWindowTitle,
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
        /// Diagnostic only — splits a nil title into skipped / denied /
        /// empty / ok in the log so it's debuggable beyond just "nil."
        let frontWindowProbeStatus: WindowTitleProbeStatus
        let dockFs: DockFullScreenState
        let isPlaying: Bool
        let nowPlayingPID: NowPlayingPID?
        let nowPlayingBundle: String?
        let nowPlayingParentBundle: String?
        let nowPlayingTitle: String?
        var overrule: Overrule

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

        var effectiveShouldHide: Bool {
            switch overrule {
            case .forceHide: true
            case .forceShow: false
            case .auto: decision.shouldHide
            }
        }

        /// Equality ignoring `overrule` — distinguishes a real state
        /// change from a heartbeat so no-op input can't clear an
        /// active overrule.
        func signalsEqual(_ other: Snapshot) -> Bool {
            var copy = self
            copy.overrule = other.overrule
            return copy == other
        }
    }

    private let menuBar: MenuBarToggler
    private var dockFs: DockFullScreenState = .initial
    private var isPlaying: Bool = false
    private var nowPlayingPID: NowPlayingPID?
    private var nowPlayingBundle: String?
    private var nowPlayingParentBundle: String?
    private var nowPlayingTitle: String?
    private var overrule: Overrule = .auto
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
    /// Each event is logged as `→ ax_rx` for diagnostics — useful
    /// when the daemon's decision and the user's perception disagree
    /// (e.g. background-tab webview activity firing focus events
    /// against a non-visible window in Chrome).
    private lazy var axWatcher = AXWatcher { [weak self] name, element in
        guard let self else { return }
        Log.controller.debug(
            "→ \(Self.formatAXEvent(name: name, element: element), privacy: .public)",
        )
        evaluate(trigger: .window)
    }

    private lazy var hotkeyWatcher = HotkeyWatcher { [weak self] in
        self?.toggleOverrule()
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
        HotkeyState.write(hotkeyWatcher.start() ? "registered" : "failed")
        evaluate(trigger: .start)
    }

    /// Called from the daemon's signal handler so the watcher's
    /// termination handler doesn't `die` on graceful shutdown.
    func stop() {
        dockSpaceWatcher.stop()
        axWatcher.detach()
        hotkeyWatcher.stop()
        HotkeyState.clear()
    }

    @objc private func onFrontAppChange(_: Notification) {
        let app = NSWorkspace.shared.frontmostApplication
        Log.controller.debug("→ \(Self.formatFrontChange(app), privacy: .public)")
        axWatcher.attach(pid: app?.processIdentifier)
        evaluate(trigger: .frontApp)
    }

    private func toggleOverrule() {
        let hidden = lastSnapshot?.effectiveShouldHide ?? false
        overrule = hidden ? .forceShow : .forceHide
        evaluate(trigger: .hotkey)
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
        dockFs = DockFullScreenState(isFullScreen: true, pid: FSOwnerPID(pid))
        evaluate(trigger: .dockStay)
    }

    private func evaluate(trigger: EvalTrigger) {
        var snap = takeSnapshot()

        // AX fires on every focus move; the focused window's title
        // often reads nil for ~50–500ms during normal interaction.
        // Suppress AX nil-title evals so the bar doesn't flicker on
        // every keystroke / focus shift. Non-AX triggers (front_app,
        // dock_fs, dock_stay, adapter, start) still go through with
        // nil so legitimate app/state changes aren't lost. Runs before
        // the overrule reset so a suppressed event doesn't silently
        // clear a manual overrule.
        if trigger == .window, snap.frontWindowTitle == nil {
            Log.controller.debug(
                "→ eval_skipped_no_window trig=\(trigger.rawValue, privacy: .public)",
            )
            return
        }

        // Return control to the daemon only on a real state change.
        // Without the signalsEqual guard, an adapter heartbeat or AX
        // focus refresh (constant during playback, identical fields)
        // would clear an active force_hide / force_show on every tick.
        let signalsChanged = lastSnapshot.map { !snap.signalsEqual($0) } ?? true
        if trigger != .hotkey, signalsChanged {
            overrule = .auto
            snap.overrule = .auto
        }

        guard snap != lastSnapshot else {
            Log.controller.debug(
                "→ eval_skipped trig=\(trigger.rawValue, privacy: .public)",
            )
            return
        }
        lastSnapshot = snap

        menuBar.apply(shouldHide: snap.effectiveShouldHide)
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
        let probe: WindowTitleProbe = needsTitle
            ? visibleWindowTitle(for: frontApp?.processIdentifier)
            : .skipped
        let frontWindowTitle: String? = probe.status == .empty ? "" : probe.title

        return Snapshot(
            frontPID: frontPID,
            frontName: frontName,
            frontBundle: frontBundle,
            frontWindowTitle: frontWindowTitle,
            frontWindowProbeStatus: probe.status,
            dockFs: dockFs,
            isPlaying: isPlaying,
            nowPlayingPID: nowPlayingPID,
            nowPlayingBundle: nowPlayingBundle,
            nowPlayingParentBundle: nowPlayingParentBundle,
            nowPlayingTitle: nowPlayingTitle,
            overrule: overrule,
        )
    }

    /// Two scannable lines for the unified log:
    ///
    ///   → {hide|show(reason)}  trig=<src>  appMatch=<…>  front_tx=<head>[…]
    ///   → np_tx=<head>[…]
    ///
    /// `<head>` is the bundle's last 1–2 dot components (`Chrome`,
    /// `WebKit.GPU`) — a visual anchor for scanning. Missing
    /// optionals render as `null` (preserving absent-vs-empty);
    /// values with spaces are double-quoted so downstream
    /// space-tokenizing parsers see them as one field.
    private func logSnapshot(_ snap: Snapshot, trigger: EvalTrigger) {
        let head = Self.formatSnapshotHead(snap, trigger: trigger)
        let np = Self.formatSnapshotNowPlaying(snap)
        Log.controller.info(
            """
            → \(head, privacy: .public)
            → \(np, privacy: .public)
            """,
        )
    }

    private static func formatSnapshotHead(_ snap: Snapshot, trigger: EvalTrigger) -> String {
        let tag = snap.decision.tag
        let trig = trigger.rawValue
        let overrule = snap.overrule.rawValue
        return """
        \(tag)  trig=\(trig) overrule=\(overrule) \
        appMatch=\(formatAppMatch(snap)) front_tx=\(formatFront(snap))
        """
    }

    private static func formatSnapshotNowPlaying(_ snap: Snapshot) -> String {
        "np_tx=\(formatNowPlaying(snap))"
    }

    /// Which gate-7 path matched (process / bundle / both / none) —
    /// `n/a` if a pid was missing. Diagnostic, computed alongside the
    /// decision rather than returned from it.
    private static func formatAppMatch(_ snap: Snapshot) -> String {
        guard let frontPID = snap.frontPID, let npPID = snap.nowPlayingPID else { return "n/a" }
        let process = frontPID.isSameProcess(as: npPID)
        let bundle: Bool = if let parent = snap.nowPlayingParentBundle, !parent.isEmpty {
            parent == snap.frontBundle
        } else {
            false
        }
        switch (process, bundle) {
        case (true, true): return "both"
        case (true, false): return "process"
        case (false, true): return "bundle"
        case (false, false): return "none"
        }
    }

    private static func formatFrontChange(_ app: NSRunningApplication?) -> String {
        let pid = formatNullable(app?.processIdentifier)
        let bundle = formatNullableString(app?.bundleIdentifier)
        let name = quoted(app?.localizedName ?? "(unknown)")
        return "front_rx pid=\(pid) bundle=\(bundle) name=\(name)"
    }

    /// One line per AX notification, with the focused element's
    /// containing window title surfaced — lets you correlate a
    /// hide/show decision to the AX event that triggered it.
    private static func formatAXEvent(name: String, element: AXUIElement) -> String {
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier ?? 0
        let appName = quoted(app?.localizedName ?? "(unknown)")
        let title = formatNullableString(windowTitle(forElement: element))
        return "ax_rx name=\(name) app=\(appName) pid=\(pid) window=\(title)"
    }

    private static func formatFront(_ snap: Snapshot) -> String {
        let head = bundleShort(snap.frontBundle) ?? ""
        let pid = formatNullable(snap.frontPID?.rawValue)
        let name = quoted(snap.frontName)
        let bundle = formatNullableString(snap.frontBundle)
        let resp = formatNullable(snap.frontPID?.responsiblePID)
        let fs = snap.dockFs.isFullScreen ? "yes" : "no"
        let fsPid = formatNullable(snap.dockFs.pid?.rawValue)
        let win = formatNullableString(snap.frontWindowTitle)
        let probe = snap.frontWindowProbeStatus.rawValue
        return "\(head)[pid=\(pid),name=\(name),bundle=\(bundle),resp=\(resp),fs=\(fs),fsPid=\(fsPid),win=\(win),probe=\(probe)]"
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
    private static func quoted(_ value: String) -> String {
        "\"\(escapeQuotes(value))\""
    }

    private static func escapeQuotes(_ value: String) -> String {
        value.contains("\"")
            ? value.replacingOccurrences(of: "\"", with: "\\\"")
            : value
    }
}
