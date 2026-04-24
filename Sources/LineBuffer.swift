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

    /// Scans the buffer once, emitting each complete line to `handler`,
    /// and drops the consumed prefix with a single `removeSubrange` at
    /// the end. Keeps total cost O(N) in the buffer size, instead of
    /// O(k·N) for a per-line remove loop.
    mutating func ingest(_ chunk: Data, handler: (Data) -> Void) {
        data.append(chunk)
        var lineStart = data.startIndex
        var i = data.startIndex
        while i < data.endIndex {
            if data[i] == 0x0A {
                handler(data.subdata(in: lineStart ..< i))
                lineStart = data.index(after: i)
            }
            i = data.index(after: i)
        }
        if lineStart > data.startIndex {
            data.removeSubrange(data.startIndex ..< lineStart)
        }
    }
}
