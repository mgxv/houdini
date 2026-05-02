// AX helper for window-level same-app refinement. Returns nil
// whenever AX is unavailable; callers fall back to process-level.

import ApplicationServices
import Foundation

/// Short action item emitted to the unified log when AX is missing
/// or revoked. The verbose first-time setup explanation lives in the
/// brew caveats (`Formula/houdini.rb`).
let accessibilityPermissionMessage = """
Accessibility permission required for window-level same-app refinement.
Grant via: System Settings → Privacy & Security → Accessibility
Then run: brew services restart houdini
"""

func isAccessibilityTrusted() -> Bool {
    AXIsProcessTrusted()
}

@MainActor private var reportedAXErrors: Set<AXError> = []

@MainActor
private func noteAXError(_ error: AXError) {
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

/// Private HIServices symbol that bridges an `AXUIElement` window
/// to its `CGWindowID`. Lets us correlate AX windows with
/// `CGWindowListCopyWindowInfo` entries (which only know CGIDs) so
/// `visibleWindowTitle` can pick the on-screen window in z-order.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(
    _ element: AXUIElement,
    _ windowID: UnsafeMutablePointer<CGWindowID>,
) -> AXError

/// Why a `visibleWindowTitle` probe ended up with the title it did.
/// The decision treats every non-`ok` case as nil (lenient hide);
/// the split is for the log only.
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

/// Walks from any AX element up to its enclosing window and returns
/// the window's AX title. If `element` is itself a window
/// (`kAXWindowRole`), reads its title directly. Used to surface the
/// containing window of an `AXObserver` callback element — AX
/// callbacks often hand us the focused UI element rather than the
/// window itself.
@MainActor
func windowTitle(forElement element: AXUIElement) -> String? {
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

/// Subscribes to focus and title changes for a target app via AX.
/// Fires `onChange(notificationName, element)` on the main actor for
/// each `kAXFocusedWindowChanged` / `kAXFocusedUIElementChanged` /
/// `kAXTitleChanged` notification — title-changed is re-pointed to
/// the focused window each time the focused window changes.
///
/// Silently no-ops when AX permission isn't granted (the underlying
/// `AXObserverCreate` returns `.apiDisabled`); a single warning is
/// emitted via `noteAXError`. Callers don't need to check
/// `isAccessibilityTrusted()` themselves — it's safe to always
/// `attach()` and rely on the watcher being a no-op if AX is off.
@MainActor
final class AXWatcher {
    private var observer: AXObserver?
    private var attachedPID: pid_t = 0
    private var watchedWindow: AXUIElement?
    private let onChange: @MainActor (String, AXUIElement) -> Void

    /// Monotonic counter of distinct focused-element shifts.
    /// Folded into `Controller.Snapshot` so `signalsEqual`
    /// detects tab switches even when the window title is stable
    /// across them — otherwise an active overrule never clears on
    /// `.window` triggers in that case.
    private(set) var focusEpoch: UInt64 = 0

    /// CFEqual baseline for `updateFocusEpoch`. Reset on
    /// `detach()` so the next attach's first focus event always
    /// registers as a shift.
    private var lastFocusedElement: AXUIElement?

    init(onChange: @escaping @MainActor (String, AXUIElement) -> Void) {
        self.onChange = onChange
    }

    func attach(pid: pid_t?) {
        guard let pid, pid > 0 else { detach(); return }
        guard pid != attachedPID else { return }
        detach()

        // Source is on the main runloop → callback fires on main;
        // `assumeIsolated` asserts the invariant.
        let callback: AXObserverCallback = { _, element, name, refcon in
            guard let refcon else { return }
            let notification = name as String
            MainActor.assumeIsolated {
                let me = Unmanaged<AXWatcher>.fromOpaque(refcon).takeUnretainedValue()
                if notification == (kAXFocusedWindowChangedNotification as String) {
                    me.refreshTitleSubscription(on: element)
                }
                me.updateFocusEpoch(notification: notification, element: element)
                me.onChange(notification, element)
            }
        }
        var obs: AXObserver?
        let status = AXObserverCreate(pid, callback, &obs)
        guard status == .success, let obs else {
            noteAXError(status)
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)
        var addStatus = AXObserverAddNotification(
            obs, appElement,
            kAXFocusedWindowChangedNotification as CFString,
            refcon,
        )
        if addStatus != .success { noteAXError(addStatus) }
        addStatus = AXObserverAddNotification(
            obs, appElement,
            kAXFocusedUIElementChangedNotification as CFString,
            refcon,
        )
        if addStatus != .success { noteAXError(addStatus) }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(obs),
            .commonModes,
        )

        observer = obs
        attachedPID = pid

        // Initial title-changed subscription on the currently focused
        // window — kAXFocusedWindowChangedNotification only fires on
        // *changes*, so we'd miss the starting window without this.
        var focusedRef: AnyObject?
        if AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &focusedRef,
        ) == .success, let focusedRef {
            refreshTitleSubscription(on: focusedRef as! AXUIElement)
        }
    }

    func detach() {
        if let obs = observer, let watched = watchedWindow {
            let removeStatus = AXObserverRemoveNotification(
                obs, watched, kAXTitleChangedNotification as CFString,
            )
            if removeStatus != .success { noteAXError(removeStatus) }
        }
        if let obs = observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(obs),
                .commonModes,
            )
        }
        observer = nil
        attachedPID = 0
        watchedWindow = nil
        lastFocusedElement = nil
    }

    /// Maintains `focusEpoch` and `lastFocusedElement`. Bumps
    /// only on real focus shifts so the Controller can distinguish
    /// "user moved focus" (tab switch, click into a different
    /// pane) from constant AX chatter during playback.
    private func updateFocusEpoch(notification: String, element: AXUIElement) {
        // Title-changed never counts: subtitle/timer elements fire
        // AXTitleChanged on the same focused element during
        // playback and would clear an active override every tick.
        guard notification == (kAXFocusedWindowChangedNotification as String)
            || notification == (kAXFocusedUIElementChangedNotification as String)
        else { return }
        // Same logical element re-reported (system re-fires the
        // notification without an actual shift) — skip.
        if let last = lastFocusedElement, CFEqual(last, element) { return }
        lastFocusedElement = element
        focusEpoch &+= 1
    }

    private func refreshTitleSubscription(on window: AXUIElement) {
        guard let obs = observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let old = watchedWindow {
            let removeStatus = AXObserverRemoveNotification(
                obs, old, kAXTitleChangedNotification as CFString,
            )
            if removeStatus != .success { noteAXError(removeStatus) }
        }
        let addStatus = AXObserverAddNotification(
            obs, window, kAXTitleChangedNotification as CFString, refcon,
        )
        if addStatus != .success { noteAXError(addStatus) }
        watchedWindow = window
    }
}
