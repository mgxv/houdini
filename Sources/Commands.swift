// Implementations of the CLI verbs: (default) foreground run,
// `status`, `logs`, `version`, `help`. LaunchAgent lifecycle is
// delegated to Homebrew (`brew services`).

import Cocoa
import Foundation

// MARK: - Foreground

/// Runs the daemon loop. Intended to be invoked by launchd via
/// `brew services`; runs fine in a terminal for local debugging too.
func runForeground() {
    acquireInstanceLock()
    ensureAccessibilityPermission()
    let artifacts = locateArtifacts()

    let menuBar = MenuBarToggler()
    menuBar.resetToVisible()

    let controller = Controller(menuBar: menuBar)

    // Seed the controller with a one-shot Now Playing snapshot before
    // starting it, so the first logged evaluation reflects the real
    // current state rather than "playing=false nowPlaying=-" from
    // before the streaming adapter has delivered its first event.
    // If the one-shot fails, we skip priming and the initial line just
    // shows empty Now Playing state — not worth aborting startup over.
    if let np = fetchNowPlayingOnce(artifacts: artifacts) {
        controller.updateMedia(playing: np.playing, pid: np.pid, bundle: np.bundle)
    }

    let adapter = AdapterClient(
        artifacts: artifacts,
        onUpdate: controller.updateMedia,
    )

    controller.start()
    do {
        try adapter.start()
    } catch {
        die("failed to start mediaremote-adapter subprocess: \(error)")
    }

    let signalSources = installSignalHandlers {
        menuBar.resetToVisible()
        adapter.stop()
    }

    Log.general.notice("houdini \(houdiniVersion, privacy: .public) running")
    print("houdini running. Press Ctrl-C to quit.")
    withExtendedLifetime(signalSources) {
        RunLoop.main.run()
    }
}

/// Installs main-thread SIGINT/SIGTERM handlers that run `shutdown`
/// before exit. The returned sources must be kept alive by the caller.
func installSignalHandlers(_ shutdown: @escaping () -> Void) -> [DispatchSourceSignal] {
    [SIGINT, SIGTERM].map { sig in
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler {
            Log.general.notice("houdini stopping")
            print("\nhoudini stopping…")
            shutdown()
            exit(0)
        }
        src.resume()
        return src
    }
}

// MARK: - status

/// Samples the inputs that drive the daemon's decision and prints a
/// synthetic snapshot. Read-only: never writes the menu-bar pref, never
/// prompts for Accessibility permission, safe to run while the daemon
/// is active. The snapshot is independent — it doesn't talk to the
/// running daemon; it just re-samples the same inputs.
func runStatus() -> Never {
    let artifacts = locateArtifacts()

    let frontApp = NSWorkspace.shared.frontmostApplication
    let frontPID = frontApp.map { FrontmostPID($0.processIdentifier) }
    let frontName = frontApp?.localizedName ?? "-"
    let frontPIDStr = frontPID?.description ?? "-"

    // Fullscreen requires Accessibility. Use the non-prompting check so
    // `status` has no side effects; report "unknown" if permission is
    // missing rather than asking for it here.
    let fullscreen: Bool? = isAccessibilityTrusted()
        ? isFocusedWindowFullScreen(pid: frontPID?.rawValue)
        : nil

    let np = fetchNowPlayingOnce(artifacts: artifacts)

    let (decision, reason): (String, String?) = {
        guard let fullscreen else {
            return ("unknown", "Accessibility permission not granted — run `houdini` once to prompt")
        }
        let shouldHide = shouldHideMenuBar(
            fullScreen: fullscreen,
            isPlaying: np?.playing ?? false,
            frontPID: frontPID,
            nowPlayingPID: np?.pid,
        )
        if shouldHide { return ("HIDE", nil) }
        return ("SHOW", showReason(frontPID: frontPID, fullscreen: fullscreen, np: np))
    }()

    let fsStr = fullscreen.map { $0 ? "yes" : "no" } ?? "unknown"
    print("daemon:   \(probeDaemonRunning() ? "running" : "not running")")
    print("front:    \(frontName) (pid=\(frontPIDStr), fullscreen=\(fsStr))")
    switch np {
    case .none:
        print("playing:  (adapter failed)")
    case let .some(snap) where snap.pid == nil:
        print("playing:  (nothing)")
    case let .some(snap):
        let bundle = snap.bundle ?? "-"
        let pidStr = snap.pid?.description ?? "-"
        let playStr = snap.playing ? "yes" : "no"
        print("playing:  \(bundle) (pid=\(pidStr), playing=\(playStr))")
    }
    if let reason {
        print("decision: \(decision)  (\(reason))")
    } else {
        print("decision: \(decision)")
    }
    exit(0)
}

/// Explains why `shouldHide` is false, picking the first unmet
/// precondition in logical order so the message names something the
/// user can act on.
private func showReason(
    frontPID: FrontmostPID?,
    fullscreen: Bool,
    np: NowPlayingSnapshot?,
) -> String {
    if frontPID == nil { return "no frontmost app" }
    if !fullscreen { return "frontmost is not fullscreen" }
    guard let np else { return "adapter failed — cannot determine Now Playing" }
    if np.pid == nil { return "nothing is using Now Playing" }
    if !np.playing { return "the Now Playing source is paused" }
    return "frontmost and Now Playing are different processes"
}

// MARK: - version

func runVersion() -> Never {
    print("houdini \(houdiniVersion)")
    exit(0)
}

// MARK: - logs

/// Streams houdini's entries from the unified log by shelling out to
/// `/usr/bin/log stream`. `--level info` is required to include the
/// HIDE/SHOW decisions (which are logged at `.info`); warnings and
/// errors come through at default level. For history, use `log show`
/// directly.
func runLogs(args: [String]) -> Never {
    if let extra = args.first {
        die("unknown argument for logs: '\(extra)' — try: houdini logs")
    }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    proc.arguments = [
        "stream",
        "--predicate", "subsystem == \"\(Log.subsystem)\"",
        "--level", "info",
        "--style", "compact",
    ]
    do {
        try proc.run()
    } catch {
        die("failed to exec /usr/bin/log: \(error)")
    }
    proc.waitUntilExit()
    exit(proc.terminationStatus)
}

// MARK: - help

func usage() {
    print("""
    houdini — hides the menu bar when the frontmost fullscreen app is
    the same one playing in the system Now Playing widget.

    Usage:
      houdini                   Run the daemon (invoked by brew services)
      houdini status            Print frontmost/Now-Playing state and the
                                hide/show decision the daemon would make
      houdini logs              Stream houdini's unified-log entries
                                (wraps `log stream --predicate …`)
      houdini version           Print version
      houdini help              Print this help

    Install and autostart are managed via Homebrew:
      brew services start houdini
      brew services stop houdini
      brew services info houdini
    """)
}
