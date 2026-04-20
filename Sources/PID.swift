// Typed wrappers around `pid_t` that distinguish the two roles a
// process identifier plays in houdini's decision logic. Separating
// the two types means the compiler catches mix-ups like passing a
// frontmost PID where a Now Playing PID is expected.
//
// The low-level Accessibility helpers intentionally still take raw
// `pid_t` — they're infrastructure, not role-aware. Callers extract
// `.rawValue` at that boundary.

import Foundation

/// PID of the frontmost (focused) application.
struct FrontmostPID: Hashable {
    let rawValue: pid_t
    init(_ rawValue: pid_t) {
        self.rawValue = rawValue
    }
}

/// PID of the application currently owning the system Now Playing
/// widget (i.e. the media source).
struct NowPlayingPID: Hashable {
    let rawValue: pid_t
    init(_ rawValue: pid_t) {
        self.rawValue = rawValue
    }
}

extension FrontmostPID {
    /// Whether this frontmost PID refers to the same OS process as
    /// the given Now Playing PID. Callers must use this explicitly —
    /// the two types are deliberately not `Equatable` across roles.
    func isSameProcess(as other: NowPlayingPID) -> Bool {
        rawValue == other.rawValue
    }
}

extension FrontmostPID: CustomStringConvertible {
    var description: String {
        String(rawValue)
    }
}

extension NowPlayingPID: CustomStringConvertible {
    var description: String {
        String(rawValue)
    }
}
