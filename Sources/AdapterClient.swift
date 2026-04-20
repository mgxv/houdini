// Spawns `/usr/bin/perl …/mediaremote-adapter.pl stream` (perl is on
// Apple's MediaRemote allowlist; an unentitled Swift binary isn't) and
// parses the newline-delimited JSON it streams to stdout. Each "data"
// event is handed to the controller on the main queue.

import Foundation

final class AdapterClient {
    /// Callback delivered on the main queue whenever the adapter emits
    /// a `data` event. `pid` is nil when Now Playing has no current
    /// source (i.e. nothing has ever played, or the last source exited).
    typealias UpdateHandler = (_ playing: Bool, _ pid: NowPlayingPID?, _ bundle: String?) -> Void

    /// Adapter `stream` flags:
    /// - `--no-diff` emits full state on every change, so we don't have
    ///    to reconstruct deltas.
    /// - `--debounce=200` collapses bursts (e.g. scrubbing) to at most
    ///    one event per 200 ms.
    private static let streamArgs: [String] = ["stream", "--no-diff", "--debounce=200"]

    private let process = Process()
    private let stdoutPipe = Pipe()
    private var buffer = Data()
    private var stopping = false
    private let onUpdate: UpdateHandler

    init(artifacts: AdapterArtifacts, onUpdate: @escaping UpdateHandler) {
        self.onUpdate = onUpdate
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [artifacts.scriptPath, artifacts.frameworkPath] + Self.streamArgs
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError
    }

    func start() throws {
        process.terminationHandler = { [weak self] proc in
            guard let self, !self.stopping else { return }
            DispatchQueue.main.async {
                die("mediaremote-adapter exited unexpectedly (status=\(proc.terminationStatus))")
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.ingest(handle.availableData)
        }
        try process.run()
    }

    func stop() {
        stopping = true
        if process.isRunning { process.terminate() }
    }

    /// Accumulates a stdout chunk and flushes any complete (newline-
    /// terminated) lines to `handleLine`.
    private func ingest(_ chunk: Data) {
        if chunk.isEmpty { return }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: 0 ..< nl)
            buffer.removeSubrange(0 ... nl)
            handleLine(line)
        }
    }

    private func handleLine(_ line: Data) {
        guard !line.isEmpty else { return }
        guard let parsed = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            let preview = String(data: line, encoding: .utf8) ?? "<non-utf8>"
            warn("ignored non-JSON line from adapter: \(preview)")
            return
        }
        guard let event = AdapterEvent(from: parsed) else { return }
        DispatchQueue.main.async {
            self.onUpdate(event.playing, event.pid, event.bundle)
        }
    }
}

/// The fields we extract from an adapter `data` event. Missing or
/// wrong-typed fields fall back to safe defaults, matching the
/// behavior of the original dict-based extraction.
private struct AdapterEvent {
    let playing: Bool
    let pid: NowPlayingPID?
    let bundle: String?

    /// Extracts a `data` event from the adapter's parsed JSON object.
    /// Returns nil for any other event type so the caller can silently
    /// ignore heartbeats, errors, etc.
    init?(from object: [String: Any]) {
        guard (object["type"] as? String) == "data" else { return nil }
        let payload = (object["payload"] as? [String: Any]) ?? [:]
        self.playing = (payload["playing"] as? Bool) ?? false
        self.pid = (payload["processIdentifier"] as? Int)
            .map { NowPlayingPID(pid_t($0)) }
        self.bundle = payload["bundleIdentifier"] as? String
    }
}
