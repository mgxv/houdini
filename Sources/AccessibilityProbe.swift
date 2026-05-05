// On-demand AX surface for window-level same-app refinement: title
// probing via CGWindowList + AXUIElement, plus the trust check and
// AX-error dedup utilities shared with the AXObserver subscription
// layer in `AXWatcher.swift`. Probes return nil/empty when AX is
// unavailable; callers fall back to process-level matching.

import ApplicationServices
import Foundation

// MARK: - AX trust + permission warnings

func isAccessibilityTrusted() -> Bool {
    AXIsProcessTrusted()
}

/// Short action item emitted to the unified log when AX is missing
/// or revoked. The verbose first-time setup explanation lives in the
/// brew caveats (`Formula/houdini.rb`).
private let accessibilityPermissionMessage = """
Accessibility permission required for window-level same-app refinement.
Grant via: System Settings → Privacy & Security → Accessibility
Then run: brew services restart houdini
"""

@MainActor private var reportedAXErrors: Set<AXError> = []

/// Logs each distinct `AXError` once for the daemon's lifetime.
/// `.apiDisabled` routes through `warn` (the actionable
/// permission message); other errors go to `Log.general` at
/// `.error`. `.success` is a no-op so call sites can pass results
/// unconditionally. Internal so `AXWatcher` (different file) can
/// share the same dedup set.
@MainActor
func noteAXError(_ error: AXError) {
    guard error != .success, !reportedAXErrors.contains(error) else { return }
    reportedAXErrors.insert(error)
    if error == .apiDisabled {
        warn(accessibilityPermissionMessage)
    } else {
        Log.general.error(
            """
            AX call returned \(describeAXError(error), privacy: .public) \
            (rawValue=\(error.rawValue, privacy: .public)) — window-level \
            refinement may be degraded for this session
            """,
        )
    }
}

private func describeAXError(_ error: AXError) -> String {
    switch error {
    case .success: "success"
    case .failure: "failure"
    case .illegalArgument: "illegalArgument"
    case .invalidUIElement: "invalidUIElement"
    case .invalidUIElementObserver: "invalidUIElementObserver"
    case .cannotComplete: "cannotComplete"
    case .attributeUnsupported: "attributeUnsupported"
    case .actionUnsupported: "actionUnsupported"
    case .notificationUnsupported: "notificationUnsupported"
    case .notImplemented: "notImplemented"
    case .notificationAlreadyRegistered: "notificationAlreadyRegistered"
    case .notificationNotRegistered: "notificationNotRegistered"
    case .apiDisabled: "apiDisabled"
    case .noValue: "noValue"
    case .parameterizedAttributeUnsupported: "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: "notEnoughPrecision"
    @unknown default: "unknown"
    }
}

// MARK: - AX SPI

/// Private HIServices symbol that bridges an `AXUIElement` window
/// to its `CGWindowID`. Lets us correlate AX windows with
/// `CGWindowListCopyWindowInfo` entries (which only know CGIDs) so
/// `visibleWindowTitle` can pick the on-screen window in z-order.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(
    _ element: AXUIElement,
    _ windowID: UnsafeMutablePointer<CGWindowID>,
) -> AXError

// MARK: - Window title probing

/// Why a `visibleWindowTitle` probe ended up with the title it did.
/// Drives the snapshot's `axFocusedWindowTitle` polarity:
/// `.ok` → title; `.empty` → ""; `.skipped`/`.denied`/`.ax_failed`
/// → nil. The split is preserved for the log; gate 7 only reads
/// the resulting title value.
enum WindowTitleProbeStatus: String {
    case ok // got a non-empty title
    case skipped // caller didn't probe (short-circuit)
    case denied // AX permission denied (`.apiDisabled`)
    case axFailed = "ax_failed" // AX returned a non-success error other than `.apiDisabled`
    case empty // probe ran, no usable title (no pid / no on-screen windows / all titles empty)
}

struct WindowTitleProbe {
    let title: String?
    let status: WindowTitleProbeStatus

    static let skipped = WindowTitleProbe(title: nil, status: .skipped)
}

/// Title of the topmost on-screen window for `pid` whose AX title is
/// non-empty. CGWindowList is z-ordered front-to-back, so we walk
/// down it and return the first match — needed because AX-focused
/// window doesn't track Space swipes for the same app, and because
/// in fullscreen mode some apps (Chrome) put a titleless helper
/// window ahead of the actual content window in z-order.
@MainActor
func visibleWindowTitle(for pid: pid_t?) -> WindowTitleProbe {
    guard let pid, pid > 0 else {
        return WindowTitleProbe(title: nil, status: .empty)
    }

    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
        as? [[String: Any]]
    else { return WindowTitleProbe(title: nil, status: .empty) }

    let candidateIDs: [CGWindowID] = infos.compactMap { info in
        guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
              let id = info[kCGWindowNumber as String] as? CGWindowID
        else { return nil }
        return id
    }
    guard !candidateIDs.isEmpty else {
        return WindowTitleProbe(title: nil, status: .empty)
    }

    let app = AXUIElementCreateApplication(pid)
    var windowsRef: AnyObject?
    let axStatus = AXUIElementCopyAttributeValue(
        app, kAXWindowsAttribute as CFString, &windowsRef,
    )
    if axStatus == .apiDisabled {
        noteAXError(axStatus)
        return WindowTitleProbe(title: nil, status: .denied)
    }
    if axStatus != .success {
        noteAXError(axStatus)
        return WindowTitleProbe(title: nil, status: .axFailed)
    }
    guard let windows = windowsRef as? [AXUIElement] else {
        return WindowTitleProbe(title: nil, status: .empty)
    }

    // Map AX windows by CGWindowID once — drops the SPI count from
    // O(candidates × windows) to O(windows) for apps with many windows.
    var windowByCGID: [CGWindowID: AXUIElement] = [:]
    windowByCGID.reserveCapacity(windows.count)
    for window in windows {
        var cgID: CGWindowID = 0
        if _AXUIElementGetWindow(window, &cgID) == .success {
            windowByCGID[cgID] = window
        }
    }

    for candidate in candidateIDs {
        guard let window = windowByCGID[candidate] else { continue }

        var titleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &titleRef,
        ) == .success,
            let title = (titleRef as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
        else { continue }
        return WindowTitleProbe(title: title, status: .ok)
    }
    return WindowTitleProbe(title: nil, status: .empty)
}

/// Walks from any AX element up to its enclosing window and returns
/// the window's AX title. If `element` is itself a window
/// (`kAXWindowRole`), reads its title directly. Used to surface the
/// containing window of an `AXObserver` callback element — AX
/// callbacks often hand us the focused UI element rather than the
/// window itself.
@MainActor
func axFocusedWindowTitle(forElement element: AXUIElement) -> String? {
    var roleRef: AnyObject?
    let isWindow = AXUIElementCopyAttributeValue(
        element, kAXRoleAttribute as CFString, &roleRef,
    ) == .success && (roleRef as? String) == (kAXWindowRole as String)

    let window: AXUIElement
    if isWindow {
        window = element
    } else {
        var windowRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXWindowAttribute as CFString, &windowRef,
        ) == .success, let windowRef else { return nil }
        window = windowRef as! AXUIElement
    }

    var titleRef: AnyObject?
    guard AXUIElementCopyAttributeValue(
        window, kAXTitleAttribute as CFString, &titleRef,
    ) == .success else { return nil }
    return (titleRef as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Title normalization

/// Strips browser-injected annotations that wobble while the
/// underlying tab is unchanged — Chrome's ` - Audio playing` /
/// ` - Audio muted` suffix and `(N) ` notification-count prefix.
/// Used as the keying basis for `Controller.overrideMap` so the
/// wobble doesn't drop a sticky override.
func normalizeWindowTitle(_ title: String) -> String {
    var t = title
    for suffix in [" - Audio playing", " - Audio muted"] {
        if let r = t.range(of: suffix) {
            t.removeSubrange(r)
        }
    }
    if let m = t.range(of: #"^\(\d+\)\s+"#, options: .regularExpression) {
        t.removeSubrange(m)
    }
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
}
