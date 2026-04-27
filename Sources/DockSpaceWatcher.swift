// Subscribes to Dock's `dock-visibility` log channel as an external
// IPC channel for fullscreen-Space state. Cross-process traces show
// that Dock emits a `Space Forces Hidden:` line on every Space
// transition (engage and exit alike) that contains, in plain text:
//
//   - `fullscreen=true|false`  — whether the new active Space is FS
//   - `pid=NNNNN`              — the FS app's PID (engage only)
//
// We use these as the canonical source of fullscreen-state truth
// instead of querying Accessibility, which on macOS 15+ is unreliable
// in two distinct ways: AX notifications are flaky during FS
// animations, and the focused window's `AXFullScreen` attribute is
// set asynchronously by the app — sometimes hundreds of milliseconds
// after Dock declares the animation complete. Reading from Dock's own
// log eliminates that race because Dock emits the line at the moment
// it makes the decision.
//
// We tap the channel by spawning `/usr/bin/log stream` with a
// predicate scoped to the dock-visibility category and filtered to the
// "Space Forces Hidden:" message we care about. Each parsed line
// surfaces as a `DockFullScreenState` event to the controller.
//
// `log stream` is a public, documented command. No private API or
// special entitlements are required.

import Foundation

/// Snapshot of the active Space's fullscreen state as Dock most
/// recently reported it. `pid` is the fullscreen app's process
/// identifier when `isFullScreen == true`, and nil otherwise (Dock's
/// exit log doesn't carry a PID, just confirmation that we're back on
/// a non-FS Space).
struct DockFullScreenState: Equatable {
    let isFullScreen: Bool
    let pid: pid_t?

    /// Default state assumed before any Dock event has arrived — the
    /// daemon starts here at boot. If the user is *already* in a
    /// fullscreen Space when the daemon launches, this snapshot is
    /// wrong (we report `isFullScreen=false` until the next Space
    /// transition). The failure mode is benign: the menu bar stays
    /// visible until the user toggles or switches Spaces, at which
    /// point Dock emits a fresh log line that corrects us.
    static let initial = DockFullScreenState(isFullScreen: false, pid: nil)
}

@MainActor
final class DockSpaceWatcher {
    /// Constrains the log stream to Dock's `dock-visibility` category
    /// and to the one message line that carries the FS state. Together
    /// they reduce subprocess output to one line per Space transition.
    private static let logPredicate = #"subsystem == "com.apple.dock" AND category == "dock-visibility" AND eventMessage CONTAINS "Space Forces Hidden:""#  // swiftformat:disable all

    private let onUpdate: @MainActor (DockFullScreenState) -> Void
    private var subprocess: Process?
    private var lineBuffer = LineBuffer()
    /// Set by `stop()` so the termination handler can distinguish
    /// graceful shutdown (we asked the subprocess to terminate) from
    /// an unexpected exit (which is fatal — see termination handler).
    private var stopping = false

    init(onUpdate: @escaping @MainActor (DockFullScreenState) -> Void) {
        self.onUpdate = onUpdate
    }

    /// Idempotent — calling start multiple times after the first is
    /// a no-op.
    ///
    /// Throws if the subprocess fails to spawn. The Dock channel is
    /// load-bearing for the entire daemon (without it we have no
    /// fullscreen-state signal at all), so the caller is expected to
    /// `die` rather than swallow — same fail-fast policy as
    /// `AdapterClient.start()`.
    func start() throws {
        guard subprocess == nil else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream",
            "--style", "compact",
            "--predicate", Self.logPredicate,
        ]

        // `log stream` writes its filter-confirmation header
        // ("Filtering the log data using …") to *stdout*, so it lands
        // in our pipe at startup. The header doesn't match our parser
        // (no "fullscreen=true|false" token), so it's silently dropped
        // without a state update. `standardError` is silenced as
        // belt-and-suspenders against any unrelated runtime noise.
        // `Process` retains the pipe via `standardOutput`, so we don't
        // store it ourselves.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        // `readabilityHandler` is a `@Sendable` Swift closure invoked
        // on a background queue, so we can capture `[weak self]`
        // directly and hop to the main actor before touching state.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.ingest(data)
                }
            }
        }

        // Unexpected subprocess exit is fatal — the daemon would lose
        // its only fullscreen-state signal, and degraded operation
        // (always SHOW) is worse than a launchd-orchestrated restart.
        // Capture the scalar status synchronously so the Process
        // reference doesn't cross into the @MainActor task closure.
        // The `stopping` check distinguishes this from graceful
        // shutdown (where `stop()` terminated the subprocess on
        // purpose).
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                guard let self, !self.stopping else { return }
                die("""
                DockSpaceWatcher: log stream subprocess exited \
                unexpectedly (status=\(status))
                """)
            }
        }

        try process.run()
        subprocess = process
    }

    /// Mark the watcher as gracefully stopping and terminate the
    /// subprocess. Called from the daemon's signal handler before
    /// `exit(0)` so the termination handler doesn't race the shutdown
    /// and call `die`. After `stop()` returns, the termination
    /// handler may still fire on a background queue, but the
    /// `stopping` flag (set synchronously here on the main actor)
    /// suppresses the fatal path.
    func stop() {
        stopping = true
        if let subprocess, subprocess.isRunning {
            subprocess.terminate()
        }
    }

    /// Drain complete lines from the buffer, parse each, and forward
    /// state changes to the controller. Non-matching lines (the filter
    /// header, possible private-redacted variants) are silently
    /// dropped.
    private func ingest(_ chunk: Data) {
        lineBuffer.ingest(chunk) { line in
            guard let text = String(data: line, encoding: .utf8) else { return }
            guard let state = Self.parse(text) else { return }
            let pidField = state.pid.map { "\($0)" } ?? "null"
            Log.controller.debug(
                "dock_visibility fs=\(state.isFullScreen, privacy: .public) pid=\(pidField, privacy: .public)",
            )
            onUpdate(state)
        }
    }

    /// Extracts `(isFullScreen, pid?)` from a `Space Forces Hidden:`
    /// log line. Returns nil for lines that don't carry an unambiguous
    /// `fullscreen=true|false` token — that includes the `log stream`
    /// header, any reworded variant Apple may ship in a future macOS,
    /// and unexpectedly redacted output. The caller treats nil as
    /// "ignore this line" rather than crashing or guessing a state.
    ///
    /// `pid=NNNNN` only appears on engage messages (the FS app's tile
    /// names it). Exit messages omit it. A `fullscreen=true` with no
    /// pid would be unexpected; we still surface the state with
    /// `pid=nil`, which the controller's `shouldHideMenuBar` rejects
    /// (the guard requires a non-nil `dockFs.pid`) → SHOW.
    private static func parse(_ line: String) -> DockFullScreenState? {
        let isFullScreen: Bool
        if line.contains("fullscreen=true") {
            isFullScreen = true
        } else if line.contains("fullscreen=false") {
            isFullScreen = false
        } else {
            return nil
        }

        // `\b` (word boundary) prevents matching the `pid=` suffix of
        // `spid=…` if Dock ever switches the space-id field's
        // separator from `:` to `=`. Today's traces use
        // `space=CGSSpace(spid: N)` (colon), so `pid=\d+` would also
        // be correct — the word boundary is purely defensive.
        var pid: pid_t?
        if let match = line.range(of: #"\bpid=\d+"#, options: .regularExpression) {
            let digits = line[match].dropFirst("pid=".count)
            pid = pid_t(digits)
        }

        return DockFullScreenState(isFullScreen: isFullScreen, pid: pid)
    }
}
