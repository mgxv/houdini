// Entry point. Dispatches the subcommand; all real work lives in the
// command handlers in Commands.swift.

import Foundation

let cmd = CommandLine.arguments.dropFirst().first ?? ""

switch cmd {
case "help", "--help", "-h":
    usage()
    exit(0)
case "":
    runForeground(dryRun: false)
case "--dry-run":
    runForeground(dryRun: true)
default:
    die("unknown command '\(cmd)' — try: houdini help")
}
