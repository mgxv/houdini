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
    /// a `data` event. See `NowPlayingSnapshot` for field semantics —
    /// in particular, `pid == nil` means nothing currently owns Now
    /// Playing, and `parentBundle` is set for helper-process owners so
    /// the controller's bundle-id identity check can match them to the
    /// user-facing app.
    typealias UpdateHandler = @Sendable @MainActor (NowPlayingSnapshot) -> Void

    /// Adapter `stream` flags:
    /// - `--no-diff` emits full state on every change, so we don't have
    ///    to reconstruct deltas.
    /// - `--debounce=200` collapses bursts (e.g. scrubbing) to at most
    ///    one event per 200 ms.
    /// - `--no-artwork` omits the `artworkData`/`artworkMimeType` fields.
    ///    Houdini never reads them, and base64-encoded TIFF artwork can
    ///    exceed the stdout line buffer on track changes.
    private static let streamArgs: [String] = [
        "stream", "--no-diff", "--debounce=200", "--no-artwork",
    ]

    /// Max bytes we'll buffer for a single line before treating the
    /// subprocess as broken. `--no-artwork` keeps realistic stream-mode
    /// events under a kilobyte, so anything past this cap is a bug.
    /// Exceeding it is fatal — launchd will restart the daemon.
    private static let stdoutLineLimit = 256 * 1024

    /// Stderr carries short log messages from the adapter; same fatal
    /// treatment but with a tighter cap.
    private static let stderrLineLimit = 64 * 1024

    // Process and Pipe are declared Sendable by the Foundation SDK on
    // macOS 15+, so the actor can hand them to Foundation's @Sendable
    // terminationHandler / readabilityHandler closures without a wrapper.
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var stdoutBuffer = LineBuffer()
    private var stderrBuffer = LineBuffer()
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

    private func markStopping() {
        stopping = true
    }

    private func handleTermination(status: Int32) {
        guard !stopping else { return }
        Task { @MainActor in
            die("mediaremote-adapter exited unexpectedly (status=\(status))")
        }
    }

    /// Accumulates a stdout chunk and flushes any complete (newline-
    /// terminated) lines to `handleStdoutLine`. If an in-progress line
    /// exceeds the cap, the subprocess is malfunctioning — `die` and
    /// let launchd restart us.
    private func ingestStdout(_ chunk: Data) {
        stdoutBuffer.ingest(chunk) { self.handleStdoutLine($0) }
        if stdoutBuffer.pendingBytes > Self.stdoutLineLimit {
            Task { @MainActor in
                die("adapter stdout exceeded \(Self.stdoutLineLimit / 1024) KiB without a newline")
            }
        }
    }

    /// Accumulates a stderr chunk and forwards each complete line to
    /// the unified log under the "adapter" category at `.debug` level.
    /// Surfaces in `houdini logs` (which streams the whole subsystem at
    /// debug). Same fatal-on-overflow policy as stdout.
    private func ingestStderr(_ chunk: Data) {
        stderrBuffer.ingest(chunk) { line in
            let text = String(data: line, encoding: .utf8) ?? "<non-utf8>"
            Log.adapter.debug("\(text, privacy: .public)")
        }
        if stderrBuffer.pendingBytes > Self.stderrLineLimit {
            Task { @MainActor in
                die("adapter stderr exceeded \(Self.stderrLineLimit / 1024) KiB without a newline")
            }
        }
    }

    private func handleStdoutLine(_ line: Data) {
        guard !line.isEmpty else { return }

        let event: NowPlayingStreamEvent
        do {
            event = try Self.decoder.decode(NowPlayingStreamEvent.self, from: line)
        } catch {
            let preview = String(data: line, encoding: .utf8) ?? "<non-utf8>"
            Task { @MainActor in
                warn("could not decode adapter line: \(preview) (\(error))")
            }
            return
        }

        guard event.type == "data" else { return } // ignore heartbeats / errors
        let snapshot = event.payload ?? .empty // null/missing payload → nothing playing

        let handler = onUpdate
        Task { @MainActor in handler(snapshot) }
    }

    /// Shared decoder. Stateless once configured; reusing avoids
    /// per-line allocation churn.
    private static let decoder = JSONDecoder()
}

/// What the adapter tells us about the current Now Playing source.
/// `pid == nil` means no app currently owns Now Playing. `bundle` is
/// the PID's own bundle id; `parentBundle` is MediaRemote's assertion
/// of the logical owning app, set for helper-process owners (e.g.
/// `com.apple.Safari` when the pid belongs to WebKit.GPU).
struct NowPlayingSnapshot {
    let playing: Bool
    let pid: NowPlayingPID?
    let bundle: String?
    let parentBundle: String?

    /// All-nil sentinel for "nothing is playing." Returned for
    /// `get`-mode `null`/empty output and for `stream`-mode `data`
    /// events whose `payload` is null or missing.
    static let empty = NowPlayingSnapshot(
        playing: false,
        pid: nil,
        bundle: nil,
        parentBundle: nil,
    )
}

// Decoding lives in an extension so Swift keeps the auto-synthesized
// memberwise init for `empty` (and any future call site) instead of
// requiring us to spell it out.
extension NowPlayingSnapshot: Decodable {
    private enum CodingKeys: String, CodingKey {
        case playing
        case pid = "processIdentifier"
        case bundle = "bundleIdentifier"
        case parentBundle = "parentApplicationBundleIdentifier"
    }

    /// Missing keys decode to defaults (`playing` → `false`, optionals
    /// → `nil`). A wrong-typed value still throws — schema drift in
    /// mediaremote-adapter surfaces as a `DecodingError` rather than
    /// silently degrading to all-nil.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            playing: c.decodeIfPresent(Bool.self, forKey: .playing) ?? false,
            pid: c.decodeIfPresent(NowPlayingPID.self, forKey: .pid),
            bundle: c.decodeIfPresent(String.self, forKey: .bundle),
            parentBundle: c.decodeIfPresent(String.self, forKey: .parentBundle),
        )
    }
}

/// `stream`-mode envelope: `{type, payload}`. We only act on `type ==
/// "data"`; everything else (heartbeats, errors) is silently ignored.
/// `payload` is optional so a `data` event with a missing or null
/// payload still decodes — call sites map that to `NowPlayingSnapshot.empty`.
struct NowPlayingStreamEvent: Decodable {
    let type: String
    let payload: NowPlayingSnapshot?
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
/// Returns a snapshot with all-nil fields when no app currently owns
/// Now Playing.
@MainActor
func fetchNowPlayingOnce(artifacts: AdapterArtifacts) -> NowPlayingSnapshot? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = [artifacts.scriptPath, artifacts.frameworkPath, "get", "--no-artwork"]
    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = FileHandle.standardError

    do {
        try process.run()
    } catch {
        warn("failed to launch mediaremote-adapter: \(error)")
        return nil
    }
    // Drain stdout before waiting: `readDataToEndOfFile` blocks until
    // the adapter closes stdout at exit. The inverse order
    // (`waitUntilExit` first) would risk the adapter blocking on a
    // full pipe buffer.
    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        warn("mediaremote-adapter exited with status \(process.terminationStatus)")
        return nil
    }

    let trimmed = (String(data: data, encoding: .utf8) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "null" {
        return .empty
    }
    guard let jsonData = trimmed.data(using: .utf8) else {
        warn("adapter get output not utf-8: \(trimmed)")
        return nil
    }
    do {
        return try JSONDecoder().decode(NowPlayingSnapshot.self, from: jsonData)
    } catch {
        warn("could not decode adapter get output: \(trimmed) (\(error))")
        return nil
    }
}
