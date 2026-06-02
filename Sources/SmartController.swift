// Fuses Now Playing state and Dock-reported fullscreen-Space state
// into one decision, only writing the menu-bar pref when that
// decision actually changes. The pure decision logic lives in
// `MenuBarDecision.swift`; this file orchestrates inputs, applies
// the verdict to the menu bar, and surfaces snapshots in the log.

import Cocoa

// MARK: - File-level types

private enum EvalTrigger: String {
    case start
    case frontApp = "front_app"
    case dockFs = "dock_fs"
    case dockStay = "dock_stay"
    case adapter
    case hotkey
    case overrides
    case wake
}

enum Overrule: String {
    /// Daemon-driven (no manual override active). Spelled `.auto`
    /// rather than `.none` to avoid shadowing `Optional.none` if
    /// `Overrule` ever appears wrapped in an Optional.
    case auto
    case forceHide = "force_hide"
    case forceShow = "force_show"
}

// MARK: - SmartController

@MainActor
final class SmartController: NSObject {
    // MARK: - Snapshot

    /// Decision is derived, so Equatable on the inputs alone dedups
    /// redundant writes without caching it. `appKitFrontPID` and
    /// `nowPlayingPID` are distinct types so the compiler blocks
    /// accidental role swaps.
    ///
    /// Field-name source key (where each input comes from):
    ///
    ///   `appKitFront*`         — AppKit `NSWorkspace.frontmostApplication`
    ///   `dockFs.*`             — Dock log `Space Forces Hidden:` line
    ///                            (`com.apple.dock` / `dock-visibility`)
    ///   `nowPlaying*` / `isPlaying`
    ///                          — MediaRemote via mediaremote-adapter
    private struct Snapshot: Equatable {
        let appKitFrontPID: FrontmostPID?
        let appKitFrontName: String
        let appKitFrontBundle: String?
        let dockFs: DockFullScreenState
        let isPlaying: Bool
        let nowPlayingPID: NowPlayingPID?
        let nowPlayingBundle: String?
        let nowPlayingParentBundle: String?
        let nowPlayingTitle: String?
        let appOverrides: AppOverrides
        var overrule: Overrule

        var decision: MenuBarDecision {
            menuBarDecision(
                dockFs: dockFs,
                isPlaying: isPlaying,
                appKitFrontPID: appKitFrontPID,
                appKitFrontBundle: appKitFrontBundle,
                nowPlayingPID: nowPlayingPID,
                nowPlayingParentBundle: nowPlayingParentBundle,
                appOverrides: appOverrides,
            )
        }

        var effectiveShouldHide: Bool {
            switch overrule {
            case .forceHide: true
            case .forceShow: false
            case .auto: decision.shouldHide
            }
        }

        /// Log verb that matches the effective outcome — so an active
        /// overrule reads as `hide(force_hide)` / `show(force_show)`
        /// instead of the underlying daemon decision.
        var effectiveTag: String {
            switch overrule {
            case .forceHide: "hide(force_hide)"
            case .forceShow: "show(force_show)"
            case .auto: decision.tag
            }
        }
    }

    // MARK: - State

    private let menuBar: MenuBarToggling
    private let frontmostProvider: FrontmostAppProvider
    /// One-shot Now Playing fetch to re-prime media on wake; `nil` in
    /// tests / when no adapter is wired.
    private let nowPlayingReprime: (@MainActor () -> NowPlayingSnapshot?)?
    private var dockFs: DockFullScreenState = .initial
    private var isPlaying: Bool = false
    private var nowPlayingPID: NowPlayingPID?
    private var nowPlayingBundle: String?
    private var nowPlayingParentBundle: String?
    private var nowPlayingTitle: String?
    private var appOverrides: AppOverrides = .empty

    /// Hotkey-driven override. Cleared only on Desktop arrival;
    /// survives front-app switches, FS↔FS hops, play/pause, and
    /// sleep/wake.
    var overrule: Overrule = .auto

    private var lastSnapshot: Snapshot?

    // MARK: - Watchers

    private lazy var dockSpaceWatcher = DockSpaceWatcher { [weak self] event in
        self?.handleDockEvent(event)
    }

    private lazy var hotkeyWatcher = HotkeyWatcher { [weak self] in
        self?.toggleOverrule()
    }

    // MARK: - Lifecycle

    init(
        menuBar: MenuBarToggling,
        frontmostProvider: FrontmostAppProvider = WorkspaceFrontmostAppProvider(),
        nowPlayingReprime: (@MainActor () -> NowPlayingSnapshot?)? = nil,
    ) {
        self.menuBar = menuBar
        self.frontmostProvider = frontmostProvider
        self.nowPlayingReprime = nowPlayingReprime
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(onWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil,
        )
        try dockSpaceWatcher.start()
        HotkeyState.write(hotkeyWatcher.start() ? "registered" : "failed")
        evaluate(trigger: .start)
    }

    /// Called from the daemon's signal handler so the watcher's
    /// termination handler doesn't `die` on graceful shutdown.
    func stop() {
        dockSpaceWatcher.stop()
        hotkeyWatcher.stop()
        HotkeyState.clear()
    }

    // MARK: - Input handlers

    @objc private func onFrontAppChange(_: Notification) {
        handleFrontAppChange()
    }

    func handleFrontAppChange() {
        let app = frontmostProvider.frontmostApp
        Log.controller.debug("→ \(Self.formatFrontChange(app), privacy: .public)")
        // front_app fires ~30–60ms before dock_stay on FS↔FS hops.
        // Refresh fsOwnerPID so gate 5 doesn't trip on the prior
        // Space's cached owner; dock_stay then dedups.
        if dockFs.isFullScreen, let pid = app?.pid {
            refreshFSOwner(pid: pid)
        }
        evaluate(trigger: .frontApp)
    }

    func updateMedia(_ snapshot: NowPlayingSnapshot) {
        applyMedia(snapshot)
        evaluate(trigger: .adapter)
    }

    private func applyMedia(_ snapshot: NowPlayingSnapshot) {
        isPlaying = snapshot.playing
        nowPlayingPID = snapshot.pid
        nowPlayingBundle = snapshot.bundle
        nowPlayingParentBundle = snapshot.parentBundle
        nowPlayingTitle = snapshot.title
    }

    @objc private func onWake(_: Notification) {
        handleWake()
    }

    /// Re-prime cached signals from authoritative sources on wake (Dock
    /// and the adapter stream can both go stale across sleep), then force
    /// a re-eval so the pref is re-asserted even if nothing net-changed.
    func handleWake() {
        Log.controller.debug("→ wake_rx")
        if let snapshot = nowPlayingReprime?() {
            applyMedia(snapshot)
        }
        if dockFs.isFullScreen, let pid = frontmostProvider.frontmostApp?.pid {
            refreshFSOwner(pid: pid)
        }
        evaluate(trigger: .wake, force: true)
    }

    func updateOverrides(_ overrides: AppOverrides) {
        guard appOverrides != overrides else { return }
        appOverrides = overrides
        evaluate(trigger: .overrides)
    }

    func handleDockEvent(_ event: DockSpaceEvent) {
        switch event {
        case let .fullScreenState(state):
            updateDockFullScreen(state)
        case .staySpaceChange:
            onStaySpaceChange()
        case .desktopArrival:
            onDesktopArrival()
        }
    }

    private func updateDockFullScreen(_ state: DockFullScreenState) {
        dockFs = state
        evaluate(trigger: .dockFs)
    }

    /// Refreshes `dockFs.fsOwnerPID` so the multi-display gate
    /// doesn't reject FS↔FS hops with a stale pid. Guarded on cached
    /// `isFullScreen` because the no-op fires for non-FS hops too;
    /// the line's `state` field is unreliable across transition
    /// phases. `frontmostApplication` is fresh here — the log
    /// subprocess pipeline serializes after AppKit propagates the
    /// new frontmost.
    private func onStaySpaceChange() {
        guard dockFs.isFullScreen,
              let pid = frontmostProvider.frontmostApp?.pid
        else { return }
        refreshFSOwner(pid: pid)
        evaluate(trigger: .dockStay)
    }

    private func onDesktopArrival() {
        overrule = .auto
        menuBar.resetToVisible()
    }

    private func refreshFSOwner(pid: pid_t) {
        dockFs = DockFullScreenState(
            isFullScreen: true,
            fsOwnerPID: FSOwnerPID(pid),
            dockWindowTitle: dockFs.dockWindowTitle,
        )
    }

    // MARK: - Override handling

    /// Refused on Desktop — pref is FS-only.
    func toggleOverrule() {
        guard dockFs.isFullScreen else {
            Log.controller.info("→ hotkey ignored (not in fullscreen)")
            return
        }
        let snap = takeSnapshot()
        overrule = snap.effectiveShouldHide ? .forceShow : .forceHide
        evaluate(trigger: .hotkey)
    }

    // MARK: - Evaluation core

    /// Single point of integration — every input channel funnels
    /// here. The `trigger` is preserved through to the log line so a
    /// surprising decision can be traced back to its input. `force`
    /// bypasses the snapshot dedup to re-assert the pref even when
    /// nothing changed (used on wake).
    private func evaluate(trigger: EvalTrigger, force: Bool = false) {
        let snap = takeSnapshot()

        if !force, let last = lastSnapshot, snap == last {
            Log.controller.debug(
                "→ eval_skipped trig=\(trigger.rawValue, privacy: .public)",
            )
            return
        }
        lastSnapshot = snap

        menuBar.apply(
            shouldHide: snap.effectiveShouldHide,
            isFullScreen: snap.dockFs.isFullScreen,
        )
        logSnapshot(snap, trigger: trigger)
    }

    /// Pure function of `SmartController`'s cached state — never mutates.
    private func takeSnapshot() -> Snapshot {
        let frontApp = frontmostProvider.frontmostApp
        let appKitFrontPID = frontApp.map { FrontmostPID($0.pid) }
        let appKitFrontName = frontApp?.name ?? "(unknown)"
        let appKitFrontBundle = frontApp?.bundle

        return Snapshot(
            appKitFrontPID: appKitFrontPID,
            appKitFrontName: appKitFrontName,
            appKitFrontBundle: appKitFrontBundle,
            dockFs: dockFs,
            isPlaying: isPlaying,
            nowPlayingPID: nowPlayingPID,
            nowPlayingBundle: nowPlayingBundle,
            nowPlayingParentBundle: nowPlayingParentBundle,
            nowPlayingTitle: nowPlayingTitle,
            appOverrides: appOverrides,
            overrule: overrule,
        )
    }

    /// Two scannable lines for the unified log:
    ///
    ///   → {hide|show(reason)|hide(force_hide)|show(force_show)}
    ///       trig=<src>  overrule=<auto|force_…>
    ///       appMatch=<…>  front_tx=<bundle>[…]
    ///   → np_tx=<bundle>[…]
    ///
    /// `<bundle>` is the front-app / Now-Playing bundle id rendered
    /// via `formatNullableString` (`null` for absent, `""` for empty)
    /// — same convention as fields inside the brackets. Values with
    /// spaces are double-quoted so downstream space-tokenizing
    /// parsers see them as one field.
    private func logSnapshot(_ snap: Snapshot, trigger: EvalTrigger) {
        let head = Self.formatSnapshotHead(snap, trigger: trigger)
        let np = Self.formatSnapshotNowPlaying(snap)
        Log.controller.info("→ \(head, privacy: .public)")
        Log.controller.info("→ \(np, privacy: .public)")
    }

    // MARK: - Log formatting — snapshot lines

    private static func formatSnapshotHead(_ snap: Snapshot, trigger: EvalTrigger) -> String {
        let tag = snap.effectiveTag
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

    /// Which gate-6 path matched (process / bundle / both / none) —
    /// `n/a` if a pid was missing. Diagnostic, computed alongside the
    /// decision rather than returned from it.
    private static func formatAppMatch(_ snap: Snapshot) -> String {
        guard let appKitFrontPID = snap.appKitFrontPID,
              let npPID = snap.nowPlayingPID else { return "n/a" }
        let process = appKitFrontPID.isSameProcess(as: npPID)
        let bundle = bundlePathMatches(
            parent: snap.nowPlayingParentBundle,
            front: snap.appKitFrontBundle,
        )
        switch (process, bundle) {
        case (true, true): return "both"
        case (true, false): return "process"
        case (false, true): return "bundle"
        case (false, false): return "none"
        }
    }

    private static func formatFront(_ snap: Snapshot) -> String {
        let bundle = formatNullableString(snap.appKitFrontBundle)
        let pid = formatNullable(snap.appKitFrontPID?.rawValue)
        let name = quoted(snap.appKitFrontName)
        let resp = formatNullable(snap.appKitFrontPID?.responsiblePID)
        let fs = snap.dockFs.isFullScreen
        let fsPid = formatNullable(snap.dockFs.fsOwnerPID?.rawValue)
        return "\(bundle)[pid=\(pid),name=\(name),bundle=\(bundle),resp=\(resp),fs=\(fs),fsPid=\(fsPid)]"
    }

    private static func formatNowPlaying(_ snap: Snapshot) -> String {
        let bundle = formatNullableString(snap.nowPlayingBundle)
        let pid = formatNullable(snap.nowPlayingPID?.rawValue)
        let parent = formatNullableString(snap.nowPlayingParentBundle)
        let resp = formatNullable(snap.nowPlayingPID?.responsiblePID)
        let play = snap.isPlaying
        let title = formatNullableString(snap.nowPlayingTitle)
        return "\(bundle)[pid=\(pid),bundle=\(bundle),parent=\(parent),resp=\(resp),play=\(play),title=\(title)]"
    }

    // MARK: - Log formatting — boundary breadcrumbs

    private static func formatFrontChange(_ app: FrontmostInfo?) -> String {
        let pid = formatNullable(app?.pid)
        let bundle = formatNullableString(app?.bundle)
        let name = quoted(app?.name ?? "(unknown)")
        return "front_rx pid=\(pid) bundle=\(bundle) name=\(name)"
    }

    // MARK: - Log formatting — string utilities

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
