// Paths, plist body, and launchctl wrapper for the per-user
// LaunchAgent installed by `houdini install`.

import Foundation

let agentLabel = "com.houdini"

func plistURL() -> URL {
    homeURL("Library/LaunchAgents/\(agentLabel).plist")
}

func logURL() -> URL {
    homeURL("Library/Logs/houdini.log")
}

func errURL() -> URL {
    homeURL("Library/Logs/houdini.err")
}

func domainTarget() -> String {
    "gui/\(getuid())"
}

func serviceTarget() -> String {
    "\(domainTarget())/\(agentLabel)"
}

/// Runs `/bin/launchctl` synchronously and returns its status + stderr.
func launchctl(_ args: [String]) -> (status: Int32, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = args
    let errPipe = Pipe()
    process.standardError = errPipe
    process.standardOutput = Pipe()
    do {
        try process.run()
    } catch {
        return (-1, "spawn failed: \(error)")
    }
    process.waitUntilExit()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(data: errData, encoding: .utf8) ?? "")
}

/// XML plist describing the agent that runs the given binary at login
/// and is kept alive by launchd.
func makeAgentPlistData(binary: String) -> Data {
    let dict: [String: Any] = [
        "Label": agentLabel,
        "ProgramArguments": [binary],
        "RunAtLoad": true,
        "KeepAlive": true,
        "StandardOutPath": logURL().path,
        "StandardErrorPath": errURL().path,
        "ProcessType": "Background",
    ]
    return try! PropertyListSerialization.data(
        fromPropertyList: dict, format: .xml, options: 0,
    )
}
