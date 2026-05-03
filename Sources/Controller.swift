// Fuses Now Playing state and Dock-reported fullscreen-Space state
// into one decision, only writing the menu-bar pref when that
// decision actually changes. The pure decision logic lives in
// `MenuBarDecision.swift`; this file orchestrates inputs, applies
// the verdict to the menu bar, and surfaces snapshots in the log.

import Cocoa

// MARK: - File-level types

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

/// Tab/window identity for `Controller.overrideMap`. `windowTitle`
/// is the focused window's normalized AX title — the per-tab
/// signal, since browsers put the page name there. `frontBundle`
/// guards against same-titled windows in different apps colliding.
/// `nowPlayingTitle` is captured at pin time as a second match
/// axis: HBO Max (and other episode-based players) roll the window
/// title per episode but keep the Now Playing title stable as the
/// show name, so falling back to NP-title equality preserves the
/// pin across episodes when the window title rolls.
struct OverrideKey: Hashable {
    let frontBundle: String?
    let windowTitle: String
    let nowPlayingTitle: String?

    init(
        frontBundle: String?,
        windowTitle: String,
        nowPlayingTitle: String? = nil,
    ) {
        self.frontBundle = frontBundle
        self.windowTitle = windowTitle
        self.nowPlayingTitle = nowPlayingTitle
    }
}

extension OverrideKey {
    /// True if this key's window title matches the queried one under
    /// the same bundle. nil/empty queried titles never match.
    func matchesByWindow(
        frontBundle queryBundle: String?,
        windowTitle queryTitle: String?,
    ) -> Bool {
        guard let q = queryTitle, !q.isEmpty else { return false }
        return frontBundle == queryBundle && windowTitle == q
    }

    /// True if this key's stored NP title matches the queried one
    /// under the same bundle. nil/empty on either side never matches —
    /// keeps a no-NP-at-pin-time entry from collapsing onto every
    /// future no-NP query.
    func matchesByNowPlaying(
        frontBundle queryBundle: String?,
        nowPlayingTitle queryTitle: String?,
    ) -> Bool {
        guard let stored = nowPlayingTitle, !stored.isEmpty else { return false }
        guard let q = queryTitle, !q.isEmpty else { return false }
        return frontBundle == queryBundle && stored == q
    }

    /// Two keys overlap when they're for the same app and either title
    /// axis would match. Used at re-pin to drop stale entries before
    /// inserting, so the same logical context (re-pinning on a
    /// different episode of the same show, etc.) doesn't accumulate
    /// contradictory overrides.
    func overlaps(_ other: OverrideKey) -> Bool {
        matchesByWindow(
            frontBundle: other.frontBundle,
            windowTitle: other.windowTitle,
        )
            || matchesByNowPlaying(
                frontBundle: other.frontBundle,
                nowPlayingTitle: other.nowPlayingTitle,
            )
    }
}

/// Diagnostic only — surfaces in the log line whether a snapshot's
/// overrule came from the per-tab map or the no-context fallback.
enum OverruleSource: Equatable {
    case auto
    case sticky
    case global
}

// MARK: - Controller

@MainActor
final class Controller: NSObject {
    // MARK: - Snapshot

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
        /// Source: `AXWatcher.focusEpoch`. Lets `signalsEqual`
        /// detect tab switches when the window title is stable
        /// across them. Not consulted by `menuBarDecision` —
        /// pure delta-detection signal. Excluded from
        /// `decisionEqual` so a focus shift with no
        /// decision-relevant change doesn't re-emit a snapshot.
        var focusEpoch: UInt64
        var overrule: Overrule
        /// Diagnostic only — `(sticky)` vs `(global)` in the log.
        /// Excluded from both equality predicates.
        var overruleSource: OverruleSource

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

        /// Equality ignoring `overrule` — distinguishes a real
        /// state change from a heartbeat so a no-op input can't
        /// clear the `globalOverrule` fallback. The per-tab
        /// `overrideMap` is never auto-cleared.
        func signalsEqual(_ other: Snapshot) -> Bool {
            var copy = self
            copy.overrule = other.overrule
            copy.overruleSource = other.overruleSource
            return copy == other
        }

        /// Equality on fields that drive the menu-bar output.
        /// Layers on `signalsEqual` (which already excludes
        /// `overrule` + `overruleSource`) and additionally
        /// ignores `focusEpoch` — delta-detection only, bumping
        /// it on every AX focus shift would re-emit a redundant
        /// snapshot even though nothing user-visible changed.
        func decisionEqual(_ other: Snapshot) -> Bool {
            var copy = self
            copy.focusEpoch = other.focusEpoch
            return copy.signalsEqual(other)
        }
    }

    // MARK: - State

    private let menuBar: MenuBarToggler
    private var dockFs: DockFullScreenState = .initial
    private var isPlaying: Bool = false
    private var nowPlayingPID: NowPlayingPID?
    private var nowPlayingBundle: String?
    private var nowPlayingParentBundle: String?
    private var nowPlayingTitle: String?

    /// Per-tab pinned overrides. Sticky for the daemon's lifetime
    /// — never auto-cleared, only replaced by a hotkey press in
    /// the same context.
    private var overrideMap: [OverrideKey: Overrule] = [:]

    /// One-shot fallback used when no `OverrideKey` is computable
    /// (AX denied, or focused window has no title). Auto-cleared
    /// by the next real signal change so the hotkey still works
    /// without AX permission.
    private var globalOverrule: Overrule = .auto

    private var lastSnapshot: Snapshot?

    // MARK: - Watchers

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

    // MARK: - Lifecycle

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

    // MARK: - Input handlers

    @objc private func onFrontAppChange(_: Notification) {
        let app = NSWorkspace.shared.frontmostApplication
        Log.controller.debug("→ \(Self.formatFrontChange(app), privacy: .public)")
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
        dockFs = DockFullScreenState(isFullScreen: true, pid: FSOwnerPID(pid))
        evaluate(trigger: .dockStay)
    }

    // MARK: - Override handling

    /// Flips the bar against its current effective state and pins
    /// that choice under the current key. Falls through to
    /// `globalOverrule` when no key is computable. Re-pinning in
    /// the same logical context (same bundle + matching window or
    /// NP title) replaces the prior entry so the map can't hold
    /// contradictory overrides for what the user perceives as the
    /// same surface.
    private func toggleOverrule() {
        let snap = takeSnapshot()
        let next: Overrule = snap.effectiveShouldHide ? .forceShow : .forceHide

        if let key = overrideKey(
            forBundle: snap.frontBundle,
            windowTitle: snap.frontWindowTitle,
            nowPlayingTitle: snap.nowPlayingTitle,
        ) {
            overrideMap = overrideMap.filter { !$0.key.overlaps(key) }
            overrideMap[key] = next
            // Sticky takes priority; drop any stale fallback.
            globalOverrule = .auto
        } else {
            globalOverrule = next
        }
        evaluate(trigger: .hotkey)
    }

    /// nil when the focused window has no usable AX title — the
    /// caller falls through to `globalOverrule`.
    private func overrideKey(
        forBundle bundle: String?,
        windowTitle: String?,
        nowPlayingTitle: String?,
    ) -> OverrideKey? {
        guard let title = windowTitle, !title.isEmpty else { return nil }
        let normalized = normalizeWindowTitle(title)
        guard !normalized.isEmpty else { return nil }
        let np: String? = (nowPlayingTitle?.isEmpty == false) ? nowPlayingTitle : nil
        return OverrideKey(
            frontBundle: bundle,
            windowTitle: normalized,
            nowPlayingTitle: np,
        )
    }

    /// Map first (sticky), then `globalOverrule` (one-shot),
    /// then `.auto`. The map scan tries window-title equality
    /// first (more specific), then falls back to NP-title equality
    /// — resolves the HBO-style case where window titles roll per
    /// episode but the NP title stays stable as the show name.
    /// Two passes over the (very small) map make the priority
    /// deterministic regardless of dictionary iteration order.
    private func resolveOverrule(
        frontBundle: String?,
        frontWindowTitle: String?,
        nowPlayingTitle: String?,
    ) -> (Overrule, OverruleSource) {
        let normalizedWindow: String? = {
            guard let t = frontWindowTitle, !t.isEmpty else { return nil }
            let n = normalizeWindowTitle(t)
            return n.isEmpty ? nil : n
        }()
        let np: String? = (nowPlayingTitle?.isEmpty == false) ? nowPlayingTitle : nil

        if normalizedWindow != nil || np != nil {
            for (key, overrule) in overrideMap
                where key.matchesByWindow(
                    frontBundle: frontBundle,
                    windowTitle: normalizedWindow,
                )
            {
                return (overrule, .sticky)
            }
            for (key, overrule) in overrideMap
                where key.matchesByNowPlaying(
                    frontBundle: frontBundle,
                    nowPlayingTitle: np,
                )
            {
                return (overrule, .sticky)
            }
        }
        if globalOverrule != .auto {
            return (globalOverrule, .global)
        }
        return (.auto, .auto)
    }

    // MARK: - Evaluation core

    /// Single point of integration — every input channel funnels
    /// here. Builds a fresh snapshot, decides whether to clear the
    /// no-context fallback, dedups against the prior snapshot, and
    /// applies the resulting hide/show to the menu bar. The
    /// `trigger` is preserved through to the log line so a
    /// surprising decision can be traced back to its input.
    private func evaluate(trigger: EvalTrigger) {
        var snap = takeSnapshot()

        // AX fires on every focus move; the focused window's title
        // often reads nil for ~50–500ms during normal interaction.
        // Suppress AX nil-title evals so the bar doesn't flicker on
        // every keystroke / focus shift. Non-AX triggers (front_app,
        // dock_fs, dock_stay, adapter, start) still go through with
        // nil so legitimate app/state changes aren't lost. When an
        // overrule is active we also let AX through — the focusEpoch
        // bump on a real focus change is the signal that clears the
        // global fallback.
        if trigger == .window, snap.frontWindowTitle == nil, snap.overrule == .auto {
            Log.controller.debug(
                "→ eval_skipped_no_window trig=\(trigger.rawValue, privacy: .public)",
            )
            return
        }

        // Auto-clear the one-shot fallback on real state changes.
        // The per-tab `overrideMap` is intentionally sticky.
        let signalsChanged = lastSnapshot.map { !snap.signalsEqual($0) } ?? true
        if trigger != .hotkey, signalsChanged, globalOverrule != .auto {
            globalOverrule = .auto
            let (resolved, source) = resolveOverrule(
                frontBundle: snap.frontBundle,
                frontWindowTitle: snap.frontWindowTitle,
                nowPlayingTitle: snap.nowPlayingTitle,
            )
            snap.overrule = resolved
            snap.overruleSource = source
        }

        // Dedup the apply + log on decision-relevant fields only.
        // A focus-only delta (focusEpoch bumped, nothing else
        // changed, overrule stable) refreshes lastSnapshot's epoch
        // so the next signalsEqual is comparable, but doesn't
        // re-emit a snapshot line for state the user already saw.
        if let last = lastSnapshot,
           snap.decisionEqual(last),
           snap.overrule == last.overrule
        {
            lastSnapshot = snap
            Log.controller.debug(
                "→ eval_skipped trig=\(trigger.rawValue, privacy: .public)",
            )
            return
        }
        lastSnapshot = snap

        menuBar.apply(shouldHide: snap.effectiveShouldHide)
        logSnapshot(snap, trigger: trigger)
    }

    /// Captures a consistent snapshot of every input the decision
    /// reads, plus `focusEpoch` (so `signalsEqual` can spot tab
    /// switches) and the resolved overrule for this snapshot's
    /// context. Pure function of `Controller`'s cached state plus
    /// a single fresh AX/CG probe — never mutates anything.
    private func takeSnapshot() -> Snapshot {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontPID = frontApp.map { FrontmostPID($0.processIdentifier) }
        let frontName = frontApp?.localizedName ?? "(unknown)"
        let frontBundle = frontApp?.bundleIdentifier
        // Probe whenever a FS frontmost app exists. Can't gate on
        // `isPlaying` — the title is also `signalsEqual`'s delta
        // signal for tab-switch overrule clearing. Gate 1
        // (not_fullscreen) still avoids the probe in the common
        // non-FS case.
        let needsTitle = dockFs.isFullScreen && frontPID != nil
        let probe: WindowTitleProbe = needsTitle
            ? visibleWindowTitle(for: frontApp?.processIdentifier)
            : .skipped
        let frontWindowTitle: String? = probe.status == .empty ? "" : probe.title

        let (resolvedOverrule, overruleSource) = resolveOverrule(
            frontBundle: frontBundle,
            frontWindowTitle: frontWindowTitle,
            nowPlayingTitle: nowPlayingTitle,
        )

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
            focusEpoch: axWatcher.focusEpoch,
            overrule: resolvedOverrule,
            overruleSource: overruleSource,
        )
    }

    /// Two scannable lines for the unified log:
    ///
    ///   → {hide|show(reason)|hide(force_hide)|show(force_show)}
    ///       trig=<src>  overrule=<auto|force_…[(sticky|global)]>
    ///       appMatch=<…>  front_tx=<head>[…]
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
        Log.controller.info("→ \(head, privacy: .public)")
        Log.controller.info("→ \(np, privacy: .public)")
    }

    // MARK: - Log formatting — snapshot lines

    private static func formatSnapshotHead(_ snap: Snapshot, trigger: EvalTrigger) -> String {
        let tag = snap.effectiveTag
        let trig = trigger.rawValue
        let overrule = formatOverrule(snap.overrule, source: snap.overruleSource)
        return """
        \(tag)  trig=\(trig) overrule=\(overrule) \
        appMatch=\(formatAppMatch(snap)) front_tx=\(formatFront(snap))
        """
    }

    private static func formatSnapshotNowPlaying(_ snap: Snapshot) -> String {
        "np_tx=\(formatNowPlaying(snap))"
    }

    /// `auto` / `force_hide(sticky)` / `force_show(global)` etc.
    /// — distinguishes per-tab from one-shot in the log.
    private static func formatOverrule(_ overrule: Overrule, source: OverruleSource) -> String {
        switch overrule {
        case .auto: "auto"
        case .forceHide, .forceShow:
            switch source {
            case .auto: overrule.rawValue
            case .sticky: "\(overrule.rawValue)(sticky)"
            case .global: "\(overrule.rawValue)(global)"
            }
        }
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

    // MARK: - Log formatting — boundary breadcrumbs

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
        let pid = formatNullable(app?.processIdentifier)
        let appName = quotedNullable(app?.localizedName)
        let title = formatNullableString(windowTitle(forElement: element))
        return "ax_rx name=\(name) app=\(appName) pid=\(pid) window=\(title)"
    }

    // MARK: - Log formatting — string utilities

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

    private static func quotedNullable(_ value: String?) -> String {
        value.map { quoted($0) } ?? "null"
    }

    private static func escapeQuotes(_ value: String) -> String {
        value.contains("\"")
            ? value.replacingOccurrences(of: "\"", with: "\\\"")
            : value
    }
}
