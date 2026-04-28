// Fuses Now Playing state and Dock-reported fullscreen-Space state
// into one decision, only writing the menu-bar pref when that decision
// actually changes.

import Cocoa

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
    /// `shouldHide` is derived, so Equatable on the inputs alone
    /// dedups redundant writes without caching the decision.
    /// `frontPID` and `nowPlayingPID` are distinct types so the
    /// compiler blocks accidental role swaps.
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
        evaluate()
    }

    /// Called from the daemon's signal handler so the watcher's
    /// termination handler doesn't `die` on graceful shutdown.
    func stop() {
        dockSpaceWatcher.stop()
    }

    @objc private func onFrontAppChange(_: Notification) {
        evaluate()
    }

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
        evaluate()
    }

    private func evaluate() {
        let snap = takeSnapshot()
        guard snap != lastSnapshot else { return }
        lastSnapshot = snap

        menuBar.apply(shouldHide: snap.shouldHide)
        logSnapshot(snap)
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
    ///   {HIDE|SHOW}  front=<head>[pid=…,name=…,bundle=…,fs=…,fsPid=…]
    ///   np=<head>[pid=…,bundle=…,parent=…,resp=…,play=…]
    ///
    /// `<head>` is the bundle's last 1–2 dot components (`Chrome`,
    /// `WebKit.GPU`) — a visual anchor for scanning. Missing
    /// optionals render as `null` (preserving absent-vs-empty);
    /// values with spaces are double-quoted so downstream
    /// space-tokenizing parsers see them as one field. Leading `\n`
    /// pushes the body onto its own row under the unified-log prefix.
    private func logSnapshot(_ snap: Snapshot) {
        Log.controller.info("\n\(Self.formatSnapshot(snap), privacy: .public)")
    }

    private static func formatSnapshot(_ snap: Snapshot) -> String {
        let decision = snap.shouldHide ? "HIDE" : "SHOW"
        // Two lines because the single-line form wrapped on most
        // terminals once full bundles + parent + resp were included.
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
