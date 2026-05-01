// Pin the seven-gate decision policy. Every test starts from a
// "happy path" Inputs whose decision is .hide, mutates one field,
// and asserts the resulting outcome — so each test exercises one
// specific gate's pass/fail boundary.

@testable import houdini
import Testing

@Suite("menuBarDecision gates")
struct MenuBarDecisionTests {
    private struct Inputs {
        var dockFs = DockFullScreenState(isFullScreen: true, pid: FSOwnerPID(100))
        var isPlaying = true
        var frontPID: FrontmostPID? = .init(100)
        var frontBundle: String? = "com.example.App"
        var frontWindowTitle: String? = "Track X — App"
        var nowPlayingPID: NowPlayingPID? = .init(100)
        var nowPlayingParentBundle: String? = "com.example.App"
        var nowPlayingTitle: String? = "Track X"

        var decision: MenuBarDecision {
            menuBarDecision(
                dockFs: dockFs,
                isPlaying: isPlaying,
                frontPID: frontPID,
                frontBundle: frontBundle,
                frontWindowTitle: frontWindowTitle,
                nowPlayingPID: nowPlayingPID,
                nowPlayingParentBundle: nowPlayingParentBundle,
                nowPlayingTitle: nowPlayingTitle,
            )
        }
    }

    @Test("Hide when every gate passes")
    func happyPathHides() {
        #expect(Inputs().decision == .hide)
    }

    // MARK: - Gate 1: fullscreen

    @Test("Gate 1: not fullscreen → show(not_fullscreen)")
    func gate1NotFullScreen() {
        var i = Inputs()
        i.dockFs = .init(isFullScreen: false, pid: nil)
        #expect(i.decision == .showNotFullScreen)
    }

    @Test("Gate 1 short-circuits earlier failures")
    func gate1TakesPrecedence() {
        var i = Inputs()
        i.dockFs = .init(isFullScreen: false, pid: nil)
        i.isPlaying = false
        i.frontPID = nil
        #expect(i.decision == .showNotFullScreen)
    }

    // MARK: - Gate 2: playing

    @Test("Gate 2: not playing → show(not_playing)")
    func gate2NotPlaying() {
        var i = Inputs()
        i.isPlaying = false
        #expect(i.decision == .showNotPlaying)
    }

    // MARK: - Gates 3 & 4: presence

    @Test("Gate 3: nil frontPID → show(no_front_pid)")
    func gate3NoFrontPID() {
        var i = Inputs()
        i.frontPID = nil
        #expect(i.decision == .showNoFrontPid)
    }

    @Test("Gate 4: nil nowPlayingPID → show(no_now_playing_pid)")
    func gate4NoNowPlayingPID() {
        var i = Inputs()
        i.nowPlayingPID = nil
        #expect(i.decision == .showNoNowPlayingPid)
    }

    // MARK: - Gate 5: FS-owner

    @Test("Gate 5: nil dockFs.pid → show(front_not_fs_owner)")
    func gate5NilDockFsPID() {
        var i = Inputs()
        i.dockFs = .init(isFullScreen: true, pid: nil)
        #expect(i.decision == .showFrontNotFsOwner)
    }

    @Test("Gate 5: front PID doesn't resolve to FS-owner → show(front_not_fs_owner)")
    func gate5FrontNotFsOwner() {
        var i = Inputs()
        i.frontPID = .init(100)
        i.dockFs = .init(isFullScreen: true, pid: FSOwnerPID(200))
        // Distinct bundles too, so isSameApp's fallback paths can't accidentally match.
        i.frontBundle = "com.front.App"
        i.nowPlayingParentBundle = "com.np.App"
        #expect(i.decision == .showFrontNotFsOwner)
    }

    @Test("Gate 5: identity match passes")
    func gate5IdentityPasses() {
        var i = Inputs()
        i.frontPID = .init(100)
        i.dockFs = .init(isFullScreen: true, pid: FSOwnerPID(100))
        #expect(i.decision == .hide)
    }

    // MARK: - Gate 6: same-app

    @Test("Gate 6: process AND bundle mismatch → show(app_mismatch)")
    func gate6AppMismatch() {
        var i = Inputs()
        i.frontPID = .init(100)
        i.dockFs = .init(isFullScreen: true, pid: FSOwnerPID(100))
        i.nowPlayingPID = .init(200)
        i.frontBundle = "com.front.App"
        i.nowPlayingParentBundle = "com.np.App"
        #expect(i.decision == .showAppMismatch)
    }

    @Test("Gate 6: bundle match passes when process mismatches")
    func gate6BundleMatch() {
        var i = Inputs()
        i.frontPID = .init(100)
        i.dockFs = .init(isFullScreen: true, pid: FSOwnerPID(100))
        i.nowPlayingPID = .init(200)
        i.frontBundle = "com.same.App"
        i.nowPlayingParentBundle = "com.same.App"
        #expect(i.decision == .hide)
    }

    @Test("Gate 6: process match passes when bundle mismatches")
    func gate6ProcessMatch() {
        var i = Inputs()
        i.frontPID = .init(100)
        i.dockFs = .init(isFullScreen: true, pid: FSOwnerPID(100))
        i.nowPlayingPID = .init(100)
        i.frontBundle = "com.front.App"
        i.nowPlayingParentBundle = "com.np.App"
        #expect(i.decision == .hide)
    }

    @Test("Gate 6: empty parent bundle disables the bundle path")
    func gate6EmptyParentBundleNoBundleMatch() {
        var i = Inputs()
        i.frontPID = .init(100)
        i.dockFs = .init(isFullScreen: true, pid: FSOwnerPID(100))
        i.nowPlayingPID = .init(200)
        i.frontBundle = ""
        i.nowPlayingParentBundle = ""
        #expect(i.decision == .showAppMismatch)
    }

    // MARK: - Gate 7: window-title refinement

    @Test("Gate 7: title contains NP title → hide")
    func gate7TitleContains() {
        var i = Inputs()
        i.frontWindowTitle = "Track X — YouTube — Google Chrome"
        i.nowPlayingTitle = "Track X"
        #expect(i.decision == .hide)
    }

    @Test("Gate 7: title doesn't contain NP title → show(window_mismatch)")
    func gate7TitleMismatch() {
        var i = Inputs()
        i.frontWindowTitle = "Settings — Google Chrome"
        i.nowPlayingTitle = "Track X"
        #expect(i.decision == .showWindowMismatch)
    }

    @Test("Gate 7: case-sensitive (intentional)")
    func gate7CaseSensitive() {
        var i = Inputs()
        i.frontWindowTitle = "TRACK X — App"
        i.nowPlayingTitle = "Track X"
        #expect(i.decision == .showWindowMismatch)
    }

    @Test("Gate 7: nil window title is lenient → hide")
    func gate7NilWindowTitleLenient() {
        var i = Inputs()
        i.frontWindowTitle = nil
        #expect(i.decision == .hide)
    }

    @Test("Gate 7: empty window title (probe-confirmed) → show(window_mismatch)")
    func gate7EmptyWindowTitleStrict() {
        var i = Inputs()
        i.frontWindowTitle = ""
        #expect(i.decision == .showWindowMismatch)
    }

    @Test("Gate 7: nil NP title is lenient → hide")
    func gate7NilNowPlayingTitleLenient() {
        var i = Inputs()
        i.nowPlayingTitle = nil
        #expect(i.decision == .hide)
    }

    @Test("Gate 7: empty NP title is lenient → hide")
    func gate7EmptyNowPlayingTitleLenient() {
        var i = Inputs()
        i.nowPlayingTitle = ""
        #expect(i.decision == .hide)
    }

    // MARK: - Ordering

    @Test("Earlier gate failures take precedence over later ones")
    func gateOrdering() {
        var i = Inputs()
        i.isPlaying = false
        i.frontPID = nil
        // Both gate 2 and gate 3 would fail; gate 2 reports first.
        #expect(i.decision == .showNotPlaying)
    }
}
