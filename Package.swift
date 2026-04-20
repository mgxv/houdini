// swift-tools-version:5.10
// Optional SwiftPM manifest so editors (SourceKit-LSP, Xcode, VS Code)
// can index Sources/ out of the box. The canonical build is build.sh —
// it also produces MediaRemoteAdapter.framework, which this manifest
// doesn't describe because the Swift binary doesn't link it directly
// (the Perl subprocess loads it at runtime via DynaLoader).
//
// Before using SPM (or first opening in an IDE), run ./build.sh once to
// generate the gitignored Sources/Version.swift. After that, `swift
// build` works for dev iteration; releases still go through build.sh.

import PackageDescription

let package = Package(
    name: "houdini",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "houdini",
            path: "Sources",
        ),
    ],
)
