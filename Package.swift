// swift-tools-version:6.0
// IDE-only manifest; the canonical build is scripts/build.sh.
// MediaRemoteAdapter.framework isn't declared because the Swift
// binary doesn't link it — loaded at runtime by the Perl subprocess.

import Foundation
import PackageDescription

let minMacOS: String = {
    let manifestDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let url = manifestDir.appendingPathComponent("MIN_MACOS")
    return (try? String(contentsOf: url, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "15.0"
}()

let package = Package(
    name: "houdini",
    platforms: [.macOS(minMacOS)],
    targets: [
        .executableTarget(
            name: "houdini",
            path: "Sources",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
        .testTarget(
            name: "Tests",
            dependencies: ["houdini"],
            path: "Tests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
    ],
)
