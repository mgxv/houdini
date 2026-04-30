// Accumulates byte chunks from a subprocess pipe, drains complete
// (newline-terminated) lines to a handler. `pendingBytes` exposes
// the size of the not-yet-terminated tail, used by tests to assert
// chunk-boundary semantics.

import Foundation

struct LineBuffer {
    private var data = Data()

    /// Bytes in the current (not-yet-terminated) line.
    var pendingBytes: Int {
        data.count
    }

    /// Single scan + single `removeSubrange` keeps total cost O(N)
    /// in buffer size, vs. O(k·N) for a per-line remove loop.
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
