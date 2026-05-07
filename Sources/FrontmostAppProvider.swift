// Read-only seam for "who is the frontmost app right now?" — lets
// SmartController consume `NSWorkspace.shared.frontmostApplication`
// in production and a controllable mock in tests.

import AppKit

/// Plain snapshot of the AppKit frontmost app's identifying fields.
/// Decoupled from `NSRunningApplication` so tests don't need to
/// construct one to drive the controller.
struct FrontmostInfo: Equatable {
    let pid: pid_t
    let name: String?
    let bundle: String?
}

@MainActor
protocol FrontmostAppProvider: AnyObject {
    var frontmostApp: FrontmostInfo? { get }
}

@MainActor
final class WorkspaceFrontmostAppProvider: FrontmostAppProvider {
    var frontmostApp: FrontmostInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontmostInfo(
            pid: app.processIdentifier,
            name: app.localizedName,
            bundle: app.bundleIdentifier,
        )
    }
}
