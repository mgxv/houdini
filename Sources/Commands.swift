// Implementations of the CLI verbs: (default) foreground run,
// `status`, `mode`, `deny`, `logs`, `version`, `help`. LaunchAgent
// lifecycle is delegated to Homebrew (`brew services`).

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

    let current = CurrentController(mode: mode, menuBar: menuBar)
    current.start()

    let signalSources = installSignalHandlers {
        current.shutdown()
    }
    let reloadSource = installReloadHandler {
        current.reload()
    }

    withExtendedLifetime((signalSources, reloadSource, activity)) {
        NSApp.run()
    }
}

// MARK: - CurrentController (mode swap)

/// Mode swaps build fresh ops because Process / DispatchSource /
/// Carbon refs are single-shot. Override-only changes skip the
/// rebuild and push into the live ops.
@MainActor
final class CurrentController {
    private let menuBar: MenuBarToggling
    private let opsFactory: @MainActor (Mode, MenuBarToggling) -> ControllerOps
    private let modeReader: () -> Mode
    private let overridesReader: () -> AppOverrides
    private(set) var mode: Mode
    private var cachedOverrides: AppOverrides
    private var ops: ControllerOps

    init(
        mode: Mode,
        menuBar: MenuBarToggling,
        opsFactory: @escaping @MainActor (Mode, MenuBarToggling)
            -> ControllerOps = defaultOpsFactory,
        modeReader: @escaping () -> Mode = ModeState.read,
        overridesReader: @escaping () -> AppOverrides = AppOverridesState.read,
    ) {
        self.mode = mode
        self.menuBar = menuBar
        self.opsFactory = opsFactory
        self.modeReader = modeReader
        self.overridesReader = overridesReader
        cachedOverrides = .empty
        ops = opsFactory(mode, menuBar)
    }

    func start() {
        ops.start()
        cachedOverrides = overridesReader()
        ops.updateOverrides(cachedOverrides)
    }

    func reload() {
        let newMode = modeReader()
        let newOverrides = overridesReader()
        let oldMode = mode

        if newMode != oldMode {
            Log.general.notice(
                "mode change: \(oldMode.rawValue, privacy: .public) → \(newMode.rawValue, privacy: .public)",
            )
            ops.stop()
            menuBar.resetToVisible()
            mode = newMode
            ops = opsFactory(newMode, menuBar)
            ops.start()
            ops.updateOverrides(newOverrides)
            cachedOverrides = newOverrides
        } else if newOverrides != cachedOverrides {
            let oldCount = cachedOverrides.deny.count
            let newCount = newOverrides.deny.count
            Log.general.notice(
                "deny list changed: \(oldCount, privacy: .public) → \(newCount, privacy: .public) entries",
            )
            ops.updateOverrides(newOverrides)
            cachedOverrides = newOverrides
        }
    }

    func shutdown() {
        ops.stop()
        menuBar.resetToVisible()
    }
}

@MainActor
func defaultOpsFactory(_ mode: Mode, _ menuBar: MenuBarToggling) -> ControllerOps {
    switch mode {
    case .smart: makeSmartOps(menuBar: menuBar)
    case .fixed: makeFixedOps(menuBar: menuBar)
    }
}

struct ControllerOps {
    let start: @MainActor () -> Void
    let stop: @MainActor () -> Void
    let updateOverrides: @MainActor (AppOverrides) -> Void
}

@MainActor
private func makeSmartOps(menuBar: MenuBarToggling) -> ControllerOps {
    let artifacts = locateArtifacts()
    let controller = SmartController(
        menuBar: menuBar,
        nowPlayingReprime: { fetchNowPlayingOnce(artifacts: artifacts) },
    )
    let adapter = AdapterClient(
        artifacts: artifacts,
        onUpdate: { @MainActor snapshot in
            controller.updateMedia(snapshot)
        },
    )
    return ControllerOps(
        start: {
            // Prime with a one-shot Now Playing fetch so the first
            // logged evaluation reflects current state, not a blank
            // placeholder from before the streaming adapter delivers
            // its first event. Skip on failure — not worth aborting
            // startup over.
            if let snapshot = fetchNowPlayingOnce(artifacts: artifacts) {
                controller.updateMedia(snapshot)
            }
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
        },
        stop: {
            adapter.stop()
            controller.stop()
        },
        updateOverrides: { controller.updateOverrides($0) },
    )
}

@MainActor
private func makeFixedOps(menuBar: MenuBarToggling) -> ControllerOps {
    let controller = FixedController(menuBar: menuBar)
    return ControllerOps(
        start: { controller.start() },
        stop: { controller.stop() },
        updateOverrides: { _ in },
    )
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

@MainActor
func installReloadHandler(_ reload: @escaping @MainActor () -> Void) -> DispatchSourceSignal {
    signal(SIGHUP, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
    src.setEventHandler {
        MainActor.assumeIsolated {
            // Logged before the no-op guard so a same-mode SIGHUP
            // still leaves a breadcrumb.
            Log.general.debug("SIGHUP received")
            reload()
        }
    }
    src.resume()
    return src
}

// MARK: - status

@MainActor
func runStatus() -> Never {
    let daemonRunning = probeDaemonRunning()
    let mode = ModeState.read()
    let adapterAlive = subprocessAlive(matching: AdapterClient.statusPgrepPattern)
    let dockLogAlive = subprocessAlive(matching: DockSpaceWatcher.statusPgrepPattern)
    let hotkeyState = daemonRunning ? (HotkeyState.read() ?? "unknown") : "n/a"
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
    let denyCount = AppOverridesState.read().deny.count
    if denyCount > 0 {
        print("deny list:      \(denyCount) entr\(denyCount == 1 ? "y" : "ies")")
    }
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
    if args.isEmpty {
        print(ModeState.read().rawValue)
        exit(0)
    }
    guard args.count == 1, let mode = Mode(rawValue: args[0]) else {
        die("usage: houdini mode [smart|fixed]")
    }
    ModeState.write(mode)
    print("mode set to \(mode.rawValue)")
    if probeDaemonRunning() {
        if signalDaemonReload() {
            print("daemon reloaded")
        } else {
            print(
                "daemon is running but couldn't be signaled; restart to apply: brew services restart houdini",
            )
        }
    }
    exit(0)
}

// MARK: - deny

@MainActor
func runDeny(args: [String]) -> Never {
    switch args.count {
    case 0:
        listDeny()
    case 2:
        let action = args[0]
        let bundle = args[1].trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case "add": addDeny(bundle: bundle)
        case "remove": removeDeny(bundle: bundle)
        default: die("usage: houdini deny [add|remove] <bundle>")
        }
    default:
        die("usage: houdini deny [add|remove] <bundle>")
    }
}

@MainActor
private func listDeny() -> Never {
    let overrides = AppOverridesState.read()
    if overrides.deny.isEmpty {
        print("(no entries)")
    } else {
        for bundle in overrides.deny.sorted() {
            print(bundle)
        }
    }
    exit(0)
}

@MainActor
private func addDeny(bundle: String) -> Never {
    guard isPlausibleBundle(bundle) else {
        die("\"\(bundle)\" doesn't look like a bundle ID (e.g. com.spotify.client)")
    }
    var overrides = AppOverridesState.read()
    if overrides.deny.contains(bundle) {
        print("\(bundle) already in deny list")
        exit(0)
    }
    overrides.deny.insert(bundle)
    persistAndReload(overrides, action: "added \(bundle) to deny list")
}

@MainActor
private func removeDeny(bundle: String) -> Never {
    var overrides = AppOverridesState.read()
    guard overrides.deny.contains(bundle) else {
        print("\(bundle) not in deny list")
        exit(0)
    }
    overrides.deny.remove(bundle)
    persistAndReload(overrides, action: "removed \(bundle) from deny list")
}

@MainActor
private func persistAndReload(_ overrides: AppOverrides, action: String) -> Never {
    do {
        try AppOverridesState.write(overrides)
    } catch {
        die("could not write deny list: \(error)")
    }
    print(action)
    if probeDaemonRunning() {
        if signalDaemonReload() {
            print("daemon reloaded")
        } else {
            print(
                "daemon is running but couldn't be signaled; restart to apply: brew services restart houdini",
            )
        }
    } else {
        print("(daemon not running — will take effect at next start)")
    }
    exit(0)
}

private func isPlausibleBundle(_ s: String) -> Bool {
    s.wholeMatch(of: #/[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/#) != nil
}

/// Retries to close the race where the daemon holds the flock but
/// hasn't yet written its PID.
private func signalDaemonReload() -> Bool {
    for _ in 0 ..< 3 {
        if let pid = readDaemonPID(), kill(pid, SIGHUP) == 0 {
            return true
        }
        usleep(50000) // 50ms
    }
    return false
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
      houdini mode              Print the current mode.
      houdini mode smart|fixed  Set the mode. Default is `smart`. The
                                running daemon (if any) is signaled to
                                reload.
      houdini deny              List bundle IDs that won't trigger
                                auto-hide even when all gates would
                                otherwise pass.
      houdini deny add <bundle>     Add a bundle ID to the deny list.
      houdini deny remove <bundle>  Remove a bundle ID from the deny list.
      houdini status            Print version, mode, daemon state,
                                subprocess health (smart mode only),
                                hotkey registration, and deny-list size.
                                Exits non-zero if required components for
                                the active mode aren't running.
      houdini logs              Stream every houdini unified-log entry
                                across all categories at debug level —
                                controller decisions, dock-visibility
                                events, mediaremote-adapter output, etc.
      houdini version           Print version
      houdini help              Print this help

    Install and autostart are managed via Homebrew:
      brew services start houdini
      brew services stop houdini
      brew services info houdini
    """)
}
