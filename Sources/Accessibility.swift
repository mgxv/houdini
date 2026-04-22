// Cross-process Accessibility helpers. NSWindow's
// didEnter/didExitFullScreen only fires for windows in the host
// process, so we observe the frontmost app via AXObserver instead.
//
// The one AX constant whose read needs a @preconcurrency suppression
// (`kAXTrustedCheckOptionPrompt`) is accessed via
// `axTrustedCheckOptionPromptKey` in AXPromptKey.swift — keeping the
// suppression scoped to that one file so any future
// @preconcurrency-covered addition is grep-visible.

import ApplicationServices
import Foundation

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
    // AXUIElementCopyAttributeValue returns a CoreFoundation type and
    // the compiler guarantees this downcast always succeeds for CF types.
    return (w as! AXUIElement)
}

/// Watches the frontmost process for focus/resize/move events, which
/// is how native fullscreen toggles surface cross-process.
@MainActor
final class AXWatcher {
    private var observer: AXObserver?
    private var attachedPID: pid_t = 0
    private var watchedWindow: AXUIElement?
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    /// Subscribe to focus/resize/move events for the given process.
    /// Passing nil (or any invalid PID) detaches instead.
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

    /// Native fullscreen toggles surface as resize/move on the focused
    /// window, so re-subscribe every time focus changes.
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

/// Whether the focused window of the given process is in native
/// fullscreen. Reads the undocumented but stable `AXFullScreen`
/// attribute. Returns false for nil/invalid PIDs, apps with no focused
/// window, or when the attribute isn't available.
@MainActor
func isFocusedWindowFullScreen(pid: pid_t?) -> Bool {
    guard let window = focusedWindow(of: pid) else { return false }
    var ref: AnyObject?
    let status = AXUIElementCopyAttributeValue(
        window, "AXFullScreen" as CFString, &ref,
    )
    guard status == .success, let value = ref as? Bool else {
        noteAXError(status)
        return false
    }
    return value
}
