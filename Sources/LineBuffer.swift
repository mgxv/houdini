// A line-oriented buffer for output from a subprocess pipe. Accumulates
// byte chunks and drains complete (newline-terminated) lines to a
// handler. If an in-progress (un-terminated) line exceeds `limit`, the
// buffer is dropped and further bytes are skipped until the next
// newline, so a misbehaving subprocess can't grow the daemon's RSS
// without bound. Complete lines are never truncated — the cap only
// applies to the tail with no newline in sight.
//
// The overflow callback fires once per buffer lifetime; further
// overflows are handled silently. Same once-only pattern used for the
// Accessibility-revoked notice in Accessibility.swift.

import Foundation

struct LineBuffer {
    let limit: Int
    private var data = Data()
    private var resyncing = false
    private var warned = false

    init(limit: Int) {
        self.limit = limit
    }

    mutating func ingest(
        _ chunk: Data,
        handler: (Data) -> Void,
        onOverflow: () -> Void,
    ) {
        var remaining = chunk
        while !remaining.isEmpty {
            if resyncing {
                guard let nl = remaining.firstIndex(of: 0x0A) else { return }
                resyncing = false
                remaining = remaining.subdata(in: (nl + 1) ..< remaining.count)
                continue
            }

            data.append(remaining)
            remaining = Data()

            while let nl = data.firstIndex(of: 0x0A) {
                let line = data.subdata(in: 0 ..< nl)
                data.removeSubrange(0 ... nl)
                handler(line)
            }

            if data.count > limit {
                data.removeAll(keepingCapacity: false)
                resyncing = true
                if !warned {
                    warned = true
                    onOverflow()
                }
            }
        }
    }
}
