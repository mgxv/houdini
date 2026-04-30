// Pin the overrule policy: `.forceHide` / `.forceShow` win
// unconditionally, `.auto` defers to the gate decision. The free
// function is the testable seam for `Controller.Snapshot.effectiveShouldHide`.

@testable import houdini
import Testing

@Suite("effectiveShouldHide")
struct EffectiveShouldHideTests {
    // MARK: - .auto follows the decision

    @Test("auto + .hide → true")
    func autoHide() {
        #expect(effectiveShouldHide(decision: .hide, overrule: .auto) == true)
    }

    @Test("auto + every show(...) → false")
    func autoShowAll() {
        let showDecisions: [MenuBarDecision] = [
            .showNotFullScreen,
            .showNotPlaying,
            .showNoFrontPid,
            .showNoNowPlayingPid,
            .showFrontNotFsOwner,
            .showAppMismatch,
            .showWindowMismatch,
        ]
        for d in showDecisions {
            #expect(
                effectiveShouldHide(decision: d, overrule: .auto) == false,
                "auto should defer to .shouldHide for \(d.tag)",
            )
        }
    }

    // MARK: - .forceHide overrides any decision

    @Test("forceHide + .hide → true")
    func forceHideAlreadyHide() {
        #expect(effectiveShouldHide(decision: .hide, overrule: .forceHide) == true)
    }

    @Test("forceHide + show(...) → true (overrides)")
    func forceHideOverridesShow() {
        let showDecisions: [MenuBarDecision] = [
            .showNotFullScreen,
            .showNotPlaying,
            .showWindowMismatch,
        ]
        for d in showDecisions {
            #expect(
                effectiveShouldHide(decision: d, overrule: .forceHide) == true,
                "forceHide should override \(d.tag)",
            )
        }
    }

    // MARK: - .forceShow overrides any decision

    @Test("forceShow + .hide → false (overrides)")
    func forceShowOverridesHide() {
        #expect(effectiveShouldHide(decision: .hide, overrule: .forceShow) == false)
    }

    @Test("forceShow + show(...) → false")
    func forceShowAlreadyShow() {
        #expect(
            effectiveShouldHide(decision: .showAppMismatch, overrule: .forceShow) == false,
        )
    }
}
