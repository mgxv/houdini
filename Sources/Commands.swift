// Implementations of the CLI verbs: (default) foreground run, `logs`,
// `version`, `help`. LaunchAgent lifecycle is delegated to Homebrew
// (`brew services`).

import Cocoa
import Foundation

// MARK: - Foreground

/// Runs the daemon loop. Intended to be invoked by launchd via
/// `brew services`; runs fine in a terminal for local debugging too.
func runForeground() {
    ensureAccessibilityPermission()
    let (scriptPath, frameworkPath) = locateArtifacts()

    let menuBar = MenuBarToggler()
    menuBar.resetToVisible()

    let controller = Controller(menuBar: menuBar)
    let adapter = AdapterClient(
        scriptPath: scriptPath,
        frameworkPath: frameworkPath,
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
            print("\nhoudini stopping…")
            shutdown()
            exit(0)
        }
        src.resume()
        return src
    }
}

// MARK: - version

func runVersion() -> Never {
    print("houdini \(houdiniVersion)")
    exit(0)
}

// MARK: - logs

/// Tails a log file written by `brew services`. First positional arg
/// selects the stream ("out" or "err"); running `houdini logs` with no
/// arg prints the available streams instead of picking a default.
func runLogs(args: [String]) -> Never {
    // 1. Which stream? `houdini logs` alone lists the choices.
    guard let stream = args.first else {
        print("""
        houdini logs <stream> [--tail N]

        Streams:
          out    HIDE/SHOW decisions and startup banner (houdini.log)
          err    Errors, including Accessibility failures (houdini.err)

        Options:
          --tail N    Print the last N lines before following (default 10)
        """)
        exit(0)
    }

    let filename: String
    switch stream {
    case "out": filename = "houdini.log"
    case "err": filename = "houdini.err"
    default:
        die("unknown stream '\(stream)' — expected 'out' or 'err'")
    }

    // 2. Parse the remaining flags.
    var lines = 10
    var iter = args.dropFirst().makeIterator()
    while let arg = iter.next() {
        switch arg {
        case "--tail":
            guard let value = iter.next(), let n = Int(value), n > 0 else {
                die("--tail requires a positive integer")
            }
            lines = n
        default:
            die("unknown flag for logs: '\(arg)' — try: houdini logs")
        }
    }

    // 3. Find the log file. Homebrew writes it under var/log in the
    //    prefix; check both Apple Silicon and Intel locations.
    let candidates = [
        "/opt/homebrew/var/log/\(filename)",
        "/usr/local/var/log/\(filename)",
    ]
    guard let path = candidates.first(where: FileManager.default.fileExists) else {
        die("""
        log file not found. Logs are only written when running under
        `brew services`; in foreground mode output goes to the terminal.

        Searched:
          \(candidates.joined(separator: "\n  "))
        """)
    }

    // 4. Hand off to `/usr/bin/tail` and exit with its status.
    let tail = Process()
    tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
    tail.arguments = ["-n", "\(lines)", "-F", path]
    do {
        try tail.run()
    } catch {
        die("failed to exec /usr/bin/tail: \(error)")
    }
    tail.waitUntilExit()
    exit(tail.terminationStatus)
}

// MARK: - help

func usage() {
    print("""
    houdini — hides the menu bar when the frontmost fullscreen app is
    the same one playing in the system Now Playing widget.

    Usage:
      houdini                   Run the daemon (invoked by brew services)
      houdini logs <out|err> [--tail N]
                                Tail out (houdini.log) or err (houdini.err);
                                run `houdini logs` alone to list streams
      houdini version           Print version
      houdini help              Print this help

    Install and autostart are managed via Homebrew:
      brew services start houdini
      brew services stop houdini
      brew services info houdini
    """)
}
