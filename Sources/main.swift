// Entry point. Dispatches the subcommand; all real work lives in the
// command handlers in Commands.swift.
//
// `MainActor.assumeIsolated` asserts (and to the compiler, *declares*)
// that top-level code here runs on the main thread. SwiftPM infers this
// automatically for `main.swift` under the Swift 6 language mode, but
// build.sh invokes swiftc directly without that inference, so the wrap
// is required for both build paths to compile.

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
