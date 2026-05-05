// Implementations of the CLI verbs: (default) foreground run,
// `status`, `logs`, `version`, `help`. LaunchAgent lifecycle is
// delegated to Homebrew (`brew services`).

import AppKit
import Foundation

// MARK: - Foreground

/// Runs the daemon loop. Intended to be invoked by launchd via
/// `brew services`; runs fine in a terminal for local debugging too.
@MainActor
func runForeground() {
    // Initializes NSApp + keeps the daemon out of the Dock. NSApp
    // is required: Carbon hotkey events are dispatched via NSApp.run.
    NSApplication.shared.setActivationPolicy(.accessory)

    // Opt out of App Nap so idle throttling can't defer event delivery.
    let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiatedAllowingIdleSystemSleep],
        reason: "houdini daemon",
    )

    acquireInstanceLock()

    let menuBar = MenuBarToggler()
    menuBar.resetToVisible()

    let mode = ModeState.read()
    Log.general
        .notice(
            "houdini \(version, privacy: .public) running (mode=\(mode.rawValue, privacy: .public))",
        )
    print("houdini \(version) running (mode=\(mode.rawValue)). Press Ctrl-C to quit.")

    switch mode {
    case .smart:
        runSmart(menuBar: menuBar, activity: activity)
    case .fixed:
        runFixed(menuBar: menuBar, activity: activity)
    }
}

@MainActor
private func runSmart(menuBar: MenuBarToggler, activity: NSObjectProtocol) {
    let artifacts = locateArtifacts()
    let controller = SmartController(menuBar: menuBar)

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

    withExtendedLifetime((signalSources, activity)) {
        NSApp.run()
    }
}

@MainActor
private func runFixed(menuBar: MenuBarToggler, activity: NSObjectProtocol) {
    let controller = FixedController(menuBar: menuBar)
    controller.start()

    let signalSources = installSignalHandlers {
        menuBar.resetToVisible()
        controller.stop()
    }

    withExtendedLifetime((signalSources, activity)) {
        NSApp.run()
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

@MainActor
func runStatus() -> Never {
    let daemonRunning = probeDaemonRunning()
    let mode = ModeState.read()
    let adapterAlive = subprocessAlive(matching: AdapterClient.statusPgrepPattern)
    let dockLogAlive = subprocessAlive(matching: DockSpaceWatcher.statusPgrepPattern)
    let hotkeyState = daemonRunning ? (HotkeyState.read() ?? "unknown") : "n/a"
    let axState = daemonRunning ? (AccessibilityState.read() ?? "unknown") : "n/a"
    print("version:        \(version)")
    print("mode:           \(mode.rawValue)")
    print("daemon:         \(daemonRunning ? "running" : "not running")")
    switch mode {
    case .smart:
        print("adapter:        \(adapterAlive ? "running" : "not running")")
        print("dock log:       \(dockLogAlive ? "running" : "not running")")
    case .fixed:
        print("adapter:        n/a (fixed mode)")
        print("dock log:       n/a (fixed mode)")
    }
    print("hotkey:         \(hotkeyState)")
    print("accessibility:  \(axState)")
    let healthy: Bool = switch mode {
    case .smart: daemonRunning && adapterAlive && dockLogAlive
    case .fixed: daemonRunning && hotkeyState == "registered"
    }
    exit(healthy ? 0 : 1)
}

private func subprocessAlive(matching pattern: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", "-q", pattern]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

// MARK: - mode

@MainActor
func runMode(args: [String]) -> Never {
    guard args.count == 1, let mode = Mode(rawValue: args[0]) else {
        die("usage: houdini mode <smart|fixed>")
    }
    ModeState.write(mode)
    print("mode set to \(mode.rawValue)")
    if probeDaemonRunning() {
        print("daemon is running; restart to apply: brew services restart houdini")
    }
    exit(0)
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
    the same one playing in the system Now Playing widget (smart mode),
    or under manual hotkey control (fixed mode).

    Usage:
      houdini                   Run the daemon (invoked by brew services)
      houdini mode smart|fixed  Set the mode. Default is `smart`.
                                Restart the daemon to apply:
                                `brew services restart houdini`.
                                Read the current mode with `houdini status`.
      houdini status            Print version, mode, daemon state,
                                subprocess health (smart mode only),
                                hotkey registration, and Accessibility
                                permission. Exits non-zero if required
                                components for the active mode aren't
                                running.
      houdini logs              Stream every houdini unified-log entry
                                across all categories at debug level —
                                controller decisions, dock-visibility
                                events, AX focus events,
                                mediaremote-adapter output, etc.
      houdini version           Print version
      houdini help              Print this help

    Install and autostart are managed via Homebrew:
      brew services start houdini
      brew services stop houdini
      brew services info houdini
    """)
}
