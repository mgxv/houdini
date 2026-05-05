// Fixed-mode runtime: hotkey toggles the menu bar. No Dock log,
// AX, or MediaRemote subscriptions — those live in `SmartController`.
// Toggle state is not persisted across restarts.

import Foundation

@MainActor
final class FixedController {
    private let menuBar: MenuBarToggler
    private var isHidden: Bool = false

    private lazy var hotkeyWatcher = HotkeyWatcher { [weak self] in
        self?.toggle()
    }

    init(menuBar: MenuBarToggler) {
        self.menuBar = menuBar
    }

    /// Writes `HotkeyState` + `AccessibilityState` so `houdini status`
    /// reports the same fields as smart mode. AX is informational only.
    func start() {
        AccessibilityState.write(isAccessibilityTrusted() ? "granted" : "denied")
        HotkeyState.write(hotkeyWatcher.start() ? "registered" : "failed")
    }

    func stop() {
        hotkeyWatcher.stop()
        HotkeyState.clear()
        AccessibilityState.clear()
    }

    private func toggle() {
        isHidden.toggle()
        menuBar.apply(shouldHide: isHidden)
        let verb = isHidden ? "hide" : "show"
        Log.controller.info("→ \(verb, privacy: .public)  trig=hotkey mode=fixed")
    }
}
