// Spawns `/usr/bin/perl mediaremote-adapter.pl stream` (perl is on
// Apple's MediaRemote allowlist; an unentitled Swift binary isn't)
// and parses the newline-delimited JSON it streams. Stderr is
// forwarded to the unified log under the "adapter" category.
//
// `actor` so Foundation's background-queue callbacks can hand chunks
// to the actor for line-buffering and parsing. `start()` and `stop()`
// are `nonisolated` so signal handlers can invoke them synchronously.
//
// `isStopping` is in an `OSAllocatedUnfairLock` rather than
// actor-isolated state so `stop()` can set it synchronously before
// `terminate()`. An actor-isolated flag set via `Task { await … }`
// could race the kernel signal: `handleTermination` would then
// observe `isStopping == false` during a clean shutdown and `die(...)`
// for what is graceful.
//
// Pipe chunks fan in through `AsyncStream`s — readability handlers
// `yield`, a single consumer task per stream pulls with `for await`.
// AsyncStream preserves yield order, so chunk-level FIFO is a
// contract, not a default-scheduling assumption. Within a chunk,
// snapshots ship in one `MainActor.run` hop. `stop()` finishes both
// continuations so the consumer loops exit.
//
// `fetchNowPlayingOnce` at the bottom runs the adapter in one-shot
// `get` mode for `status`.

import Foundation
import os

// MARK: - Data types

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
    let title: String?

    /// All-nil sentinel for "nothing is playing." Returned for
    /// `get`-mode `null`/empty output and `stream`-mode `data`
    /// events with a null/missing payload.
    static let empty = NowPlayingSnapshot(
        playing: false,
        pid: nil,
        bundle: nil,
        parentBundle: nil,
        title: nil,
    )
}

/// Decoding lives in an extension so Swift keeps the auto-synthesized
/// memberwise init for `empty` (and any future call site) instead of
/// requiring us to spell it out.
extension NowPlayingSnapshot: Decodable {
    private enum CodingKeys: String, CodingKey {
        case playing
        case pid = "processIdentifier"
        case bundle = "bundleIdentifier"
        case parentBundle = "parentApplicationBundleIdentifier"
        case title
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
            title: c.decodeIfPresent(String.self, forKey: .title),
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

private let sharedDecoder = JSONDecoder()

// MARK: - AdapterClient

actor AdapterClient {
    /// Callback delivered on the main actor for each `data` event.
    typealias UpdateHandler = @Sendable @MainActor (NowPlayingSnapshot) -> Void

    // MARK: Configuration

    /// Adapter `stream` flags:
    /// - `--no-diff` emits full state on every change, so we don't have
    ///    to reconstruct deltas.
    /// - `--debounce=200` collapses bursts (e.g. scrubbing) to at most
    ///    one event per 200 ms.
    /// - `--no-artwork` omits the `artworkData`/`artworkMimeType` fields.
    ///    Houdini never reads them, and base64-encoded TIFF artwork
    ///    bloats every event with hundreds of KiB of unused payload.
    private static let streamArgs: [String] = [
        "stream",
        "--no-diff",
        "--debounce=200",
        "--no-artwork",
    ]

    static let statusPgrepPattern = #"mediaremote-adapter\.pl.*MediaRemoteAdapter\.framework"#

    // MARK: State

    // Process and Pipe are Sendable on macOS 15+, so the actor can
    // hand them to Foundation's @Sendable callbacks unwrapped.
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var stdoutBuffer = LineBuffer()
    private var stderrBuffer = LineBuffer()
    private let isStopping = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let onUpdate: UpdateHandler

    // Fan-in for pipe chunks. `.unbounded` because the producer is
    // 200ms-debounced — realistic rates won't blow up the queue.
    private let stdoutChunks: AsyncStream<Data>
    private let stdoutChunkContinuation: AsyncStream<Data>.Continuation
    private let stderrChunks: AsyncStream<Data>
    private let stderrChunkContinuation: AsyncStream<Data>.Continuation

    init(artifacts: AdapterArtifacts, onUpdate: @escaping UpdateHandler) {
        self.onUpdate = onUpdate
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [artifacts.scriptPath, artifacts.frameworkPath] + Self.streamArgs
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let (outStream, outCont) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        stdoutChunks = outStream
        stdoutChunkContinuation = outCont
        let (errStream, errCont) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        stderrChunks = errStream
        stderrChunkContinuation = errCont
    }

    // MARK: Lifecycle

    nonisolated func start() throws {
        process.terminationHandler = { [weak self] proc in
            // Capture the scalar status synchronously so the Process
            // reference doesn't cross into the Task closure.
            let status = proc.terminationStatus
            Task { await self?.handleTermination(status: status) }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.stdoutChunkContinuation.yield(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.stderrChunkContinuation.yield(data)
        }
        try process.run()

        // One consumer per stream — `for await` serializes by
        // construction so chunk ordering is preserved.
        Task { [weak self] in await self?.runStdoutConsumer() }
        Task { [weak self] in await self?.runStderrConsumer() }
    }

    /// Sets `isStopping` *before* `terminate()` so a fast termination
    /// handler observes the flag and skips the unexpected-exit path.
    /// `finish()` lets the consumer for-await loops exit cleanly.
    nonisolated func stop() {
        isStopping.withLock { $0 = true }
        if process.isRunning { process.terminate() }
        stdoutChunkContinuation.finish()
        stderrChunkContinuation.finish()
    }

    private func handleTermination(status: Int32) {
        if isStopping.withLock({ $0 }) { return }
        Task { @MainActor in
            die("mediaremote-adapter exited unexpectedly (status=\(status))")
        }
    }

    // MARK: Consumers

    private func runStdoutConsumer() async {
        for await chunk in stdoutChunks {
            await ingestStdout(chunk)
        }
    }

    private func runStderrConsumer() async {
        for await chunk in stderrChunks {
            ingestStderr(chunk)
        }
    }

    /// Single `MainActor.run` hop per chunk for atomic delivery —
    /// cross-chunk FIFO is preserved upstream by AsyncStream.
    private func ingestStdout(_ chunk: Data) async {
        var snapshots: [NowPlayingSnapshot] = []
        stdoutBuffer.ingest(chunk) { line in
            if let snapshot = self.parseStdoutLine(line) {
                snapshots.append(snapshot)
            }
        }
        guard !snapshots.isEmpty else { return }

        let handler = onUpdate
        let captured = snapshots
        await MainActor.run {
            for snapshot in captured {
                handler(snapshot)
            }
        }
    }

    /// Forwards each complete stderr line to the "adapter" log
    /// category at `.debug`.
    private func ingestStderr(_ chunk: Data) {
        stderrBuffer.ingest(chunk) { line in
            let text = String(data: line, encoding: .utf8) ?? "<non-utf8>"
            Log.adapter.debug("\(text, privacy: .public)")
        }
    }

    // MARK: Parsing

    /// Returns nil for blanks, non-`data` envelopes, and undecodable
    /// input. Decode errors `warn` and drop the line so a single bad
    /// event doesn't stall the stream; snapshot dispatch happens in
    /// `ingestStdout` after the whole chunk is parsed, so ordering
    /// is preserved.
    private func parseStdoutLine(_ line: Data) -> NowPlayingSnapshot? {
        guard !line.isEmpty else { return nil }

        let event: NowPlayingStreamEvent
        do {
            event = try sharedDecoder.decode(NowPlayingStreamEvent.self, from: line)
        } catch {
            let preview = String(data: line, encoding: .utf8) ?? "<non-utf8>"
            Task { @MainActor in
                warn("could not decode adapter line: \(preview) (\(error))")
            }
            return nil
        }

        Log.adapter.debug("→ \(Self.formatEvent(event), privacy: .public)")

        guard event.type == "data" else { return nil } // ignore heartbeats / errors
        return event.payload ?? .empty
    }

    private static func formatEvent(_ event: NowPlayingStreamEvent) -> String {
        guard event.type == "data" else { return "np_rx type=\(event.type)" }
        guard let payload = event.payload else { return "np_rx type=data payload=null" }
        let play = payload.playing ? "yes" : "no"
        let pid = payload.pid.map { "\($0.rawValue)" } ?? "null"
        let bundle = payload.bundle ?? "null"
        let parent = payload.parentBundle ?? "null"
        let title = payload.title ?? "null"
        return "np_rx type=data play=\(play) pid=\(pid) bundle=\(bundle) parent=\(parent) title=\(title)"
    }
}

// MARK: - One-shot fetch (status command)

/// Synchronous one-shot `mediaremote-adapter.pl get` for the
/// `status` subcommand. Blocks until the subprocess exits.
///
/// `get` emits the raw payload dict (or JSON `null`), not the
/// `{type, payload}` envelope that `stream` uses.
///
/// Returns nil on spawn or parse failure (after a `warn`).
/// Returns `.empty` when nothing currently owns Now Playing.
@MainActor
func fetchNowPlayingOnce(artifacts: AdapterArtifacts) -> NowPlayingSnapshot? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = [artifacts.scriptPath, artifacts.frameworkPath, "get", "--no-artwork"]
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
    } catch {
        warn("failed to launch mediaremote-adapter: \(error)")
        return nil
    }

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    forwardStderrToLog(stderrData)
    guard process.terminationStatus == 0 else {
        warn("mediaremote-adapter exited with status \(process.terminationStatus)")
        return nil
    }

    let trimmed = (String(data: stdoutData, encoding: .utf8) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "null" {
        return .empty
    }
    guard let jsonData = trimmed.data(using: .utf8) else {
        warn("adapter get output not utf-8: \(trimmed)")
        return nil
    }
    do {
        return try sharedDecoder.decode(NowPlayingSnapshot.self, from: jsonData)
    } catch {
        warn("could not decode adapter get output: \(trimmed) (\(error))")
        return nil
    }
}

/// Forwards a captured stderr blob to `Log.adapter.debug`, one
/// line per entry — matching the streaming path's behavior.
private func forwardStderrToLog(_ data: Data) {
    guard !data.isEmpty else { return }
    let text = String(data: data, encoding: .utf8) ?? "<non-utf8>"
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        Log.adapter.debug("\(String(line), privacy: .public)")
    }
}
