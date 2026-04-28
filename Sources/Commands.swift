// Implementations of the CLI verbs: (default) foreground run,
// `status`, `logs`, `version`, `help`. LaunchAgent lifecycle is
// delegated to Homebrew (`brew services`).

import Foundation

// MARK: - Foreground

/// Runs the daemon loop. Intended to be invoked by launchd via
/// `brew services`; runs fine in a terminal for local debugging too.
@MainActor
func runForeground() {
    let artifacts = locateArtifacts()
    acquireInstanceLock()

    let menuBar = MenuBarToggler()
    menuBar.resetToVisible()

    let controller = Controller(menuBar: menuBar)

    // Prime with a one-shot Now Playing fetch so the first logged
    // evaluation reflects current state, not a blank placeholder
    // from before the streaming adapter delivers its first event.
    // Skip on failure — not worth aborting startup over.
    if let snapshot = fetchNowPlayingOnce(artifacts: artifacts) {
        controller.updateMedia(snapshot)
    }

    let adapter = AdapterClient(
        artifacts: artifacts,
        onUpdate: { @MainActor snapshot in
            controller.updateMedia(snapshot)
        },
    )

    do {
        try controller.start()
    } catch {
        die("failed to start dock-space watcher: \(error)")
    }
    do {
        try adapter.start()
    } catch {
        die("failed to start mediaremote-adapter subprocess: \(error)")
    }

    let signalSources = installSignalHandlers {
        menuBar.resetToVisible()
        adapter.stop()
        controller.stop()
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
            // Source is queued on .main, but DispatchSource's handler
            // isn't statically main-actor-isolated — assume isolation
            // so we can call @MainActor APIs before exit().
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

/// Exits non-zero when the daemon isn't running, so
/// `houdini status && …` is a usable script primitive.
@MainActor
func runStatus() -> Never {
    let daemonRunning = probeDaemonRunning()
    print("version:  houdini \(version)")
    print("daemon:   \(daemonRunning ? "running" : "not running")")
    exit(daemonRunning ? 0 : 1)
}

// MARK: - version

@MainActor
func runVersion() -> Never {
    print("houdini \(version)")
    exit(0)
}

// MARK: - logs

/// Streams every houdini unified-log entry across every category at
/// `--level debug` — one command surfaces everything for a repro.
/// For history, use `log show` with the same predicate.
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

    // `/usr/bin/log stream` doesn't always exit cleanly on SIGINT,
    // leaving an orphan attached to the tty. Handlers on a
    // background queue (main is about to block in waitUntilExit)
    // explicitly terminate the child.
    //
    // The closure is hoisted into a `@Sendable () -> Void` so it
    // does NOT inherit `@MainActor` from `runLogs` — Swift 6's
    // runtime isolation check traps with SIGTRAP otherwise when
    // the handler fires on `.global()`.
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
      houdini status            Print version and whether a daemon is
                                running. Exits non-zero if not running.
      houdini logs              Stream every houdini unified-log entry
                                across all categories at debug level —
                                controller decisions, dock-visibility
                                events, mediaremote-adapter output,
                                startup notices, etc.
      houdini version           Print version
      houdini help              Print this help

    Install and autostart are managed via Homebrew:
      brew services start houdini
      brew services stop houdini
      brew services info houdini
    """)
}
