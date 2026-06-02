// Filesystem path resolution used at runtime: the vendored
// mediaremote-adapter artifacts, and the Application Support directory
// backing the on-disk `*State` stores.

import Foundation

/// `~/Library/Application Support/<subsystem>/<name>`, or nil if it
/// can't be resolved. Shared by the `*State` stores.
func subsystemSupportURL(_ name: String) -> URL? {
    guard let appSupport = try? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false,
    ) else { return nil }
    return appSupport
        .appendingPathComponent(Log.subsystem, isDirectory: true)
        .appendingPathComponent(name)
}

struct AdapterArtifacts {
    let scriptPath: String
    let frameworkPath: String
}

/// Resolves the vendored `mediaremote-adapter.pl` and
/// `MediaRemoteAdapter.framework` paths. Searches, in order:
///
///   1. `$HOUDINI_LIBEXEC`                      (explicit override)
///   2. `../libexec/houdini/` relative to binary (Homebrew-style layout)
///   3. The binary's own directory              (development layout)
///
/// The first directory that contains *both* artifacts wins. Exits if no
/// candidate matches.
@MainActor
func locateArtifacts() -> AdapterArtifacts {
    guard let exec = Bundle.main.executableURL else {
        die("could not determine binary path (Bundle.main.executableURL is nil)")
    }
    // Resolve symlinks so Homebrew's /opt/homebrew/bin/houdini shim
    // lands inside the Cellar keg, where libexec/houdini/ lives.
    let binDir = exec.resolvingSymlinksInPath().deletingLastPathComponent()

    var candidates: [URL] = []
    if let override = ProcessInfo.processInfo.environment["HOUDINI_LIBEXEC"],
       !override.isEmpty
    {
        candidates.append(URL(fileURLWithPath: override))
    }
    candidates.append(binDir.deletingLastPathComponent()
        .appendingPathComponent("libexec/houdini"))
    candidates.append(binDir)

    let fm = FileManager.default
    for dir in candidates {
        let script = dir.appendingPathComponent(
            "vendor/mediaremote-adapter/bin/mediaremote-adapter.pl",
        ).path
        let framework = dir.appendingPathComponent("MediaRemoteAdapter.framework").path
        if fm.fileExists(atPath: script), fm.fileExists(atPath: framework) {
            return AdapterArtifacts(scriptPath: script, frameworkPath: framework)
        }
    }

    let searched = candidates.map(\.path).joined(separator: "\n  ")
    die("""
    could not find MediaRemoteAdapter.framework + vendor/mediaremote-adapter/.
    Searched:
      \(searched)
    Run ./scripts/build.sh, or set HOUDINI_LIBEXEC to the directory containing both.
    """)
}
