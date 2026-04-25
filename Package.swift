// swift-tools-version:6.2.4
// Optional SwiftPM manifest so editors (SourceKit-LSP, Xcode, VS Code)
// can index Sources/ out of the box. The canonical build is
// scripts/build.sh — it also produces MediaRemoteAdapter.framework,
// which this manifest doesn't describe because the Swift binary
// doesn't link it directly (the Perl subprocess loads it at runtime
// via DynaLoader).
//
// The target compiles under the Swift 6 language mode (strict
// concurrency); scripts/build.sh passes the equivalent
// `-swift-version 6` to its direct swiftc invocation so both build
// paths match.
//
// `swift build` works for dev iteration as-is; releases still go
// through scripts/build.sh. Sources/Version.swift is tracked (the
// single source of truth for the version string — scripts/release.sh
// rewrites it on a new release) so IDEs resolve `version` on fresh
// clones without anyone running scripts/build.sh first.

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
