// Unified-logging plumbing for houdini. Two concerns:
//
// 1. Shared `os.Logger` instances under `Log`, grouped by category so
//    `houdini logs [category]` can subset the stream.
// 2. `warn` / `die` helpers that route through `Log.general` and also
//    echo to stderr on TTY (foreground debug runs), so a user doesn't
//    need a second terminal open on `houdini logs` to see failures.

import Darwin
import Foundation
import os

enum Log {
    static let subsystem = "com.github.mgxv.houdini"

    /// HIDE/SHOW decisions emitted by the evaluation loop.
    static let controller = Logger(subsystem: subsystem, category: "controller")

    /// mediaremote-adapter subprocess output. Logged at `.debug` so it
    /// stays out of the default `houdini logs` stream — surface it with
    /// `houdini logs adapter` when diagnosing the subprocess.
    static let adapter = Logger(subsystem: subsystem, category: "adapter")

    /// Startup/shutdown notices and everything routed through `warn`/`die`.
    static let general = Logger(subsystem: subsystem, category: "general")
}

/// Logs at `.error` level; additionally echoes `houdini: <message>`
/// to stderr when stderr is attached to a TTY.
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
