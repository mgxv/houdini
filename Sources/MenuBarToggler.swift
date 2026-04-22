// Writes the system "auto-hide menu bar in fullscreen" preference.
// The pref's *visible* polarity is the inverse of our shouldHide
// decision, so callers pass shouldHide and we invert.
//
// The pref write alone doesn't re-apply menu bar policy to a window
// that is already fullscreen. ControlCenterSettings.appex posts this
// same distributed notification right after writing, and SkyLight
// (WindowServer) re-reads.

import Foundation

@MainActor
final class MenuBarToggler {
    private static let key = "AppleMenuBarVisibleInFullscreen" as CFString
    private static let domain = kCFPreferencesAnyApplication
    private static let user = kCFPreferencesCurrentUser
    private static let host = kCFPreferencesAnyHost

    private static let changeNotification =
        Notification.Name("AppleInterfaceFullScreenMenuBarVisibilityChangedNotification")

    private var lastWritten: Bool?

    /// Writes the pref only if the effective value would change.
    func apply(shouldHide: Bool) {
        let visible = !shouldHide
        guard visible != lastWritten else { return }
        write(visible: visible)
    }

    /// Force always-visible. Used as startup baseline and on graceful
    /// shutdown so the menu bar is never left hidden.
    func resetToVisible() {
        write(visible: true)
    }

    private func write(visible: Bool) {
        CFPreferencesSetValue(
            Self.key, visible as CFBoolean,
            Self.domain, Self.user, Self.host,
        )
        CFPreferencesSynchronize(Self.domain, Self.user, Self.host)
        DistributedNotificationCenter.default().postNotificationName(
            Self.changeNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true,
        )
        lastWritten = visible
    }
}
