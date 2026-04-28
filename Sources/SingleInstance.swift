// Per-user single-instance lock. `flock` on a file in Application
// Support — kernel releases on any exit (including SIGKILL/panic),
// so no stale-state cleanup on crash. Application Support rather
// than Caches/tmp because cleaning utilities purge those, and a
// deleted lock file lets a second daemon start on a fresh inode.

import Darwin
import Foundation

/// Read-only — safe from `probeDaemonRunning`.
private func instanceLockURL() -> URL {
    let fm = FileManager.default
    let appSupport = (try? fm.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false,
    )) ?? URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    return appSupport
        .appendingPathComponent(Log.subsystem, isDirectory: true)
        .appendingPathComponent("instance.lock")
}

/// Dies if another daemon is already running. The fd is
/// intentionally leaked — closing would release the lock.
@MainActor
func acquireInstanceLock() {
    let url = instanceLockURL()
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
    } catch {
        die("could not create lock directory: \(error)")
    }

    let path = url.path
    let fd = open(path, O_RDWR | O_CREAT, 0o644)
    if fd < 0 {
        die("could not open lock file \(path): \(String(cString: strerror(errno)))")
    }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        if errno == EWOULDBLOCK {
            die("""
            another houdini is already running. Stop it with `brew services stop houdini` \
            (or `pkill -x houdini` for a foreground copy), then try again.
            """)
        }
        die("flock on \(path) failed: \(String(cString: strerror(errno)))")
    }
}

/// Side-effect-free probe used by `status`. Returns false if the
/// lock file doesn't exist yet (no daemon has run on this account).
func probeDaemonRunning() -> Bool {
    let path = instanceLockURL().path
    guard FileManager.default.fileExists(atPath: path) else { return false }
    let fd = open(path, O_RDWR)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
        flock(fd, LOCK_UN)
        return false
    }
    return errno == EWOULDBLOCK
}
