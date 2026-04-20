// Stderr helpers. houdini has no throwing API surface of its own, so
// errors bubble up as warn(...) + die(...) calls.

import Foundation

/// Writes `houdini: <message>` to stderr without exiting.
func warn(_ message: String) {
    FileHandle.standardError.write(Data("houdini: \(message)\n".utf8))
}

/// Writes to stderr and exits with status 1.
func die(_ message: String) -> Never {
    warn(message)
    exit(1)
}
