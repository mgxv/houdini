// Unified-logging plumbing for houdini. Two concerns:
//
// 1. Shared `os.Logger` instances under `Log`, grouped into three
//    categories so a reader (Console.app, raw `log show` predicate,
//    etc.) can filter by category. The `houdini logs` CLI streams all
//    three at debug level — see runLogs in Commands.swift.
// 2. `warn` / `die` helpers that route through `Log.general` and also
//    echo to stderr on TTY (foreground debug runs), so a user doesn't
//    need a second terminal open on `houdini logs` to see failures.

import Darwin
import Foundation
import os

enum Log {
    static let subsystem = "com.github.mgxv.houdini"

    /// Two streams: the HIDE/SHOW snapshot emitted by the evaluation
    /// loop on each decision change (info), and the parsed
    /// `dock_visibility` events from `DockSpaceWatcher` (debug).
    /// Together they describe both what we decided and what inputs we
    /// observed.
    static let controller = Logger(subsystem: subsystem, category: "controller")

    /// mediaremote-adapter subprocess output, line by line. Logged at
    /// `.debug` so a Console.app session at default level doesn't see
    /// every adapter heartbeat; `houdini logs` streams it anyway.
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
