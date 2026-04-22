// `AdapterClient` spawns `/usr/bin/perl …/mediaremote-adapter.pl
// stream` (perl is on Apple's MediaRemote allowlist; an unentitled
// Swift binary isn't) and parses the newline-delimited JSON it
// streams to stdout. Each "data" event is handed to the controller on
// the main actor. Anything the subprocess writes to stderr is
// forwarded line-by-line to the unified log under the "adapter"
// category, so it's distinguishable from houdini's own warnings
// without needing a stream-specific prefix.
//
// The client is an `actor`: Foundation delivers `terminationHandler`
// and `readabilityHandler` callbacks on its own background queues, and
// those callbacks hop into the actor via `Task { await self?.… }`
// before touching the line buffers. `start()` and `stop()` are
// `nonisolated` so the @MainActor `runForeground` and its SIGINT/
// SIGTERM signal handler can invoke them synchronously without an
// `await`. The `UpdateHandler` callback is `@Sendable @MainActor`, so
// every decision-affecting event reaches the controller on main.
//
// `fetchNowPlayingOnce` at the bottom of the file runs the adapter in
// one-shot `get` mode for the `status` subcommand; it's @MainActor
// and blocks the caller until the subprocess exits.

import Foundation

actor AdapterClient {
    /// Callback delivered on the main actor whenever the adapter emits
    /// a `data` event. `pid` is nil when Now Playing has no current
    /// source (i.e. nothing has ever played, or the last source exited).
    typealias UpdateHandler = @Sendable @MainActor (
        _ playing: Bool, _ pid: NowPlayingPID?, _ bundle: String?
    ) -> Void

    /// Adapter `stream` flags:
    /// - `--no-diff` emits full state on every change, so we don't have
    ///    to reconstruct deltas.
    /// - `--debounce=200` collapses bursts (e.g. scrubbing) to at most
    ///    one event per 200 ms.
    private static let streamArgs: [String] = ["stream", "--no-diff", "--debounce=200"]

    /// Max bytes we'll buffer for a single stdout line. Sized well above
    /// any realistic event — stream-mode JSON with base64 artwork data
    /// tops out around a megabyte in the wild — but small enough that a
    /// runaway subprocess can't exhaust memory.
    private static let stdoutLineLimit = 2 * 1024 * 1024

    /// Max bytes for a single stderr line. Stderr carries short log
    /// messages from the adapter, so this is much tighter.
    private static let stderrLineLimit = 64 * 1024

    // Process and Pipe are declared Sendable by the Foundation SDK on
    // macOS 15+, so the actor can hand them to Foundation's @Sendable
    // terminationHandler / readabilityHandler closures without a wrapper.
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var stdoutBuffer = LineBuffer(limit: stdoutLineLimit)
    private var stderrBuffer = LineBuffer(limit: stderrLineLimit)
    private var stopping = false
    private let onUpdate: UpdateHandler

    init(artifacts: AdapterArtifacts, onUpdate: @escaping UpdateHandler) {
        self.onUpdate = onUpdate
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [artifacts.scriptPath, artifacts.frameworkPath] + Self.streamArgs
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    /// `nonisolated` so callers (the @MainActor `runForeground`) can
    /// invoke it synchronously without an `await` hop. Only touches
    /// `Sendable` state (process, pipes) directly; the Foundation-
    /// delivered callbacks defer actor-isolated work via
    /// `Task { await self?.… }`.
    nonisolated func start() throws {
        process.terminationHandler = { [weak self] proc in
            // Capture the scalar status synchronously so the Process
            // reference itself doesn't cross into the Task closure;
            // the actor-internal `stopping` flag is checked after hop.
            let status = proc.terminationStatus
            Task { await self?.handleTermination(status: status) }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.ingestStdout(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.ingestStderr(data) }
        }
        try process.run()
    }

    /// Terminates the subprocess. `nonisolated` because signal handlers
    /// call this synchronously during shutdown and can't `await`;
    /// `Process.terminate()` is thread-safe per Foundation docs. Sets
    /// the actor-isolated `stopping` flag via a detached task — the
    /// race against `handleTermination` below is benign: in the worst
    /// case we log an "unexpected exit" line we could have suppressed.
    nonisolated func stop() {
        Task { await self.markStopping() }
        if process.isRunning { process.terminate() }
    }

    private func markStopping() { stopping = true }

    private func handleTermination(status: Int32) {
        guard !stopping else { return }
        Task { @MainActor in
            die("mediaremote-adapter exited unexpectedly (status=\(status))")
        }
    }

    /// Accumulates a stdout chunk and flushes any complete (newline-
    /// terminated) lines to `handleStdoutLine`.
    private func ingestStdout(_ chunk: Data) {
        stdoutBuffer.ingest(
            chunk,
            handler: { self.handleStdoutLine($0) },
            onOverflow: {
                let message = "adapter stdout exceeded \(Self.stdoutLineLimit / 1024 / 1024) MiB without a newline; buffer reset. Further overflows suppressed until restart."
                Task { @MainActor in warn(message) }
            },
        )
    }

    /// Accumulates a stderr chunk and forwards each complete line to
    /// the unified log under the "adapter" category at `.debug` level,
    /// so the default `houdini logs` stream stays focused on decisions
    /// and warnings. Surface it with `houdini logs adapter` when
    /// diagnosing the subprocess.
    private func ingestStderr(_ chunk: Data) {
        stderrBuffer.ingest(
            chunk,
            handler: { line in
                let text = String(data: line, encoding: .utf8) ?? "<non-utf8>"
                Log.adapter.debug("\(text, privacy: .public)")
            },
            onOverflow: {
                let message = "adapter stderr exceeded \(Self.stderrLineLimit / 1024) KiB without a newline; buffer reset. Further overflows suppressed until restart."
                Task { @MainActor in warn(message) }
            },
        )
    }

    private func handleStdoutLine(_ line: Data) {
        guard !line.isEmpty else { return }
        guard let parsed = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            let preview = String(data: line, encoding: .utf8) ?? "<non-utf8>"
            Task { @MainActor in warn("ignored non-JSON line from adapter: \(preview)") }
            return
        }
        guard let event = AdapterEvent(from: parsed) else { return }
        let handler = onUpdate
        Task { @MainActor in handler(event.playing, event.pid, event.bundle) }
    }
}

/// The fields we extract from an adapter `data` event. Missing or
/// wrong-typed fields fall back to safe defaults, matching the
/// behavior of the original dict-based extraction.
private struct AdapterEvent: Sendable {
    let playing: Bool
    let pid: NowPlayingPID?
    let bundle: String?

    /// Extracts a `data` event from the adapter's parsed JSON object.
    /// Returns nil for any other event type so the caller can silently
    /// ignore heartbeats, errors, etc.
    init?(from object: [String: Any]) {
        guard (object["type"] as? String) == "data" else { return nil }
        let payload = (object["payload"] as? [String: Any]) ?? [:]
        playing = (payload["playing"] as? Bool) ?? false
        pid = (payload["processIdentifier"] as? Int)
            .map { NowPlayingPID(pid_t($0)) }
        bundle = payload["bundleIdentifier"] as? String
    }
}

/// One-shot Now Playing snapshot returned by `fetchNowPlayingOnce`.
/// `pid == nil` means no app currently owns the Now Playing widget
/// (the adapter emits the literal JSON `null` in that case).
struct NowPlayingSnapshot: Sendable {
    let playing: Bool
    let pid: NowPlayingPID?
    let bundle: String?
}

/// Synchronously invokes `mediaremote-adapter.pl get` and parses the
/// result. Blocks the calling thread until the adapter exits. Intended
/// for the `status` subcommand; the daemon uses the streaming
/// `AdapterClient` instead.
///
/// Note: `get` emits the raw payload dict (or the literal JSON `null`),
/// not the `{type, payload}` envelope that `stream` uses.
///
/// Returns nil on spawn or parse failure (a `warn()` is emitted first).
/// Returns `NowPlayingSnapshot(playing: false, pid: nil, bundle: nil)`
/// when no app currently owns Now Playing.
@MainActor
func fetchNowPlayingOnce(artifacts: AdapterArtifacts) -> NowPlayingSnapshot? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = [artifacts.scriptPath, artifacts.frameworkPath, "get"]
    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = FileHandle.standardError

    do {
        try process.run()
    } catch {
        warn("failed to launch mediaremote-adapter: \(error)")
        return nil
    }
    // Read before waiting: `get` output can exceed the pipe buffer
    // when it includes artworkData. readDataToEndOfFile blocks until
    // the adapter closes stdout at exit.
    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        warn("mediaremote-adapter exited with status \(process.terminationStatus)")
        return nil
    }

    let trimmed = (String(data: data, encoding: .utf8) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "null" {
        return NowPlayingSnapshot(playing: false, pid: nil, bundle: nil)
    }
    guard let jsonData = trimmed.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
    else {
        warn("could not parse adapter get output: \(trimmed)")
        return nil
    }
    return NowPlayingSnapshot(
        playing: (parsed["playing"] as? Bool) ?? false,
        pid: (parsed["processIdentifier"] as? Int).map { NowPlayingPID(pid_t($0)) },
        bundle: parsed["bundleIdentifier"] as? String,
    )
}
