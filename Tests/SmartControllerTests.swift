// Drives SmartController with a recording MenuBarToggling and a mock
// FrontmostAppProvider for deterministic gate coverage.

@testable import houdini
import Testing

@MainActor
private final class RecordingMenuBar: MenuBarToggling {
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

@MainActor
private final class MockFrontmostProvider: FrontmostAppProvider {
    var frontmostApp: FrontmostInfo?
}

@Suite("SmartController")
@MainActor
struct SmartControllerTests {
    private static func makeController(
        frontmost: FrontmostInfo? = nil,
        reprime: (@MainActor () -> NowPlayingSnapshot?)? = nil,
    ) -> (SmartController, RecordingMenuBar, MockFrontmostProvider) {
        let bar = RecordingMenuBar()
        let provider = MockFrontmostProvider()
        provider.frontmostApp = frontmost
        let controller = SmartController(
            menuBar: bar, frontmostProvider: provider, nowPlayingReprime: reprime,
        )
        return (controller, bar, provider)
    }

    private static let fsEntry100 = DockSpaceEvent.fullScreenState(
        DockFullScreenState(isFullScreen: true, fsOwnerPID: FSOwnerPID(100)),
    )

    private static let fsExit = DockSpaceEvent.fullScreenState(
        DockFullScreenState(isFullScreen: false, fsOwnerPID: nil),
    )

    private static func playing(pid: Int32, parentBundle: String) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            playing: true,
            pid: NowPlayingPID(pid),
            bundle: parentBundle,
            parentBundle: parentBundle,
            title: "Track",
        )
    }

    // MARK: - Hotkey on Desktop

    @Test("Hotkey on Desktop is refused: no apply, overrule unchanged")
    func hotkeyOnDesktopRefused() {
        let (controller, bar, _) = Self.makeController()
        controller.toggleOverrule()
        #expect(controller.overrule == .auto)
        #expect(bar.calls.isEmpty)
    }

    // MARK: - Hotkey in FS

    @Test("Hotkey in FS sets overrule and applies")
    func hotkeyInFSPins() {
        let (controller, bar, _) = Self.makeController()
        controller.handleDockEvent(Self.fsEntry100)
        bar.calls.removeAll() // ignore the FS-entry apply

        controller.toggleOverrule()

        // Frontmost is nil → gate 3 trips → effective false → toggle pins forceHide.
        #expect(controller.overrule == .forceHide)
        #expect(bar.calls == [.apply(shouldHide: true, isFullScreen: true)])
    }

    // MARK: - Desktop arrival

    @Test("Desktop arrival clears active overrule and calls resetToVisible")
    func desktopArrivalClearsPin() {
        let (controller, bar, _) = Self.makeController()
        controller.handleDockEvent(Self.fsEntry100)
        controller.toggleOverrule()
        #expect(controller.overrule != .auto)
        bar.calls.removeAll()

        controller.handleDockEvent(.desktopArrival)

        #expect(controller.overrule == .auto)
        #expect(bar.calls == [.resetToVisible])
    }

    @Test("Desktop arrival with no active overrule: still resets, no apply")
    func desktopArrivalIdempotent() {
        let (controller, bar, _) = Self.makeController()

        controller.handleDockEvent(.desktopArrival)

        #expect(controller.overrule == .auto)
        #expect(bar.calls == [.resetToVisible])
    }

    // MARK: - Heartbeat dedup

    @Test("Same FS-state event twice: first applies, second is eval_skipped")
    func heartbeatDedup() {
        let (controller, bar, _) = Self.makeController()

        controller.handleDockEvent(Self.fsEntry100)
        let firstCount = bar.calls.count

        controller.handleDockEvent(Self.fsEntry100)

        #expect(bar.calls.count == firstCount)
    }

    @Test("FS exit applies with shouldHide=false (gate 1 trips, not_fullscreen)")
    func fsExitShowsBar() {
        let (controller, bar, _) = Self.makeController()
        controller.handleDockEvent(Self.fsEntry100)
        bar.calls.removeAll()

        controller.handleDockEvent(Self.fsExit)

        #expect(bar.calls == [.apply(shouldHide: false, isFullScreen: false)])
    }

    // MARK: - updateMedia plumbing

    @Test("updateMedia triggers an evaluation")
    func updateMediaTriggersEvaluate() {
        let (controller, bar, _) = Self.makeController()
        controller.handleDockEvent(Self.fsExit)
        bar.calls.removeAll()

        controller.updateMedia(Self.playing(pid: 200, parentBundle: "com.example.player"))

        #expect(bar.calls == [.apply(shouldHide: false, isFullScreen: false)])
    }

    // MARK: - Gate 5 (front_not_fs_owner)

    @Test("Gate 5: frontmost ≠ FS-owner → show(front_not_fs_owner)")
    func gate5FrontNotFsOwner() {
        // Untracked test pids make responsibility-pid resolution
        // return 0, so isSameApp correctly returns false.
        let (controller, bar, _) = Self.makeController(
            frontmost: FrontmostInfo(pid: 200, name: "Other", bundle: "com.other.App"),
        )
        controller.updateMedia(Self.playing(pid: 300, parentBundle: "com.np.App"))
        bar.calls.removeAll()

        controller.handleDockEvent(Self.fsEntry100)

        #expect(bar.calls == [.apply(shouldHide: false, isFullScreen: true)])
    }

    // MARK: - Gate 6 (app_mismatch)

    @Test("Gate 6: process AND bundle mismatch → show(app_mismatch)")
    func gate6AppMismatch() {
        let (controller, bar, _) = Self.makeController(
            frontmost: FrontmostInfo(pid: 200, name: "Front", bundle: "com.front.App"),
        )
        controller.updateMedia(Self.playing(pid: 300, parentBundle: "com.np.App"))
        bar.calls.removeAll()

        controller.handleDockEvent(.fullScreenState(
            DockFullScreenState(isFullScreen: true, fsOwnerPID: FSOwnerPID(200)),
        ))

        #expect(bar.calls == [.apply(shouldHide: false, isFullScreen: true)])
    }

    @Test("Gate 6: bundle match passes when process mismatches → hide")
    func gate6BundleMatchHides() {
        let (controller, bar, _) = Self.makeController(
            frontmost: FrontmostInfo(pid: 200, name: "App", bundle: "com.same.App"),
        )
        controller.updateMedia(Self.playing(pid: 300, parentBundle: "com.same.App"))
        bar.calls.removeAll()

        controller.handleDockEvent(.fullScreenState(
            DockFullScreenState(isFullScreen: true, fsOwnerPID: FSOwnerPID(200)),
        ))

        #expect(bar.calls == [.apply(shouldHide: true, isFullScreen: true)])
    }

    // MARK: - Wake re-prime

    @Test("Wake re-primes Now Playing the stream missed and hides")
    func wakeReprimesAndHides() {
        let reprimed = Self.playing(pid: 100, parentBundle: "com.same.App")
        let (controller, bar, _) = Self.makeController(
            frontmost: FrontmostInfo(pid: 100, name: "App", bundle: "com.same.App"),
            reprime: { reprimed },
        )
        // In FS, but the stream only ever delivered a paused snapshot.
        controller.handleDockEvent(Self.fsEntry100)
        controller.updateMedia(NowPlayingSnapshot(
            playing: false, pid: NowPlayingPID(100),
            bundle: "com.same.App", parentBundle: "com.same.App", title: "Track",
        ))
        #expect(bar.calls.last == .apply(shouldHide: false, isFullScreen: true))
        bar.calls.removeAll()

        // Wake: the one-shot get reports playback resumed → bar hides.
        controller.handleWake()

        #expect(bar.calls == [.apply(shouldHide: true, isFullScreen: true)])
    }

    @Test("Wake forces a re-assert even when nothing net-changed")
    func wakeForcesReassert() {
        let snapshot = Self.playing(pid: 100, parentBundle: "com.same.App")
        let (controller, bar, _) = Self.makeController(
            frontmost: FrontmostInfo(pid: 100, name: "App", bundle: "com.same.App"),
            reprime: { snapshot },
        )
        controller.updateMedia(snapshot)
        controller.handleDockEvent(Self.fsEntry100)
        #expect(bar.calls.last == .apply(shouldHide: true, isFullScreen: true))
        bar.calls.removeAll()

        // Identical state — without force this would be eval_skipped.
        controller.handleWake()

        #expect(bar.calls == [.apply(shouldHide: true, isFullScreen: true)])
    }

    // MARK: - Front-app change handler

    @Test("handleFrontAppChange refreshes the snapshot")
    func handleFrontAppChangeRefreshes() {
        let (controller, bar, provider) = Self.makeController(
            frontmost: FrontmostInfo(pid: 200, name: "Same", bundle: "com.same.App"),
        )
        controller.updateMedia(Self.playing(pid: 300, parentBundle: "com.same.App"))
        controller.handleDockEvent(.fullScreenState(
            DockFullScreenState(isFullScreen: true, fsOwnerPID: FSOwnerPID(200)),
        ))
        #expect(bar.calls.last == .apply(shouldHide: true, isFullScreen: true))
        bar.calls.removeAll()

        provider.frontmostApp = FrontmostInfo(
            pid: 999, name: "Other", bundle: "com.other.App",
        )
        controller.handleFrontAppChange()

        #expect(bar.calls == [.apply(shouldHide: false, isFullScreen: true)])
    }
}
