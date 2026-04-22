// Typed wrappers around `pid_t` that distinguish the two roles a
// process identifier plays in houdini's decision logic. Separating
// the two types means the compiler catches mix-ups like passing a
// frontmost PID where a Now Playing PID is expected.
//
// The low-level Accessibility helpers intentionally still take raw
// `pid_t` — they're infrastructure, not role-aware. Callers extract
// `.rawValue` at that boundary.

import Foundation

// macOS tracks, for every process, the user-facing app it acts on
// behalf of (the "responsible process") — e.g. Safari's WebKit GPU
// helper resolves to Safari. Same mechanism TCC uses to attribute a
// camera prompt to Safari when the request came from a WebKit
// content process. Not in a public SDK header, but present and stable
// in libsystem_coreservices since 10.12.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

/// PID of the frontmost (focused) application.
struct FrontmostPID: Hashable, Sendable {
    let rawValue: pid_t
    init(_ rawValue: pid_t) {
        self.rawValue = rawValue
    }
}

/// PID of the application currently owning the system Now Playing
/// widget (i.e. the media source).
struct NowPlayingPID: Hashable, Sendable {
    let rawValue: pid_t
    init(_ rawValue: pid_t) {
        self.rawValue = rawValue
    }
}

extension FrontmostPID {
    /// Whether this frontmost PID refers to the same OS process as
    /// the given Now Playing PID, or to the app that owns it.
    /// Safari (and any WebKit-based browser) routes media through an
    /// out-of-process helper — the Now Playing PID is the helper, not
    /// the visible app. A strict PID match would miss that case, so we
    /// fall back to the OS's responsibility mapping.
    /// Callers must use this explicitly — the two types are
    /// deliberately not `Equatable` across roles.
    func isSameProcess(as other: NowPlayingPID) -> Bool {
        if rawValue == other.rawValue { return true }
        let responsible = responsibility_get_pid_responsible_for_pid(other.rawValue)
        return responsible > 0 && responsible == rawValue
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
