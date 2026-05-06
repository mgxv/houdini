// Subscribes to Dock's `dock-visibility` log channel as our source
// of fullscreen-Space state. Dock emits at decision time, which is
// the most reliable signal we can read without entitlements.
//
// `log stream` is a public, documented command — no entitlements
// required.

import Foundation

// MARK: - Public types

/// Snapshot of the active Space's fullscreen state as Dock most
/// recently reported it. `fsOwnerPID` is the fullscreen app's process
/// identifier when `isFullScreen == true`, and nil otherwise (Dock's
/// exit log doesn't carry a PID, just confirmation that we're back on
/// a non-FS Space).
///
/// `dockWindowTitle` is the FS-tile's `name=` field, captured at
/// FS-entry; nil on FS-exit / stay pulses.
struct DockFullScreenState: Equatable {
    let isFullScreen: Bool
    let fsOwnerPID: FSOwnerPID?
    let dockWindowTitle: String?

    init(
        isFullScreen: Bool,
        fsOwnerPID: FSOwnerPID?,
        dockWindowTitle: String? = nil,
    ) {
        self.isFullScreen = isFullScreen
        self.fsOwnerPID = fsOwnerPID
        self.dockWindowTitle = dockWindowTitle
    }

    /// Default until any Dock event arrives. If the user is
    /// *already* in a fullscreen Space when the daemon launches, we
    /// report `isFullScreen=false` until the next Space transition
    /// corrects us — menu bar stays visible until then.
    static let initial = DockFullScreenState(
        isFullScreen: false,
        fsOwnerPID: nil,
        dockWindowTitle: nil,
    )
}

/// Events from the dock-visibility log channel. `staySpaceChange`
/// is the `Skipping no-op state update` pulse Dock emits on silent
/// FS↔FS Space switches — no payload, just "active Space changed."
enum DockSpaceEvent: Equatable {
    case fullScreenState(DockFullScreenState)
    case staySpaceChange
}

// MARK: - DockSpaceWatcher

@MainActor
final class DockSpaceWatcher {
    // MARK: Configuration

    /// Filters `dock-visibility` to `Space Forces Hidden:` (engage/exit
    /// transitions; carries pid + fullscreen flag) and `Skipping no-op
    /// state update` (Dock's wake-up on silent FS↔FS Space switches).
    private static let logPredicate = """
    subsystem == "com.apple.dock" \
    AND category == "dock-visibility" \
    AND (eventMessage CONTAINS "Space Forces Hidden:" \
    OR eventMessage CONTAINS "Skipping no-op state update")
    """

    static let statusPgrepPattern = #"log stream.*dock-visibility"#

    // MARK: State

    private let onUpdate: @MainActor (DockSpaceEvent) -> Void
    private var subprocess: Process?
    private var lineBuffer = LineBuffer()
    /// Set by `stop()` so the termination handler can distinguish
    /// graceful shutdown from unexpected exit (fatal).
    private var isStopping = false

    init(onUpdate: @escaping @MainActor (DockSpaceEvent) -> Void) {
        self.onUpdate = onUpdate
    }

    // MARK: Lifecycle

    /// Idempotent. Throws on spawn failure — the Dock channel is
    /// load-bearing, so the caller is expected to `die`.
    func start() throws {
        guard subprocess == nil else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream",
            "--level", "debug",
            "--style", "compact",
            "--predicate", Self.logPredicate,
        ]

        // `log stream` writes a "Filtering the log data using …"
        // header to stdout that doesn't match our parser, so it's
        // silently dropped. `standardError` is silenced as
        // belt-and-suspenders.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.ingest(data)
                }
            }
        }

        // Unexpected exit is fatal — degraded operation (always show)
        // is worse than a launchd-orchestrated restart. The
        // `isStopping` check distinguishes graceful shutdown.
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                guard let self, !self.isStopping else { return }
                die("""
                DockSpaceWatcher: log stream subprocess exited \
                unexpectedly (status=\(status))
                """)
            }
        }

        try process.run()
        subprocess = process
    }

    /// Sets the `isStopping` flag synchronously before `terminate()`
    /// so the termination handler observes it and skips the fatal
    /// unexpected-exit path.
    func stop() {
        isStopping = true
        if let subprocess, subprocess.isRunning {
            subprocess.terminate()
        }
    }

    // MARK: Parsing

    private func ingest(_ chunk: Data) {
        lineBuffer.ingest(chunk) { line in
            guard let text = String(data: line, encoding: .utf8) else { return }
            guard let event = Self.parse(text) else { return }
            switch event {
            case let .fullScreenState(state):
                let pidField = state.fsOwnerPID.map { "\($0.rawValue)" } ?? "null"
                let nameField = state.dockWindowTitle.map { "\"\($0)\"" } ?? "null"
                Log.controller.debug(
                    "→ dock_rx fs=\(state.isFullScreen, privacy: .public) pid=\(pidField, privacy: .public) name=\(nameField, privacy: .public)",
                )
            case .staySpaceChange:
                Log.controller.debug("→ dock_rx stay_space_change")
            }
            onUpdate(event)
        }
    }

    /// Returns nil for lines that don't match either expected shape
    /// (`log stream` header, redacted output) — caller drops them.
    ///
    /// `Skipping no-op state update` is used only as a wake-up
    /// trigger; its `state` field tracks Dock's transition phases
    /// unreliably and isn't a source of FS-ness truth.
    ///
    /// `Space Forces Hidden:` exit messages omit the pid and surface
    /// as `pid=nil`, which `menuBarDecision`'s non-nil pid guard
    /// then rejects. `dockWindowTitle` is extracted only on FS-entry.
    nonisolated static func parse(_ line: String) -> DockSpaceEvent? {
        if line.contains("Skipping no-op state update") {
            return .staySpaceChange
        }

        let isFullScreen: Bool
        if line.contains("fullscreen=true") {
            isFullScreen = true
        } else if line.contains("fullscreen=false") {
            isFullScreen = false
        } else {
            return nil
        }

        // `\b` prevents matching the `pid=` suffix of `spid=…` if
        // Dock ever switches the space-id separator from `:` to `=`.
        // Defensive — today's traces use `(spid: N)`. `raw > 0` rejects
        // `pid=0`: responsibility-pid returns 0 for untracked pids, so
        // a zero `fsOwnerPID` would false-match via gate 5.
        var fsOwnerPID: FSOwnerPID?
        var pidEnd: String.Index?
        if let match = line.range(of: #"\bpid=\d+"#, options: .regularExpression) {
            let digits = line[match].dropFirst("pid=".count)
            if let raw = pid_t(digits), raw > 0 { fsOwnerPID = FSOwnerPID(raw) }
            pidEnd = match.upperBound
        }

        let dockWindowTitle = isFullScreen
            ? extractTileName(in: line, after: pidEnd)
            : nil

        return .fullScreenState(DockFullScreenState(
            isFullScreen: isFullScreen,
            fsOwnerPID: fsOwnerPID,
            dockWindowTitle: dockWindowTitle,
        ))
    }

    /// Extracts the tile's `name=…` value, terminated by
    /// ` space=CGSSpace`. The leading space in ` name=` disambiguates
    /// it from `appName=`, which always precedes the title.
    private nonisolated static func extractTileName(
        in line: String,
        after pidEnd: String.Index?,
    ) -> String? {
        guard let pidEnd, pidEnd < line.endIndex else { return nil }
        guard let nameStart = line.range(
            of: " name=",
            range: pidEnd ..< line.endIndex,
        ) else { return nil }
        let valueStart = nameStart.upperBound
        guard valueStart <= line.endIndex,
              let terminator = line.range(
                  of: " space=CGSSpace",
                  range: valueStart ..< line.endIndex,
              )
        else { return nil }
        let raw = String(line[valueStart ..< terminator.lowerBound])
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
