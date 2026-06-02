// Fixed-mode runtime: hotkey toggles the menu bar. No Dock log
// or MediaRemote subscriptions — those live in `SmartController`.
// Toggle state is not persisted across restarts.

import Foundation

@MainActor
final class FixedController {
    private let menuBar: MenuBarToggling
    private var isHidden: Bool = false

    private lazy var hotkeyWatcher = HotkeyWatcher { [weak self] in
        self?.toggle()
    }

    init(menuBar: MenuBarToggling) {
        self.menuBar = menuBar
    }

    func start() {
        HotkeyState.write(hotkeyWatcher.start() ? "registered" : "failed")
    }

    func stop() {
        hotkeyWatcher.stop()
        HotkeyState.clear()
    }

    private func toggle() {
        isHidden.toggle()
        menuBar.apply(shouldHide: isHidden, isFullScreen: true)
        let verb = isHidden ? "hide" : "show"
        Log.controller.info("→ \(verb, privacy: .public)  trig=hotkey mode=fixed")
    }
}
