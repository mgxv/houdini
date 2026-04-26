// Typed wrappers around `pid_t` that distinguish the two roles a
// process identifier plays in houdini's decision logic. Separating
// the two types means the compiler catches mix-ups like passing a
// frontmost PID where a Now Playing PID is expected.
//
// The low-level Accessibility helpers intentionally still take raw
// `pid_t` — they're infrastructure, not role-aware. Callers extract
// `.rawValue` at that boundary.

import Foundation

/// macOS tracks, for every process, the user-facing app it acts on
/// behalf of (the "responsible process") — e.g. Safari's WebKit GPU
/// helper resolves to Safari. Same mechanism TCC uses to attribute a
/// camera prompt to Safari when the request came from a WebKit
/// content process. Not in a public SDK header, but present and stable
/// in libsystem_coreservices since 10.12. The `@_silgen_name` binds
/// this Swift wrapper to the C symbol, so we can pick any readable
/// Swift name without affecting the link.
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
    /// Whether this frontmost PID refers to the same OS process as
    /// the given Now Playing PID, or to the app that owns it.
    ///
    /// Browsers (Safari, Chrome, Firefox, etc.) route media through
    /// helper processes — and during fullscreen video may also promote
    /// a *different* helper to the foreground. Both PIDs can therefore
    /// be helpers delegating up to the same responsible app, so we
    /// resolve both sides and accept a match via any of three paths:
    ///
    ///   1. Now Playing helper's responsible process is us (classic
    ///      WebKit case with Safari.app in the foreground).
    ///   2. We're a helper whose responsible process is the Now Playing
    ///      app (inverse of the above).
    ///   3. Both sides are helpers of a common responsible app
    ///      (Safari fullscreen helper + media helper, for example).
    ///
    /// Callers must use this explicitly — the two types are
    /// deliberately not `Equatable` across roles.
    func isSameProcess(as other: NowPlayingPID) -> Bool {
        if rawValue == other.rawValue { return true }
        // The user-facing app each side acts on behalf of, per the
        // kernel's responsibility mapping. Returns 0 for processes the
        // system doesn't track, or the PID itself when the process is
        // not delegating for anyone. Resolve the Now Playing side
        // first — Path 1 is the common Safari/Chrome case and doesn't
        // need the frontmost side's mapping.
        let nowPlayingResponsiblePID = responsibleProcess(for: other.rawValue)
        // Path 1: Now Playing is a helper that delegates up to us.
        if nowPlayingResponsiblePID > 0,
           nowPlayingResponsiblePID == rawValue
        {
            return true
        }
        let frontmostResponsiblePID = responsibleProcess(for: rawValue)
        // Path 2: we're a helper that delegates up to the Now Playing app.
        if frontmostResponsiblePID > 0,
           frontmostResponsiblePID == other.rawValue
        {
            return true
        }
        // Path 3: both sides are helpers of the same user-facing app.
        if frontmostResponsiblePID > 0,
           frontmostResponsiblePID == nowPlayingResponsiblePID
        {
            return true
        }
        return false
    }
}

extension NowPlayingPID {
    /// OS-reported responsible process for this PID, or nil if the
    /// syscall returned 0 (not tracked) or the process's own PID
    /// (no delegation). Used to annotate log lines so a failed
    /// `isSameProcess` check is diagnosable without a rebuild.
    var responsiblePID: pid_t? {
        let resolved = responsibleProcess(for: rawValue)
        // 0 means the OS doesn't track this process; equal to our own
        // PID means we're not delegating for anyone. Neither is worth
        // reporting as a distinct "responsible app".
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

/// Decode from a bare JSON number (the shape mediaremote-adapter uses
/// for `processIdentifier`). The Int → pid_t (Int32) narrowing matches
/// the previous dict-fishing init's behavior.
extension NowPlayingPID: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(Int.self)
        self.init(pid_t(raw))
    }
}
