// Implementations of the CLI verbs: (default) foreground run,
// `status`, `logs`, `version`, `help`. LaunchAgent lifecycle is
// delegated to Homebrew (`brew services`).

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

/// Exits non-zero when the daemon isn't running or Accessibility is
/// missing, so `houdini status && …` is a usable script primitive.
@MainActor
func runStatus() -> Never {
    let daemonRunning = probeDaemonRunning()
    let axGranted = isAccessibilityTrusted()
    print("version:  houdini \(version)")
    print("daemon:   \(daemonRunning ? "running" : "not running")")
    if axGranted {
        print("perms:    Accessibility granted")
    } else {
        print("perms:    Accessibility not granted")
        print("          brew services restart houdini")
    }
    exit(daemonRunning && axGranted ? 0 : 1)
}

// MARK: - version

@MainActor
func runVersion() -> Never {
    print("houdini \(version)")
    exit(0)
}

// MARK: - logs

/// Streams every houdini unified-log entry by shelling out to
/// `/usr/bin/log stream`. Always at `--level debug` and across every
/// category, so a single command surfaces everything we'd want for a
/// repro — controller HIDE/SHOW snapshots, the per-window
/// `isAppFullScreen` diagnostic, mediaremote-adapter subprocess output,
/// and startup/shutdown notices. For history, use `log show` with the
/// same predicate.
@MainActor
func runLogs(args: [String]) -> Never {
    if !args.isEmpty {
        die("logs takes no arguments — `houdini logs` streams every houdini entry at debug level")
    }

    let predicate = "subsystem == \"\(Log.subsystem)\""

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    proc.arguments = [
        "stream",
        "--predicate", predicate,
        "--level", "debug",
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
      houdini status            Print version, whether a daemon is running,
                                and whether Accessibility is granted.
                                Exits non-zero if either is missing.
      houdini logs              Stream every houdini unified-log entry
                                across all categories at debug level —
                                controller decisions, the per-window
                                fullscreen diagnostic, mediaremote-
                                adapter output, startup notices, etc.
      houdini version           Print version
      houdini help              Print this help

    Install and autostart are managed via Homebrew:
      brew services start houdini
      brew services stop houdini
      brew services info houdini
    """)
}
