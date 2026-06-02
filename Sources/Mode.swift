// Daemon operating mode. `smart` runs the signal-fusion pipeline;
// `fixed` is hotkey-only. Read at startup and re-read on SIGHUP.

import Foundation

enum Mode: String {
    case smart
    case fixed
}

/// On-disk persistence mirroring `HotkeyState`.
/// Default is `.smart` when the file is missing or malformed.
enum ModeState {
    private static func url() -> URL? {
        subsystemSupportURL("mode")
    }

    static func read() -> Mode {
        guard let url = url(),
              let raw = try? String(contentsOf: url, encoding: .utf8)
              .trimmingCharacters(in: .whitespacesAndNewlines),
              let mode = Mode(rawValue: raw)
        else { return .smart }
        return mode
    }

    static func write(_ mode: Mode) {
        guard let url = url() else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try? mode.rawValue.write(to: url, atomically: true, encoding: .utf8)
    }
}
