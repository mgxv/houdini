// Implementations of the CLI verbs: (default) foreground run,
// `status`, `logs`, `version`, `help`. LaunchAgent lifecycle is
// delegated to Homebrew (`brew services`).

import Cocoa
import Foundation

// MARK: - Foreground

/// Runs the daemon loop. Intended to be invoked by launchd via
/// `brew services`; runs fine in a terminal for local debugging too.
@MainActor
func runForeground() {
    acquireInstanceLock()
    ensureAccessibilityPermission()
    let artifacts = locateArtifacts()

    let menuBar = MenuBarToggler()
    menuBar.resetToVisible()

    let controller = Controller(menuBar: menuBar)

    // Seed the controller with a one-shot Now Playing snapshot before
    // starting it, so the first logged evaluation reflects the real
    // current state rather than a blank "(no Now Playing source)"
    // placeholder from before the streaming adapter delivers its first
    // event. If the one-shot fails, we skip priming — not worth
    // aborting startup over.
    if let snapshot = fetchNowPlayingOnce(artifacts: artifacts) {
        controller.updateMedia(snapshot)
    }

    let adapter = AdapterClient(
        artifacts: artifacts,
        onUpdate: { @MainActor snapshot in
            controller.updateMedia(snapshot)
        },
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

    Log.general.notice("houdini \(version, privacy: .public) running")
    print("houdini \(version) running. Press Ctrl-C to quit.")
    withExtendedLifetime(signalSources) {
        RunLoop.main.run()
    }
}

/// Installs main-thread SIGINT/SIGTERM handlers that run `shutdown`
/// before exit. The returned sources must be kept alive by the caller.
@MainActor
func installSignalHandlers(_ shutdown: @escaping @MainActor () -> Void) -> [DispatchSourceSignal] {
    [SIGINT, SIGTERM].map { sig in
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler {
            // The source is queued on .main, so this handler runs on the
            // main thread — but DispatchSource's event handler isn't
            // statically main-actor-isolated. Assume the isolation so we
            // can call @MainActor APIs synchronously before exit().
            MainActor.assumeIsolated {
                Log.general.notice("houdini \(version, privacy: .public) stopping")
                print("\nhoudini \(version) stopping…")
                shutdown()
                exit(0)
            }
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
@MainActor
func runStatus() -> Never {
    let artifacts = locateArtifacts()

    let frontApp = NSWorkspace.shared.frontmostApplication
    let frontPID = frontApp.map { FrontmostPID($0.processIdentifier) }
    let frontName = frontApp?.localizedName ?? "-"
    let frontBundle = frontApp?.bundleIdentifier
    let frontPIDStr = frontPID?.description ?? "-"

    // Fullscreen requires Accessibility. Use the non-prompting check
    // so `status` has no side effects; report "unknown" if permission
    // is missing rather than asking for it here. `axTrusted` is read
    // once so the `perms:` line and the fullscreen branch agree.
    let axTrusted = isAccessibilityTrusted()
    let fullscreen: Bool? = axTrusted
        ? isFocusedWindowFullScreen(pid: frontPID?.rawValue)
        : nil

    let np = fetchNowPlayingOnce(artifacts: artifacts)

    let decision: String = {
        guard let fullscreen else { return "unknown" }
        let shouldHide = shouldHideMenuBar(
            fullScreen: fullscreen,
            isPlaying: np?.playing ?? false,
            frontPID: frontPID,
            frontBundle: frontBundle,
            nowPlayingPID: np?.pid,
            nowPlayingParentBundle: np?.parentBundle,
        )
        return shouldHide ? "HIDE" : "SHOW"
    }()

    // Focus-independent block: true regardless of which app is
    // frontmost when `status` is invoked. Print first so these are
    // easy to spot even in a long output.
    print("version:  houdini \(version)")
    print("daemon:   \(probeDaemonRunning() ? "running" : "not running")")
    if axTrusted {
        print("perms:    Accessibility granted")
    } else {
        print("perms:    Accessibility not granted")
        print("          brew services restart houdini")
    }
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

    // Focus-dependent block: running `houdini status` from a terminal
    // makes the terminal frontmost, so `front` and `decision` reflect
    // that rather than whatever the daemon is currently deciding.
    // Direct the user to the logs if they want the daemon's live view.
    // The command is offset to the value column (10 spaces) so it
    // aligns with other values and is visually easy to spot and copy.
    print("")
    print("— `front:` and `decision:` below show this terminal's view,")
    print("  not the daemon's. for the daemon's live decisions, run:")
    print("")
    print("          houdini logs controller")
    print("")
    let fsStr = fullscreen.map { $0 ? "yes" : "no" } ?? "unknown"
    print("front:    \(frontName) (pid=\(frontPIDStr), fullscreen=\(fsStr))")
    print("decision: \(decision)")
    exit(0)
}

// MARK: - version

@MainActor
func runVersion() -> Never {
    print("houdini \(version)")
    exit(0)
}

// MARK: - logs

/// Streams houdini's entries from the unified log by shelling out to
/// `/usr/bin/log stream`. An optional category argument narrows the
/// stream to one of `controller`, `adapter`, or `general`. `adapter`
/// uses `--level debug` because subprocess output is logged there;
/// the rest stay at `info`. For history, use `log show` directly.
@MainActor
func runLogs(args: [String]) -> Never {
    if args.count > 1 {
        die("too many arguments for logs — try: houdini logs [controller|adapter|general]")
    }

    let (category, level): (String?, String) = switch args.first {
    case nil: (nil, "info")
    case "controller": ("controller", "info")
    case "adapter": ("adapter", "debug")
    case "general": ("general", "info")
    case let other?: die("unknown category '\(other)' — expected: controller, adapter, general")
    }

    var predicate = "subsystem == \"\(Log.subsystem)\""
    if let category {
        predicate += " AND category == \"\(category)\""
    }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    proc.arguments = [
        "stream",
        "--predicate", predicate,
        "--level", level,
        "--style", "compact",
    ]

    // Ctrl-C sends SIGINT to the whole foreground process group, but
    // `/usr/bin/log stream` doesn't always exit cleanly on it — leaving
    // an orphan still attached to the tty, writing log lines between
    // future shell prompts. Install handlers on a background queue (the
    // main thread is about to block in waitUntilExit, so a .main-queued
    // source would never fire) that explicitly terminate the child;
    // waitUntilExit then returns and we exit with its status.
    //
    // The event-handler closure is hoisted into its own explicitly-
    // typed `@Sendable () -> Void` binding so it does NOT inherit
    // `@MainActor` from the enclosing `runLogs` function. Without that,
    // Swift 6's runtime isolation check traps with SIGTRAP when the
    // handler fires on `.global()` (the assert is "I should be on main
    // but I'm on default-qos"). `proc` is Sendable on macOS 15+, so
    // capturing it in a non-isolated @Sendable closure is legitimate.
    let onSignal: @Sendable () -> Void = {
        if proc.isRunning { proc.terminate() }
    }
    let signalSources: [DispatchSourceSignal] = [SIGINT, SIGTERM].map { sig in
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        src.setEventHandler(handler: onSignal)
        src.resume()
        return src
    }

    print("Streaming houdini logs. Press Ctrl-C to exit.")
    fflush(stdout) // ensure the banner precedes log stream's own output
    do {
        try proc.run()
    } catch {
        die("failed to exec /usr/bin/log: \(error)")
    }
    withExtendedLifetime(signalSources) {
        proc.waitUntilExit()
    }
    exit(proc.terminationStatus)
}

// MARK: - help

@MainActor
func usage() {
    print("""
    houdini — hides the menu bar when the frontmost fullscreen app is
    the same one playing in the system Now Playing widget.

    Usage:
      houdini                   Run the daemon (invoked by brew services)
      houdini status            Print frontmost/Now-Playing state and the
                                hide/show decision the daemon would make
      houdini logs [category]   Stream houdini's unified-log entries.
                                Optional category narrows the stream:
                                  controller  HIDE/SHOW decisions
                                  adapter     mediaremote-adapter output
                                  general     startup, shutdown, warnings
      houdini version           Print version
      houdini help              Print this help

    Install and autostart are managed via Homebrew:
      brew services start houdini
      brew services stop houdini
      brew services info houdini
    """)
}
