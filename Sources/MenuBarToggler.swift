// Writes the "auto-hide menu bar in fullscreen" pref. Callers pass
// `shouldHide`; the pref stores the inverted `visible` polarity.
//
// Writing alone doesn't re-apply policy to an already-fullscreen
// window — the distributed notification is what tells SkyLight
// (WindowServer) to re-read. ControlCenterSettings.appex does the
// same after toggling the pref from System Settings.

import Foundation

@MainActor
protocol MenuBarToggler: AnyObject {
    func apply(shouldHide: Bool, isFullScreen: Bool)
    func resetToVisible()
}

@MainActor
final class MenuBarToggle: MenuBarToggler {
    private static let key = "AppleMenuBarVisibleInFullscreen" as CFString
    private static let domain = kCFPreferencesAnyApplication
    private static let user = kCFPreferencesCurrentUser
    private static let host = kCFPreferencesAnyHost

    private static let changeNotification =
        Notification.Name("AppleInterfaceFullScreenMenuBarVisibilityChangedNotification")

    func apply(shouldHide: Bool, isFullScreen: Bool) {
        guard isFullScreen else { return }
        write(visible: !shouldHide)
    }

    /// Used at startup and on graceful shutdown so the menu bar is
    /// never left hidden.
    func resetToVisible() {
        write(visible: true)
    }

    /// No in-process dedup here: a cached "last written" value goes
    /// stale the moment the user toggles "Automatically hide and
    /// show the menu bar in full screen" in System Settings — we'd
    /// then skip a write that's actually needed. Snapshot-level
    /// dedup in `SmartController.evaluate` collapses redundant calls
    /// before they reach this layer; SkyLight re-animates on each
    /// `DistributedNotification` post, so suppressing duplicate
    /// posts upstream is what prevents flicker.
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
