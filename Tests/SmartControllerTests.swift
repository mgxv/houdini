// Drives SmartController via a recording MenuBarToggler mock.
// Avoids gates 5/6 (which read NSWorkspace.frontmostApplication) by
// using non-FS state or overrule pins.

@testable import houdini
import Testing

@MainActor
private final class RecordingMenuBar: MenuBarToggler {
    enum Call: Equatable {
        case apply(shouldHide: Bool, isFullScreen: Bool)
        case resetToVisible
    }

    var calls: [Call] = []

    func apply(shouldHide: Bool, isFullScreen: Bool) {
        calls.append(.apply(shouldHide: shouldHide, isFullScreen: isFullScreen))
    }

    func resetToVisible() {
        calls.append(.resetToVisible)
    }
}

@Suite("SmartController")
@MainActor
struct SmartControllerTests {
    private static let fsEntry = DockSpaceEvent.fullScreenState(
        DockFullScreenState(isFullScreen: true, fsOwnerPID: FSOwnerPID(100)),
    )

    private static let fsExit = DockSpaceEvent.fullScreenState(
        DockFullScreenState(isFullScreen: false, fsOwnerPID: nil),
    )

    // MARK: - Hotkey on Desktop

    @Test("Hotkey on Desktop is refused: no apply, overrule unchanged")
    func hotkeyOnDesktopRefused() {
        let bar = RecordingMenuBar()
        let controller = SmartController(menuBar: bar)
        // Initial state: dockFs.isFullScreen=false (no FS event sent).
        controller.toggleOverrule()
        #expect(controller.overrule == .auto)
        #expect(bar.calls.isEmpty)
    }

    // MARK: - Hotkey in FS

    @Test("Hotkey in FS sets overrule and applies")
    func hotkeyInFSPins() {
        let bar = RecordingMenuBar()
        let controller = SmartController(menuBar: bar)
        controller.handleDockEvent(Self.fsEntry)
        bar.calls.removeAll() // ignore the FS-entry apply

        controller.toggleOverrule()

        // FS gates 5/6 likely fail (frontmost app isn't pid 100), so
        // pre-pin effective is "show" → toggle pins to forceHide.
        #expect(controller.overrule == .forceHide)
        // Apply emitted with isFullScreen=true (the snapshot's dockFs).
        #expect(bar.calls == [.apply(shouldHide: true, isFullScreen: true)])
    }

    // MARK: - Desktop arrival

    @Test("Desktop arrival clears active overrule and calls resetToVisible")
    func desktopArrivalClearsPin() {
        let bar = RecordingMenuBar()
        let controller = SmartController(menuBar: bar)
        controller.handleDockEvent(Self.fsEntry)
        controller.toggleOverrule() // pin while in FS
        #expect(controller.overrule != .auto)
        bar.calls.removeAll()

        controller.handleDockEvent(.desktopArrival)

        #expect(controller.overrule == .auto)
        #expect(bar.calls == [.resetToVisible])
    }

    @Test("Desktop arrival with no active overrule: still resets, no apply")
    func desktopArrivalIdempotent() {
        let bar = RecordingMenuBar()
        let controller = SmartController(menuBar: bar)
        // Never pinned; overrule starts at .auto.

        controller.handleDockEvent(.desktopArrival)

        #expect(controller.overrule == .auto)
        #expect(bar.calls == [.resetToVisible])
    }

    // MARK: - Heartbeat dedup

    @Test("Same FS-state event twice: first applies, second is eval_skipped")
    func heartbeatDedup() {
        let bar = RecordingMenuBar()
        let controller = SmartController(menuBar: bar)

        controller.handleDockEvent(Self.fsEntry)
        let firstCount = bar.calls.count

        controller.handleDockEvent(Self.fsEntry)

        // Second event was a no-op (snap == last → eval_skipped).
        #expect(bar.calls.count == firstCount)
    }

    @Test("FS exit applies with shouldHide=false (gate 1 trips, not_fullscreen)")
    func fsExitShowsBar() {
        let bar = RecordingMenuBar()
        let controller = SmartController(menuBar: bar)
        controller.handleDockEvent(Self.fsEntry)
        bar.calls.removeAll()

        controller.handleDockEvent(Self.fsExit)

        // Gate 1 (not_fullscreen) → effective false → apply(false).
        // isFullScreen passed to apply is the snapshot's value: false.
        #expect(bar.calls == [.apply(shouldHide: false, isFullScreen: false)])
    }

    // MARK: - updateMedia plumbing

    @Test("updateMedia triggers an evaluation")
    func updateMediaTriggersEvaluate() {
        let bar = RecordingMenuBar()
        let controller = SmartController(menuBar: bar)
        // Send an initial event to populate lastSnapshot so the
        // updateMedia call below is a real delta, not the first.
        controller.handleDockEvent(Self.fsExit)
        bar.calls.removeAll()

        controller.updateMedia(NowPlayingSnapshot(
            playing: true,
            pid: NowPlayingPID(200),
            bundle: "com.example.player",
            parentBundle: "com.example.player",
            title: "Track A",
        ))

        // dockFs.isFullScreen=false, so even with playing=true the
        // decision is .showNotFullScreen → apply(false).
        #expect(bar.calls == [.apply(shouldHide: false, isFullScreen: false)])
    }
}
