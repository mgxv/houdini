// A line-oriented buffer for output from a subprocess pipe. Accumulates
// byte chunks and drains complete (newline-terminated) lines to a
// handler. The buffer grows unboundedly on purpose — the caller is
// expected to check `pendingBytes` after each `ingest` and fail fatally
// if a line has grown past whatever cap is appropriate for that stream.
// Keeping the cap policy in the caller lets different streams pick
// different limits without the buffer carrying the state machine.

import Foundation

struct LineBuffer {
    private var data = Data()

    /// Bytes accumulated for the current (not-yet-terminated) line.
    /// Callers check this to enforce a per-stream size cap.
    var pendingBytes: Int {
        data.count
    }

    mutating func ingest(_ chunk: Data, handler: (Data) -> Void) {
        data.append(chunk)
        while let nl = data.firstIndex(of: 0x0A) {
            let line = data.subdata(in: 0 ..< nl)
            data.removeSubrange(0 ... nl)
            handler(line)
        }
    }
}
