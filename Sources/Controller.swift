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

    /// JSON-encoded snapshot, pretty-printed via `JSONEncoder`. Field
    /// order is the property-declaration order of the payload structs
    /// below (CodingKeys are synthesized in the same order). Leading
    /// `\n` puts the JSON body on its own line under the unified-log
    /// prefix; trailing `\n` adds a blank line between events.
    private func logSnapshot(_ snap: Snapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(LogPayload(snap)),
              let json = String(data: data, encoding: .utf8)
        else {
            Log.controller.error("failed to encode snapshot for logging")
            return
        }
        Log.controller.info("\n\(json, privacy: .public)\n")
    }

    private struct FrontPayload: Encodable {
        let pid: pid_t?
        let name: String
        let bundle: String?
        let fullscreen: Bool
    }

    private struct NowPlayingPayload: Encodable {
        let pid: pid_t
        let bundle: String?
        let parentBundle: String?
        let responsiblePID: pid_t?
        let playing: Bool
    }

    private struct LogPayload: Encodable {
        let shouldHide: Bool
        let front: FrontPayload
        let nowPlaying: NowPlayingPayload?

        init(_ snap: Snapshot) {
            shouldHide = snap.shouldHide
            front = FrontPayload(
                pid: snap.frontPID?.rawValue,
                name: snap.frontName,
                bundle: snap.frontBundle,
                fullscreen: snap.fullScreen,
            )
            if let npPID = snap.nowPlayingPID {
                nowPlaying = NowPlayingPayload(
                    pid: npPID.rawValue,
                    bundle: snap.nowPlayingBundle,
                    parentBundle: snap.nowPlayingParentBundle,
                    responsiblePID: npPID.responsiblePID,
                    playing: snap.isPlaying,
                )
            } else {
                nowPlaying = nil
            }
        }

        enum CodingKeys: String, CodingKey {
            case shouldHide, front, nowPlaying
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(shouldHide, forKey: .shouldHide)
            try container.encode(front, forKey: .front)
            try container.encodeIfPresent(nowPlaying, forKey: .nowPlaying)
        }
    }
}
