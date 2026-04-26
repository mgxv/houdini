// swift-tools-version:6.0
// IDE-only manifest; the canonical build is scripts/build.sh.
// MediaRemoteAdapter.framework isn't declared because the Swift
// binary doesn't link it — loaded at runtime by the Perl subprocess.

import PackageDescription

let package = Package(
    name: "houdini",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "houdini",
            path: "Sources",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
    ],
)
