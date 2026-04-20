// Implementations of the CLI verbs: (default) foreground run, `help`.
// LaunchAgent lifecycle is delegated to Homebrew (`brew services`).

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

// MARK: - help

func usage() {
    print("""
    houdini — hides the menu bar when the frontmost fullscreen app is
    the same one playing in the system Now Playing widget.

    Usage:
      houdini [--dry-run]    Run in foreground
                             (--dry-run observes and logs; no menu-bar writes)
      houdini help           Print this help

    Install and autostart are managed via Homebrew:
      brew services start houdini
      brew services stop houdini
      brew services info houdini
    """)
}
