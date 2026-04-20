// Spawns `/usr/bin/perl …/mediaremote-adapter.pl stream` (perl is on
// Apple's MediaRemote allowlist; an unentitled Swift binary isn't) and
// parses the newline-delimited JSON it streams to stdout. Each "data"
// event is decoded into (playing, pid, bundle) and handed to the
// controller on the main queue.

import Foundation

final class AdapterClient {
    typealias UpdateHandler = (_ playing: Bool, _ pid: pid_t, _ bundle: String?) -> Void

    /// Adapter `stream` flags:
    /// - `--no-diff` emits full state on every change, so we don't have
    ///    to reconstruct deltas.
    /// - `--debounce=200` collapses bursts (e.g. scrubbing) to at most
    ///    one event per 200 ms.
    private static let streamArgs = ["stream", "--no-diff", "--debounce=200"]

    private let process = Process()
    private let stdoutPipe = Pipe()
    private var buffer = Data()
    private var stopping = false
    private let onUpdate: UpdateHandler

    init(scriptPath: String,
         frameworkPath: String,
         onUpdate: @escaping UpdateHandler)
    {
        self.onUpdate = onUpdate
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptPath, frameworkPath] + Self.streamArgs
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
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            warn("ignored non-JSON line from adapter: \(String(data: line, encoding: .utf8) ?? "<non-utf8>")")
            return
        }
        guard (obj["type"] as? String) == "data" else { return }

        let payload = (obj["payload"] as? [String: Any]) ?? [:]
        let playing = (payload["playing"] as? Bool) ?? false
        let pid = pid_t((payload["processIdentifier"] as? Int) ?? 0)
        let bundle = payload["bundleIdentifier"] as? String

        DispatchQueue.main.async { self.onUpdate(playing, pid, bundle) }
    }
}
