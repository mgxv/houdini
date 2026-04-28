// Writes the "auto-hide menu bar in fullscreen" pref. Callers pass
// `shouldHide`; the pref stores the inverted `visible` polarity.
//
// Writing alone doesn't re-apply policy to an already-fullscreen
// window — the distributed notification is what tells SkyLight
// (WindowServer) to re-read. ControlCenterSettings.appex does the
// same after toggling the pref from System Settings.

import Foundation

@MainActor
final class MenuBarToggler {
    private static let key = "AppleMenuBarVisibleInFullscreen" as CFString
    private static let domain = kCFPreferencesAnyApplication
    private static let user = kCFPreferencesCurrentUser
    private static let host = kCFPreferencesAnyHost

    private static let changeNotification =
        Notification.Name("AppleInterfaceFullScreenMenuBarVisibilityChangedNotification")

    func apply(shouldHide: Bool) {
        write(visible: !shouldHide)
    }

    /// Used at startup and on graceful shutdown so the menu bar is
    /// never left hidden.
    func resetToVisible() {
        write(visible: true)
    }

    /// No in-process dedup: a cached "last written" value goes stale
    /// the moment the user toggles "Automatically hide and show the
    /// menu bar in full screen" in System Settings — we'd then skip
    /// a write that's actually needed. SkyLight no-ops same-value
    /// writes anyway, so re-applying every time is the simplest
    /// correct option.
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
    }
}
