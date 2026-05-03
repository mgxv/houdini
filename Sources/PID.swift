// Typed wrappers around `pid_t` that distinguish the two roles a
// process identifier plays in houdini's decision logic. Separating
// the two types means the compiler catches mix-ups like passing a
// frontmost PID where a Now Playing PID is expected.

import Foundation

// MARK: - Private helpers (responsibility-PID resolution)

/// macOS tracks, for every process, the user-facing app it acts on
/// behalf of (the "responsible process") — Safari's WebKit GPU
/// helper resolves to Safari. Same mechanism TCC uses to attribute
/// camera prompts. Not in a public SDK header but stable in
/// libsystem_coreservices since 10.12.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibleProcess(for pid: pid_t) -> pid_t

/// True if `a` and `b` resolve to the same user-facing app via
/// `responsibility_get_pid_responsible_for_pid`. The syscall returns
/// 0 for untracked PIDs and the PID itself for non-delegating ones;
/// both filter out via the `> 0` and identity checks. See
/// `isSameProcess(as:)` for the four match paths in plain English.
private func sameResponsibleApp(_ a: pid_t, _ b: pid_t) -> Bool {
    if a == b { return true }
    let aResp = responsibleProcess(for: a)
    if aResp > 0, aResp == b { return true }
    let bResp = responsibleProcess(for: b)
    if bResp > 0, bResp == a { return true }
    if aResp > 0, bResp > 0, aResp == bResp { return true }
    return false
}

private func responsiblePIDOrNil(for pid: pid_t) -> pid_t? {
    let resolved = responsibleProcess(for: pid)
    guard resolved > 0, resolved != pid else { return nil }
    return resolved
}

// MARK: - FrontmostPID

/// PID of the frontmost (focused) application.
struct FrontmostPID: Hashable {
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
        sameResponsibleApp(rawValue, other.rawValue)
    }

    /// True if Dock's FS Space owner resolves to the same app.
    /// Chrome/Safari host the FS window in a helper, so the FS-owner
    /// pid often differs from `frontmostApplication`'s pid — strict
    /// equality would mis-trip `front_not_fs_owner`.
    func isSameApp(asFSOwnerPID fsOwnerPID: FSOwnerPID) -> Bool {
        sameResponsibleApp(rawValue, fsOwnerPID.rawValue)
    }

    var responsiblePID: pid_t? {
        responsiblePIDOrNil(for: rawValue)
    }
}

extension FrontmostPID: CustomStringConvertible {
    var description: String {
        String(rawValue)
    }
}

// MARK: - NowPlayingPID

/// PID of the application currently owning the system Now Playing
/// widget (i.e. the media source).
struct NowPlayingPID: Hashable {
    let rawValue: pid_t
    init(_ rawValue: pid_t) {
        self.rawValue = rawValue
    }
}

extension NowPlayingPID {
    var responsiblePID: pid_t? {
        responsiblePIDOrNil(for: rawValue)
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

// MARK: - FSOwnerPID

/// PID of the application that owns the active fullscreen Space, as
/// reported by Dock's `dock-visibility` log channel.
struct FSOwnerPID: Hashable {
    let rawValue: pid_t
    init(_ rawValue: pid_t) {
        self.rawValue = rawValue
    }
}
