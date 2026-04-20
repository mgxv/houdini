// Filesystem paths used at runtime. LaunchAgent-specific paths live in
// LaunchAgent.swift.

import Foundation

/// Builds a URL relative to the user's home directory.
func homeURL(_ subpath: String) -> URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(subpath)
}

/// Where `houdini install` drops the CLI symlink.
func symlinkURL() -> URL {
    homeURL(".local/bin/houdini")
}

/// Whether the directory containing the CLI symlink is on $PATH.
func symlinkDirIsOnPath() -> Bool {
    guard let path = ProcessInfo.processInfo.environment["PATH"] else { return false }
    let target = symlinkURL().deletingLastPathComponent().path
    return path.split(separator: ":").contains { String($0) == target }
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
func locateArtifacts() -> (script: String, framework: String) {
    guard let exec = Bundle.main.executableURL else {
        die("could not determine binary path (Bundle.main.executableURL is nil)")
    }
    let binDir = exec.deletingLastPathComponent()

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
            return (script, framework)
        }
    }

    let searched = candidates.map(\.path).joined(separator: "\n  ")
    die("""
    could not find MediaRemoteAdapter.framework + vendor/mediaremote-adapter/.
    Searched:
      \(searched)
    Run ./build.sh, or set HOUDINI_LIBEXEC to the directory containing both.
    """)
}
