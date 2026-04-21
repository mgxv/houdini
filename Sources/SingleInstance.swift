// Per-user single-instance lock for the daemon. `flock` on a file in
// Application Support guarantees at most one running daemon per user.
// The kernel releases the lock when the process exits — including
// SIGKILL and panic — so there's no stale-state cleanup on crash.
//
// Application Support, rather than Caches or /tmp, because cleaning
// utilities routinely purge cache-style locations and a deleted lock
// file lets a second daemon start up on a fresh inode.

import Darwin
import Foundation

/// Absolute URL of the lock file. Does not create anything on disk —
/// safe to call from read-only paths like `probeDaemonRunning`.
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

/// Acquires the exclusive per-user lock, or dies with a clear message
/// if another daemon is already running. The returned file descriptor
/// is intentionally leaked — the lock lives for the lifetime of the
/// process, and closing would release it. Call exactly once, at the
/// top of `runForeground`.
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

/// Side-effect-free probe: is a daemon currently holding the lock?
/// Returns false if the lock file doesn't exist yet (no daemon has
/// ever run on this user account). Used by `status`.
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
