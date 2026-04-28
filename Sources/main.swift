// Entry point. Real work lives in Commands.swift.
//
// `MainActor.assumeIsolated` is required because scripts/build.sh
// invokes swiftc directly without SwiftPM's inference of
// `@MainActor` for `main.swift` under the Swift 6 language mode.

import Foundation

MainActor.assumeIsolated {
    let args = Array(CommandLine.arguments.dropFirst())
    let cmd = args.first ?? ""

    switch cmd {
    case "help", "--help", "-h":
        usage()
        exit(0)
    case "version", "--version", "-v":
        runVersion()
    case "logs":
        runLogs(args: Array(args.dropFirst()))
    case "status":
        runStatus()
    case "":
        runForeground()
    default:
        die("unknown command '\(cmd)' — try: houdini help")
    }
}
