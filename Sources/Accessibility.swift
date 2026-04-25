// Cross-process Accessibility helpers. NSWindow's
// didEnter/didExitFullScreen only fires for windows in the host
// process, so we observe the frontmost app via AXObserver instead.
//
// The one AX constant whose read needs a @preconcurrency suppression
// (`kAXTrustedCheckOptionPrompt`) is accessed via
// `axTrustedCheckOptionPromptKey` in AXPromptKey.swift — keeping the
// suppression scoped to that one file so any future
// @preconcurrency-covered addition is grep-visible.
//
// Window enumeration uses two complementary lists. `kAXWindowsAttribute`
// returns every window an app owns, including windows in other spaces;
// `CGWindowListCopyWindowInfo(.optionOnScreenOnly, …)` returns only the
// windows currently visible on the active space. Bridging an AXUIElement
// back to its CGWindowID — required to intersect the two — uses the
// private `_AXUIElementGetWindow` declared below.

import ApplicationServices
import Foundation

/// Bridges an AX window element to its CGWindowID. Not in any public
/// SDK header, but exported by HIServices and stable since at least
/// 10.10; widely used by window-management tools. The `@_silgen_name`
/// binds this Swift wrapper to the C symbol, so we can pick any
/// readable Swift name without affecting the link.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(
    _ element: AXUIElement,
    _ windowID: UnsafeMutablePointer<CGWindowID>,
) -> AXError

/// Prompts the user to grant Accessibility permission if not already
/// granted. Exits on failure — nothing else works without it.
@MainActor
func ensureAccessibilityPermission() {
    if !AXIsProcessTrustedWithOptions([axTrustedCheckOptionPromptKey: true] as CFDictionary) {
        die("""
        Accessibility permission required.
        Open: System Settings → Privacy & Security → Accessibility
        Grant the binary (or parent terminal app, when run from a shell),
        quit and relaunch it, then re-run.
        """)
    }
}

/// Non-prompting Accessibility trust check. Unlike
/// `ensureAccessibilityPermission`, this never shows the system prompt
/// and never exits — it's used by read-only diagnostics like `status`.
/// Kept `nonisolated` so it's callable from any isolation; the underlying
/// syscall is thread-safe.
func isAccessibilityTrusted() -> Bool {
    AXIsProcessTrusted()
}

/// Latched after the first `AXError.apiDisabled` we observe at runtime,
/// so the warning is emitted once instead of on every evaluation tick.
/// `@MainActor`-isolated because every caller of `noteAXError` is —
/// that's what keeps the flag race-free without a lock.
@MainActor private var axPermissionLostReported = false

/// Emits a one-time warning if the given AX error signals that the
/// process is no longer trusted. Only `.apiDisabled` indicates
/// revocation — other failures (windowless apps, unresponsive targets,
/// unsupported attributes) are normal and must not trigger the warning.
@MainActor
private func noteAXError(_ error: AXError) {
    guard error == .apiDisabled, !axPermissionLostReported else { return }
    axPermissionLostReported = true
    warn("""
    Accessibility permission appears to have been revoked; fullscreen detection is disabled.
    Re-grant in System Settings → Privacy & Security → Accessibility, then run:
      brew services restart houdini
    """)
}

/// The currently focused window of the given process, if any.
/// Accepts `pid_t?` so callers that don't have a frontmost app can
/// pass nil and get nil back without a local guard.
@MainActor
func focusedWindow(of pid: pid_t?) -> AXUIElement? {
    guard let pid, pid > 0 else { return nil }
    var ref: AnyObject?
    let status = AXUIElementCopyAttributeValue(
        AXUIElementCreateApplication(pid),
        kAXFocusedWindowAttribute as CFString, &ref,
    )
    guard status == .success, let w = ref else {
        noteAXError(status)
        return nil
    }
    // `kAXFocusedWindowAttribute` is documented to return an
    // AXUIElementRef, so this CF→Swift bridge is always valid.
    return (w as! AXUIElement)
}

/// Watches the frontmost process for focus/resize/move events and for
/// window create/destroy. Native ⌃⌘F fullscreen toggles surface as
/// resize/move on the existing focused window; browser HTML5 fullscreen
/// (YouTube, Netflix, …) instead creates a *new* fullscreen window,
/// which only `kAXWindowCreatedNotification` reliably catches. The
/// matching `kAXUIElementDestroyedNotification` closes the symmetric
/// case on exit, when a fullscreen window is torn down without focus
/// shifting first. The latter is documented as element-specific but in
/// practice fires for descendants when subscribed on the application
/// element — relied on by Hammerspoon and similar AX-driven tooling.
@MainActor
final class AXWatcher {
    private var observer: AXObserver?
    private var attachedPID: pid_t = 0
    private var watchedWindow: AXUIElement?
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    /// Subscribe the AX observer to the wake-up notifications described
    /// in the class doc above — focused-window/main-window/window-created/
    /// ui-element-destroyed on the application element, plus resize/move
    /// on whatever window is currently focused. Passing nil (or any
    /// invalid PID) detaches instead.
    func attach(pid: pid_t?) {
        guard let pid, pid > 0 else { detach(); return }
        guard pid != attachedPID else { return }
        detach()

        guard let obs = makeObserver(for: pid) else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)

        AXObserverAddNotification(obs, appElement,
                                  kAXFocusedWindowChangedNotification as CFString,
                                  refcon)
        AXObserverAddNotification(obs, appElement,
                                  kAXMainWindowChangedNotification as CFString,
                                  refcon)
        AXObserverAddNotification(obs, appElement,
                                  kAXWindowCreatedNotification as CFString,
                                  refcon)
        AXObserverAddNotification(obs, appElement,
                                  kAXUIElementDestroyedNotification as CFString,
                                  refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(obs),
                           .commonModes)

        observer = obs
        attachedPID = pid
        refreshWindowSubscription()
    }

    func detach() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(obs),
                                  .commonModes)
        }
        observer = nil
        attachedPID = 0
        watchedWindow = nil
    }

    private func makeObserver(for pid: pid_t) -> AXObserver? {
        // The AX observer source is added to CFRunLoopGetMain(), so this
        // C callback is delivered on the main thread — just not statically
        // provable. `MainActor.assumeIsolated` asserts that invariant.
        let callback: AXObserverCallback = { _, _, name, refcon in
            guard let refcon else { return }
            MainActor.assumeIsolated {
                let me = Unmanaged<AXWatcher>.fromOpaque(refcon).takeUnretainedValue()
                if (name as String) == kAXFocusedWindowChangedNotification {
                    me.refreshWindowSubscription()
                }
                me.onChange()
            }
        }
        var newObs: AXObserver?
        let status = AXObserverCreate(pid, callback, &newObs)
        guard status == .success else {
            noteAXError(status)
            return nil
        }
        return newObs
    }

    /// Subscribe resize/move on the currently focused window, re-run
    /// on every focus change so we keep watching whatever window the
    /// user is interacting with. These are wake-up sources for
    /// `evaluate()` — they fire during a ⌃⌘F transition on the focused
    /// window, and during an HTML5-fullscreen animation once focus
    /// shifts to the newly created fullscreen window. The hide/show
    /// signal itself is computed in `isAppFullScreen`, which walks
    /// every on-screen window the app owns.
    private func refreshWindowSubscription() {
        guard let obs = observer, attachedPID > 0 else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        if let old = watchedWindow {
            AXObserverRemoveNotification(obs, old, kAXResizedNotification as CFString)
            AXObserverRemoveNotification(obs, old, kAXMovedNotification as CFString)
        }
        watchedWindow = nil

        guard let win = focusedWindow(of: attachedPID) else { return }
        AXObserverAddNotification(obs, win, kAXResizedNotification as CFString, refcon)
        AXObserverAddNotification(obs, win, kAXMovedNotification as CFString, refcon)
        watchedWindow = win
    }
}

/// Whether the given app currently presents a fullscreen window on the
/// active space. Walks every window the app owns (`kAXWindowsAttribute`),
/// keeps only those that appear in the on-screen window list (which
/// excludes windows in other spaces — see `onScreenWindowIDs` below),
/// and returns true if any of them reports `AXFullScreen=true`.
///
/// Replaces an earlier "is the *focused* window fullscreen?" check that
/// broke for browsers' HTML5 fullscreen: clicking a YouTube/Netflix
/// fullscreen button creates a separate fullscreen window alongside the
/// original tab window, and the AX-focused pointer oscillates between
/// the two even though the on-screen state is stable. Walking the right
/// set asks the right question and gives a stable answer.
///
/// Returns false for nil/invalid PIDs, when AX is disabled, or when the
/// app has no on-screen windows.
@MainActor
func isAppFullScreen(pid: pid_t?) -> Bool {
    guard let pid, pid > 0 else { return false }
    let app = AXUIElementCreateApplication(pid)

    var windowsRef: AnyObject?
    let status = AXUIElementCopyAttributeValue(
        app, kAXWindowsAttribute as CFString, &windowsRef,
    )
    guard status == .success, let windows = windowsRef as? [AXUIElement] else {
        noteAXError(status)
        return false
    }

    let onScreen = onScreenWindowIDs(pid: pid)
    if onScreen.isEmpty { return false }

    for window in windows {
        var cgID: CGWindowID = 0
        guard _AXUIElementGetWindow(window, &cgID) == .success,
              onScreen.contains(cgID)
        else {
            continue
        }

        var fsRef: AnyObject?
        let fsStatus = AXUIElementCopyAttributeValue(
            window, "AXFullScreen" as CFString, &fsRef,
        )
        if fsStatus == .success, (fsRef as? Bool) == true {
            return true
        }
        // Per-window failures here are normally `.attributeUnsupported`
        // for windows that don't expose AXFullScreen — harmless. Any
        // `.apiDisabled` would have surfaced on the kAXWindowsAttribute
        // read above, so we don't re-report it per-window.
    }
    return false
}

/// CGWindowIDs of `pid`'s windows currently visible on the active space.
/// `kCGWindowListOptionOnScreenOnly` is the whole point of this filter:
/// a fullscreen window in another space is *not* on-screen now, so it's
/// excluded — which is what prevents a fullscreen Safari in space B
/// from triggering hide while the user is using a windowed Safari in
/// space A.
@MainActor
private func onScreenWindowIDs(pid: pid_t) -> Set<CGWindowID> {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
        as? [[String: Any]]
    else {
        return []
    }
    var result = Set<CGWindowID>()
    for info in infos {
        guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
              ownerPID == pid,
              let number = info[kCGWindowNumber as String] as? CGWindowID
        else {
            continue
        }
        result.insert(number)
    }
    return result
}
