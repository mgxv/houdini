// AXObserver subscription for focus and title changes. Fires
// `onChange(notificationName, element)` on the main actor for each
// `kAXFocusedWindowChanged` / `kAXFocusedUIElementChanged` /
// `kAXTitleChanged` notification, with the title-changed observer
// re-pointed each time the focused window changes. The on-demand
// title probe lives in `AccessibilityProbe.swift` and shares
// `noteAXError` for one-shot warning dedup.

import ApplicationServices
import Foundation

/// Subscribes to focus and title changes for a target app via AX.
///
/// Silently no-ops when AX permission isn't granted (the underlying
/// `AXObserverCreate` returns `.apiDisabled`); a single warning is
/// emitted via `noteAXError`. Callers don't need to check
/// `isAccessibilityTrusted()` themselves — it's safe to always
/// `attach()` and rely on the watcher being a no-op if AX is off.
@MainActor
final class AXWatcher {
    // MARK: State

    private var observer: AXObserver?
    private var attachedPID: pid_t = 0
    private var watchedWindow: AXUIElement?
    private let onChange: @MainActor (String, AXUIElement) -> Void

    /// Monotonic counter of distinct focused-element shifts.
    /// Folded into `Controller.Snapshot` so `signalsEqual`
    /// detects tab switches even when the window title is stable
    /// across them — otherwise the no-context `globalOverrule`
    /// fallback would never clear on `.window` triggers in that
    /// case. The per-tab `overrideMap` is keyed on the title, so
    /// a tab switch already moves it out of scope by key change.
    private(set) var axFocusEpoch: UInt64 = 0

    /// CFEqual baseline for `updateFocusEpoch`. Reset on
    /// `detach()` so the next attach's first focus event always
    /// registers as a shift.
    private var lastFocusedElement: AXUIElement?

    init(onChange: @escaping @MainActor (String, AXUIElement) -> Void) {
        self.onChange = onChange
    }

    // MARK: Attach / detach

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

    // MARK: Internal helpers

    /// Maintains `axFocusEpoch` and `lastFocusedElement`. Bumps
    /// only on real focus shifts so the Controller can distinguish
    /// "user moved focus" (tab switch, click into a different
    /// pane) from constant AX chatter during playback.
    private func updateFocusEpoch(notification: String, element: AXUIElement) {
        // Title-changed never counts: subtitle/timer elements fire
        // AXTitleChanged on the same focused element during
        // playback and would clear the `globalOverrule` fallback
        // every tick.
        guard notification == (kAXFocusedWindowChangedNotification as String)
            || notification == (kAXFocusedUIElementChangedNotification as String)
        else { return }
        // Same logical element re-reported (system re-fires the
        // notification without an actual shift) — skip.
        if let last = lastFocusedElement, CFEqual(last, element) { return }
        lastFocusedElement = element
        axFocusEpoch &+= 1
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
