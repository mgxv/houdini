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
    )
}

@Suite("CurrentController")
@MainActor
struct CurrentControllerTests {
    private static func make(
        initialMode: Mode,
        modeReader: @escaping () -> Mode,
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
        )
        return (controller, bar, trace)
    }

    // MARK: - init + start

    @Test("init does not start ops; start() does")
    func initDoesNotStart() {
        let (controller, _, trace) = Self.make(initialMode: .smart, modeReader: { .smart })
        #expect(trace.events.isEmpty)

        controller.start()
        #expect(trace.events == ["smart:start"])
        #expect(controller.mode == .smart)
    }

    // MARK: - reload no-op

    @Test("reload with unchanged mode is a no-op (no stop, no start, no reset)")
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

    @Test("reload smart→fixed: stop old, reset bar, start new (in that order)")
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

        // Ordering invariant: stop → resetToVisible → start. Trace
        // captures the ops boundary; bar.calls captures the reset.
        #expect(trace.events == ["smart:stop", "fixed:start"])
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

        #expect(trace.events == ["fixed:stop", "smart:start"])
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

        #expect(trace.events == ["smart:stop", "fixed:start", "fixed:stop", "smart:start"])
        #expect(bar.calls == [.resetToVisible, .resetToVisible])
        #expect(controller.mode == .smart)
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
