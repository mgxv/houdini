// Typed wrappers around `pid_t` that distinguish the two roles a
// process identifier plays in houdini's decision logic. Separating
// the two types means the compiler catches mix-ups like passing a
// frontmost PID where a Now Playing PID is expected.

import Foundation

/// macOS tracks, for every process, the user-facing app it acts on
/// behalf of (the "responsible process") — Safari's WebKit GPU
/// helper resolves to Safari. Same mechanism TCC uses to attribute
/// camera prompts. Not in a public SDK header but stable in
/// libsystem_coreservices since 10.12.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibleProcess(for pid: pid_t) -> pid_t

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
    /// Browsers route media through helper processes and during
    /// fullscreen video may promote a *different* helper to the
    /// foreground. Both sides can therefore be helpers of the same
    /// responsible app. We accept a match via any of three paths:
    ///
    ///   1. Now Playing's responsible process is us (Safari/WebKit).
    ///   2. We're a helper whose responsible process is Now Playing.
    ///   3. Both sides are helpers of a common responsible app.
    ///
    /// Callers must use this explicitly — the two types are
    /// deliberately not Equatable across roles.
    func isSameProcess(as other: NowPlayingPID) -> Bool {
        if rawValue == other.rawValue { return true }
        // `responsibleProcess` returns 0 for untracked processes,
        // and the PID itself for non-delegating ones. Resolve Now
        // Playing first — Path 1 is the common case.
        let nowPlayingResponsiblePID = responsibleProcess(for: other.rawValue)
        // Path 1: Now Playing is a helper that delegates up to us.
        if nowPlayingResponsiblePID > 0,
           nowPlayingResponsiblePID == rawValue
        {
            return true
        }
        let frontmostResponsiblePID = responsibleProcess(for: rawValue)
        // Path 2: we're a helper that delegates up to Now Playing.
        if frontmostResponsiblePID > 0,
           frontmostResponsiblePID == other.rawValue
        {
            return true
        }
        // Path 3: both helpers of the same user-facing app.
        if frontmostResponsiblePID > 0,
           frontmostResponsiblePID == nowPlayingResponsiblePID
        {
            return true
        }
        return false
    }
}

extension NowPlayingPID {
    /// Responsible process for this PID, or nil if untracked
    /// (syscall returned 0) or self-delegating. Used to annotate log
    /// lines so a failed `isSameProcess` check is diagnosable
    /// without a rebuild.
    var responsiblePID: pid_t? {
        let resolved = responsibleProcess(for: rawValue)
        guard resolved > 0, resolved != rawValue else { return nil }
        return resolved
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

/// Decode from a bare JSON number — the shape mediaremote-adapter
/// uses for `processIdentifier`.
extension NowPlayingPID: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(Int.self)
        self.init(pid_t(raw))
    }
}
