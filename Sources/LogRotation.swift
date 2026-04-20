// Caps launchd-written log files at a fixed size so they don't grow
// unboundedly. Runs at daemon startup only — launchd opens the files
// in O_APPEND mode, so truncating in place is safe: the kernel resets
// the file to 0 bytes, launchd's next write appends at offset 0. No
// rotated archive is kept; losing history at the truncation boundary
// is the accepted tradeoff for a zero-dependency implementation.

import Foundation

/// Truncation threshold for each launchd-written log file.
private let logSizeCap = 500 * 1024

/// The two Homebrew prefixes that can hold `filename`, in preference
/// order. Shared with the `logs` subcommand so both agree on where
/// the files live.
func homebrewLogCandidates(_ filename: String) -> [String] {
    [
        "/opt/homebrew/var/log/\(filename)",
        "/usr/local/var/log/\(filename)",
    ]
}

/// Truncates `houdini.log` and `houdini.err` if either exceeds
/// `logSizeCap`. Silent no-op when neither file exists (foreground
/// run — launchd isn't managing the streams). On any I/O error,
/// warns and continues: a failed rotation must not stop startup.
func rotateLogsIfNeeded() {
    for filename in ["houdini.log", "houdini.err"] {
        guard let path = homebrewLogCandidates(filename)
            .first(where: FileManager.default.fileExists)
        else { continue }
        truncateIfOverCap(path: path)
    }
}

private func truncateIfOverCap(path: String) {
    let size: Int
    do {
        size = try URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.fileSizeKey])
            .fileSize ?? 0
    } catch {
        warn("could not stat log file \(path) for rotation: \(error)")
        return
    }
    guard size > logSizeCap else { return }

    guard let handle = FileHandle(forWritingAtPath: path) else {
        warn("could not open \(path) for truncation")
        return
    }
    defer { try? handle.close() }
    do {
        try handle.truncate(atOffset: 0)
    } catch {
        warn("could not truncate \(path) (was \(size) bytes): \(error)")
    }
}
