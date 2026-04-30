// Unified-logging plumbing. Three categories so readers can filter
// (Console.app, `log show` predicate, etc.). `warn`/`die` route
// through `Log.general` and echo to stderr on TTY so a foreground
// run shows failures without a second terminal on `houdini logs`.

import Darwin
import Foundation
import os

enum Log {
    static let subsystem = "com.github.mgxv.houdini"

    /// hide/show snapshots (info) and parsed `dock_rx`
    /// events (debug).
    static let controller = Logger(subsystem: subsystem, category: "controller")

    /// mediaremote-adapter subprocess output. `.debug` so Console.app
    /// at default level doesn't see every adapter heartbeat.
    static let adapter = Logger(subsystem: subsystem, category: "adapter")

    /// Startup/shutdown and everything routed through `warn`/`die`.
    static let general = Logger(subsystem: subsystem, category: "general")
}

/// Logs at `.error`; also echoes to stderr on TTY.
@MainActor
func warn(_ message: String) {
    Log.general.error("\(message, privacy: .public)")
    if isatty(fileno(stderr)) != 0 {
        FileHandle.standardError.write(Data("houdini: \(message)\n".utf8))
    }
}

/// `warn` plus exits with status 1.
@MainActor
func die(_ message: String) -> Never {
    warn(message)
    exit(1)
}
