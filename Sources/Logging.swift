// Warning/error helpers. Messages are routed to the unified log so the
// daemon surfaces them in `houdini logs` (and Console.app) even when
// running under launchd. When stderr is a TTY — i.e. a foreground
// debug run — they're also echoed there so the user sees them
// immediately without needing a second terminal for `houdini logs`.

import Darwin
import Foundation

/// Logs at `.error` level; additionally echoes `houdini: <message>`
/// to stderr when stderr is attached to a TTY.
func warn(_ message: String) {
    Log.general.error("\(message, privacy: .public)")
    if isatty(fileno(stderr)) != 0 {
        FileHandle.standardError.write(Data("houdini: \(message)\n".utf8))
    }
}

/// `warn` plus exits with status 1.
func die(_ message: String) -> Never {
    warn(message)
    exit(1)
}
