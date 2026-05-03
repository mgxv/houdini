// The seven-gate decision that drives the menu bar. Pure function
// of (Dock fullscreen state, Now Playing state, frontmost app,
// focused-window title) returning `hide` or `show(reason)`. Pinned
// by `MenuBarDecisionTests`; Controller composes the inputs and
// applies the verdict, but the gates themselves live here.

import Foundation

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

/// `appKitFrontPID.isSameApp(asFSOwnerPID: dockFs.fsOwnerPID)` is the multi-display
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
    appKitFrontPID: FrontmostPID?,
    appKitFrontBundle: String?,
    axFocusedWindowTitle: String?,
    nowPlayingPID: NowPlayingPID?,
    nowPlayingParentBundle: String?,
    nowPlayingTitle: String?,
) -> MenuBarDecision {
    guard dockFs.isFullScreen else { return .showNotFullScreen }
    guard isPlaying else { return .showNotPlaying }
    guard let appKitFrontPID else { return .showNoFrontPid }
    guard let nowPlayingPID else { return .showNoNowPlayingPid }

    guard let fsOwnerPID = dockFs.fsOwnerPID else { return .showFrontNotFsOwner }
    guard appKitFrontPID.isSameApp(asFSOwnerPID: fsOwnerPID) else { return .showFrontNotFsOwner }

    let processMatch = appKitFrontPID.isSameProcess(as: nowPlayingPID)
    let bundleMatch: Bool = {
        guard let parent = nowPlayingParentBundle, !parent.isEmpty else { return false }
        return parent == appKitFrontBundle
    }()
    guard processMatch || bundleMatch else { return .showAppMismatch }

    if let npTitle = nowPlayingTitle, !npTitle.isEmpty,
       let winTitle = axFocusedWindowTitle,
       !winTitle.contains(npTitle)
    {
        return .showWindowMismatch
    }
    return .hide
}
