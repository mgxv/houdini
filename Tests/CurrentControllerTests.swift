// Pin the controller-swap behavior of CurrentController via injected
// opsFactory + modeReader, so no subprocess or hotkey is touched.

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

@MainActor
private final class Trace {
    var events: [String] = []
}

@MainActor
private func recordingOps(for mode: Mode, trace: Trace) -> ControllerOps {
    ControllerOps(
        start: { trace.events.append("\(mode.rawValue):start") },
        stop: { trace.events.append("\(mode.rawValue):stop") },
        updateOverrides: { overrides in
            trace.events.append("\(mode.rawValue):overrides(\(overrides.deny.count))")
        },
    )
}

@Suite("CurrentController")
@MainActor
struct CurrentControllerTests {
    private static func make(
        initialMode: Mode,
        modeReader: @escaping () -> Mode,
        overridesReader: @escaping () -> AppOverrides = { .empty },
    ) -> (CurrentController, RecordingMenuBar, Trace) {
        let trace = Trace()
        let bar = RecordingMenuBar()
        let opsFactory: @MainActor (Mode, MenuBarToggler) -> ControllerOps = { mode, _ in
            recordingOps(for: mode, trace: trace)
        }
        let controller = CurrentController(
            mode: initialMode,
            menuBar: bar,
            opsFactory: opsFactory,
            modeReader: modeReader,
            overridesReader: overridesReader,
        )
        return (controller, bar, trace)
    }

    // MARK: - init + start

    @Test("init does not start ops; start() does and pushes initial overrides")
    func initDoesNotStart() {
        let (controller, _, trace) = Self.make(initialMode: .smart, modeReader: { .smart })
        #expect(trace.events.isEmpty)

        controller.start()
        #expect(trace.events == ["smart:start", "smart:overrides(0)"])
        #expect(controller.mode == .smart)
    }

    // MARK: - reload no-op

    @Test("reload with unchanged mode and overrides is a no-op")
    func reloadSameModeIsNoOp() {
        let (controller, bar, trace) = Self.make(initialMode: .smart, modeReader: { .smart })
        controller.start()
        let baseline = trace.events
        let barBaseline = bar.calls

        controller.reload()

        #expect(trace.events == baseline)
        #expect(bar.calls == barBaseline)
        #expect(controller.mode == .smart)
    }

    // MARK: - reload swap

    @Test("reload smart→fixed: stop old, reset bar, start new + push overrides")
    func reloadSmartToFixed() {
        var current: Mode = .smart
        let (controller, bar, trace) = Self.make(
            initialMode: .smart,
            modeReader: { current },
        )
        controller.start()
        bar.calls.removeAll()
        trace.events.removeAll()

        current = .fixed
        controller.reload()

        // Ordering: stop → resetToVisible → start → updateOverrides.
        #expect(trace.events == ["smart:stop", "fixed:start", "fixed:overrides(0)"])
        #expect(bar.calls == [.resetToVisible])
        #expect(controller.mode == .fixed)
    }

    @Test("reload fixed→smart: same swap shape in the other direction")
    func reloadFixedToSmart() {
        var current: Mode = .fixed
        let (controller, bar, trace) = Self.make(
            initialMode: .fixed,
            modeReader: { current },
        )
        controller.start()
        bar.calls.removeAll()
        trace.events.removeAll()

        current = .smart
        controller.reload()

        #expect(trace.events == ["fixed:stop", "smart:start", "smart:overrides(0)"])
        #expect(bar.calls == [.resetToVisible])
        #expect(controller.mode == .smart)
    }

    @Test("Two reloads back-to-back: each produces a clean swap")
    func twoReloads() {
        var current: Mode = .smart
        let (controller, bar, trace) = Self.make(
            initialMode: .smart,
            modeReader: { current },
        )
        controller.start()
        bar.calls.removeAll()
        trace.events.removeAll()

        current = .fixed
        controller.reload()
        current = .smart
        controller.reload()

        #expect(trace.events == [
            "smart:stop", "fixed:start", "fixed:overrides(0)",
            "fixed:stop", "smart:start", "smart:overrides(0)",
        ])
        #expect(bar.calls == [.resetToVisible, .resetToVisible])
        #expect(controller.mode == .smart)
    }

    // MARK: - reload with overrides change

    @Test("reload with overrides-only change pushes overrides without rebuilding")
    func reloadOverridesOnly() {
        var overrides: AppOverrides = .empty
        let (controller, bar, trace) = Self.make(
            initialMode: .smart,
            modeReader: { .smart },
            overridesReader: { overrides },
        )
        controller.start()
        bar.calls.removeAll()
        trace.events.removeAll()

        overrides = AppOverrides(deny: ["com.spotify.client"])
        controller.reload()

        // No stop/start — only updateOverrides, with the new count.
        #expect(trace.events == ["smart:overrides(1)"])
        #expect(bar.calls.isEmpty)
        #expect(controller.mode == .smart)
    }

    @Test("reload with same overrides set is a no-op")
    func reloadSameOverridesIsNoOp() {
        let pinned = AppOverrides(deny: ["com.spotify.client"])
        let (controller, _, trace) = Self.make(
            initialMode: .smart,
            modeReader: { .smart },
            overridesReader: { pinned },
        )
        controller.start()
        let baseline = trace.events

        controller.reload()

        #expect(trace.events == baseline)
    }

    // MARK: - shutdown

    @Test("shutdown stops ops and resets the bar")
    func shutdown() {
        let (controller, bar, trace) = Self.make(initialMode: .smart, modeReader: { .smart })
        controller.start()
        bar.calls.removeAll()
        trace.events.removeAll()

        controller.shutdown()

        #expect(trace.events == ["smart:stop"])
        #expect(bar.calls == [.resetToVisible])
    }
}
