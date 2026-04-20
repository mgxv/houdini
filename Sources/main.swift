// Entry point. Dispatches the subcommand; all real work lives in the
// command handlers in Commands.swift.

import Foundation

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
case "":
    runForeground()
default:
    die("unknown command '\(cmd)' — try: houdini help")
}
