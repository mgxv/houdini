// Read-only seam for the frontmost app — `NSWorkspace` in production,
// mockable in tests.

import AppKit

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
