// Implementations of the CLI verbs: (default) foreground run,
// `install`, `uninstall`, `status`, `help`.

import Cocoa
import Foundation

// MARK: - Foreground

/// Runs the daemon loop in the foreground. When `dryRun` is true, all
/// evaluation happens but no menu-bar preference is written.
func runForeground(dryRun: Bool) {
    ensureAccessibilityPermission()
    let (scriptPath, frameworkPath) = locateArtifacts()

    let menuBar: MenuBarToggler? = dryRun ? nil : MenuBarToggler()
    menuBar?.resetToVisible()

    let controller = Controller(menuBar: menuBar)
    let adapter = AdapterClient(
        scriptPath: scriptPath,
        frameworkPath: frameworkPath,
    ) { playing, pid, bundle in
        controller.updateMedia(playing: playing, pid: pid, bundle: bundle)
    }

    controller.start()
    do {
        try adapter.start()
    } catch {
        die("failed to start mediaremote-adapter subprocess: \(error)")
    }

    let signalSources = installSignalHandlers {
        menuBar?.resetToVisible()
        adapter.stop()
    }

    let mode = dryRun ? " (dry-run, no menu-bar writes)" : ""
    print("houdini running\(mode). Press Ctrl-C to quit.")
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
            print("\nhoudini stopping…")
            shutdown()
            exit(0)
        }
        src.resume()
        return src
    }
}

// MARK: - install

func runInstall() -> Never {
    guard let exec = Bundle.main.executableURL else {
        die("could not determine binary path")
    }
    let binary = exec.path

    createAgentDirectories()
    bootstrapAgent(binary: binary)
    createCLISymlink(to: binary)
    printInstallReceipt(binary: binary)
    exit(0)
}

private func createAgentDirectories() {
    let fm = FileManager.default
    do {
        try fm.createDirectory(at: plistURL().deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: logURL().deletingLastPathComponent(),
                               withIntermediateDirectories: true)
    } catch {
        die("failed to create LaunchAgents/Logs directory: \(error)")
    }
}

private func bootstrapAgent(binary: String) {
    // Idempotent: bootout an existing copy before re-bootstrapping.
    _ = launchctl(["bootout", serviceTarget()])

    do {
        try makeAgentPlistData(binary: binary).write(to: plistURL())
    } catch {
        die("failed to write \(plistURL().path): \(error)")
    }

    let result = launchctl(["bootstrap", domainTarget(), plistURL().path])
    if result.status != 0 {
        die("launchctl bootstrap failed (status=\(result.status)): " +
            result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private func createCLISymlink(to binary: String) {
    let link = symlinkURL()
    let fm = FileManager.default
    do {
        try fm.createDirectory(at: link.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link,
                                  withDestinationURL: URL(fileURLWithPath: binary))
    } catch {
        warn("failed to create CLI symlink at \(link.path): \(error)")
    }
}

private func printInstallReceipt(binary: String) {
    let link = symlinkURL()
    let pathNote = symlinkDirIsOnPath() ? "" : """


    NOTE: \(link.deletingLastPathComponent().path) is not on your PATH.
    Add this to ~/.zshrc (or equivalent) and open a new shell:
      export PATH="$HOME/.local/bin:$PATH"
    """

    print("""
    houdini installed.
      binary:   \(binary)
      symlink:  \(link.path)
      plist:    \(plistURL().path)
      logs:     \(logURL().path)
                \(errURL().path)
      service:  \(serviceTarget())\(pathNote)

    Grant Accessibility permission to the binary above in
    System Settings → Privacy & Security → Accessibility.
    The agent will keep restarting until permission is granted.

    Tail logs:  tail -f \(logURL().path)
    """)
}

// MARK: - uninstall

func runUninstall() -> Never {
    let bootResult = launchctl(["bootout", serviceTarget()])

    removePlist()
    try? FileManager.default.removeItem(at: symlinkURL())

    // Restore in case the daemon died with the menu bar in auto-hide state.
    MenuBarToggler().resetToVisible()

    print("houdini uninstalled. Menu bar restored to always-visible.")
    let trimmed = bootResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if bootResult.status != 0, !trimmed.isEmpty {
        // bootout returns non-zero when nothing was loaded — informational, not fatal.
        warn("launchctl bootout: \(trimmed)")
    }
    exit(0)
}

private func removePlist() {
    let plist = plistURL()
    let fm = FileManager.default
    guard fm.fileExists(atPath: plist.path) else { return }
    do {
        try fm.removeItem(at: plist)
    } catch {
        warn("failed to remove \(plist.path): \(error)")
    }
}

// MARK: - status

func runStatus() -> Never {
    let plist = plistURL()
    let plistExists = FileManager.default.fileExists(atPath: plist.path)
    let loaded = launchctl(["print", serviceTarget()]).status == 0

    let link = symlinkURL()
    let linkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
    let linkStr: String = linkTarget.map { "\(link.path) → \($0)" }
        ?? "\(link.path) [missing]"
    let pathStr = symlinkDirIsOnPath() ? "on PATH" : "NOT on PATH"

    print("""
    LaunchAgent
      plist:    \(plist.path) [\(plistExists ? "exists" : "missing")]
      service:  \(serviceTarget()) [\(loaded ? "loaded" : "not loaded")]

    CLI symlink (\(pathStr))
      \(linkStr)

    Logs
      stdout:   \(logURL().path)
      stderr:   \(errURL().path)
      tail:     tail -f \(logURL().path)

    Menu bar
      AppleMenuBarVisibleInFullscreen = \(describeMenuBarPref())
    """)
    exit(0)
}

/// Human-readable current value of the AppleMenuBarVisibleInFullscreen
/// preference for the status output.
private func describeMenuBarPref() -> String {
    let value = CFPreferencesCopyValue(
        "AppleMenuBarVisibleInFullscreen" as CFString,
        kCFPreferencesAnyApplication,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost,
    ) as? Bool
    switch value {
    case true: return "true (always visible)"
    case false: return "false (auto-hide in fullscreen)"
    case nil: return "<unset>"
    }
}

// MARK: - help

func usage() {
    print("""
    houdini — auto-hide the macOS menu bar when the frontmost fullscreen
    app is the same one playing in the system Now Playing widget.

    Usage:
      houdini [--dry-run]    Run in foreground (--dry-run = log only, no toggle)
      houdini install        Install the LaunchAgent + autostart at login
      houdini uninstall      Stop and remove the agent; restore menu bar
      houdini status         Show install state, log paths, and current pref
      houdini help           Print this help
    """)
}
