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
            fullScreen: isAppFullScreen(pid: frontPID?.rawValue),
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
    ///   {HIDE|SHOW}  front=<head>[pid=<pid>,name=<name>,bundle=<bundle>,fs=<yes|no>]
    ///   np=<head>[pid=<pid>,bundle=<bundle>,parent=<parent>,resp=<resp>,play=<yes|no>]
    ///
    /// `<head>` is the bundle's last 1–2 dot components (`Chrome`,
    /// `WebKit.GPU`) — a cheap visual anchor for scanning. Empty when
    /// the bundle is nil. The bracketed body emits every original field;
    /// missing optionals are explicit `null` (so absent vs. empty stays
    /// distinguishable from the log alone). String values with spaces
    /// are double-quoted so a downstream space-tokenizing parser sees
    /// them as one field.
    ///
    /// Example:
    ///   HIDE  front=Safari[pid=37860,name="Safari",bundle=com.apple.Safari,fs=yes]
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
            "fs=\(snap.fullScreen ? "yes" : "no")",
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
