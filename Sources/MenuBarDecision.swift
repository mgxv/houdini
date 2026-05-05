// The seven-gate decision that drives the menu bar. Pure function
// of (Dock fullscreen state, Now Playing state, frontmost app,
// focused-window title) returning `hide` or `show(reason)`. Pinned
// by `MenuBarDecisionTests`; SmartController composes the inputs and
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

/// Returns `.hide` only when every gate passes; each `show*` case
/// names the gate that rejected. Order matters — earlier gates
/// short-circuit later ones (`MenuBarDecisionTests.gateOrdering`).
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
    // 1 — fullscreen Space is active. Outside fullscreen the OS
    // shows the menu bar via its own auto-hide pref; the rest of
    // the gates only matter in FS.
    guard dockFs.isFullScreen else { return .showNotFullScreen }

    // 2 — media is actually playing. Paused/idle media never
    // warrants hiding.
    guard isPlaying else { return .showNotPlaying }

    // 3 & 4 — both pids are known. Needed for the same-app checks
    // below; reported separately so the log shows which side was
    // missing.
    guard let appKitFrontPID else { return .showNoFrontPid }
    guard let nowPlayingPID else { return .showNoNowPlayingPid }

    // 5 — frontmost app owns the active fullscreen Space (multi-
    // display guard). With FS Chrome on display 2 and a windowed
    // app focused on display 1, the front PID won't resolve to the
    // FS-Space owner and we keep the bar visible.
    guard let fsOwnerPID = dockFs.fsOwnerPID,
          appKitFrontPID.isSameApp(asFSOwnerPID: fsOwnerPID)
    else { return .showFrontNotFsOwner }

    // 6 — frontmost is the same app as Now Playing.
    guard isSameAppAsNowPlaying(
        appKitFrontPID: appKitFrontPID,
        appKitFrontBundle: appKitFrontBundle,
        nowPlayingPID: nowPlayingPID,
        nowPlayingParentBundle: nowPlayingParentBundle,
    ) else { return .showAppMismatch }

    // 7 — focused window's title and the Now Playing track refer to
    // the same media (bidirectional substring).
    guard titleMatchesNowPlaying(
        winTitle: axFocusedWindowTitle,
        npTitle: nowPlayingTitle,
    ) else { return .showWindowMismatch }

    return .hide
}

// MARK: - Gate helpers

/// Gate 6 — process or bundle path is sufficient.
///
/// process — responsibility-pid resolution via the kernel syscall.
///           Handles helper processes (WebKit.GPU → Safari) without
///           adapter cooperation.
/// bundle  — frontmost bundle id matches Now Playing's
///           `parentApplicationBundleIdentifier`. MediaRemote's
///           direct assertion of the owning app — a fallback if the
///           responsibility syscall regresses.
private func isSameAppAsNowPlaying(
    appKitFrontPID: FrontmostPID,
    appKitFrontBundle: String?,
    nowPlayingPID: NowPlayingPID,
    nowPlayingParentBundle: String?,
) -> Bool {
    if appKitFrontPID.isSameProcess(as: nowPlayingPID) { return true }
    if let parent = nowPlayingParentBundle, !parent.isEmpty,
       parent == appKitFrontBundle { return true }
    return false
}

/// Gate 7 — bidirectional case-sensitive substring between the
/// focused window's title and the Now Playing track. Either
/// direction is accepted: `winTitle ⊇ npTitle` for the common
/// "two FS Chrome windows, only one playing" case that gate 6
/// alone can't refute, plus `npTitle ⊇ winTitle` for native
/// players whose window title is a shorter form of the NP string
/// (e.g. window=`"Bohemian Rhapsody"`, NP=`"Bohemian Rhapsody — Queen"`).
///
/// Polarities:
///   nil/empty NP        — no track to match against → lenient hide.
///   nil window          — AX unknown → lenient hide.
///   probe-confirmed ""  — strict show(window_mismatch).
///
/// The explicit `!winTitle.isEmpty` is what enforces the strict-
/// empty path: Swift's `String.contains("")` returns true, which
/// would otherwise let the reverse direction silently hide.
private func titleMatchesNowPlaying(winTitle: String?, npTitle: String?) -> Bool {
    guard let npTitle, !npTitle.isEmpty else { return true }
    guard let winTitle else { return true }
    guard !winTitle.isEmpty else { return false }
    return winTitle.contains(npTitle) || npTitle.contains(winTitle)
}
