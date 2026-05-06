// Daemon operating mode. `smart` runs the signal-fusion pipeline;
// `fixed` is hotkey-only. Read once at daemon startup — changes
// require `brew services restart houdini`.

import Foundation

enum Mode: String {
    case smart
    case fixed
}

/// On-disk persistence mirroring `HotkeyState`.
/// Default is `.smart` when the file is missing or malformed.
enum ModeState {
    private static func url() -> URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false,
        ) else { return nil }
        return appSupport
            .appendingPathComponent(Log.subsystem, isDirectory: true)
            .appendingPathComponent("mode")
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
