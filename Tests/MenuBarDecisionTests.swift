// Pin the seven-gate decision policy. Every test starts from a
// "happy path" Inputs whose decision is .hide, mutates one field,
// and asserts the resulting outcome — so each test exercises one
// specific gate's pass/fail boundary.

@testable import houdini
import Testing

@Suite("menuBarDecision gates")
struct MenuBarDecisionTests {
    private struct Inputs {
        var dockFs = DockFullScreenState(isFullScreen: true, pid: 100)
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

    @Test("Gate 1: not fullscreen → SHOW(not_fullscreen)")
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

    @Test("Gate 2: not playing → SHOW(not_playing)")
    func gate2NotPlaying() {
        var i = Inputs()
        i.isPlaying = false
        #expect(i.decision == .showNotPlaying)
    }

    // MARK: - Gates 3 & 4: presence

    @Test("Gate 3: nil frontPID → SHOW(no_front_pid)")
    func gate3NoFrontPID() {
        var i = Inputs()
        i.frontPID = nil
        #expect(i.decision == .showNoFrontPid)
    }

    @Test("Gate 4: nil nowPlayingPID → SHOW(no_now_playing_pid)")
    func gate4NoNowPlayingPID() {
        var i = Inputs()
        i.nowPlayingPID = nil
        #expect(i.decision == .showNoNowPlayingPid)
    }

    // MARK: - Gates 5/6: FS-owner

    @Test("Gate 5: nil dockFs.pid → SHOW(front_not_fs_owner)")
    func gate5NilDockFsPID() {
        var i = Inputs()
        i.dockFs = .init(isFullScreen: true, pid: nil)
        #expect(i.decision == .showFrontNotFsOwner)
    }

    @Test("Gate 5: front PID doesn't resolve to FS-owner → SHOW(front_not_fs_owner)")
    func gate5FrontNotFsOwner() {
        var i = Inputs()
        i.frontPID = .init(100)
        i.dockFs = .init(isFullScreen: true, pid: 200)
        // Distinct bundles too, so isSameApp's fallback paths can't accidentally match.
        i.frontBundle = "com.front.App"
        i.nowPlayingParentBundle = "com.np.App"
        #expect(i.decision == .showFrontNotFsOwner)
    }

    @Test("Gate 5: identity match passes")
    func gate5IdentityPasses() {
        var i = Inputs()
        i.frontPID = .init(100)
        i.dockFs = .init(isFullScreen: true, pid: 100)
        #expect(i.decision == .hide)
    }

    // MARK: - Gate 7: same-app

    @Test("Gate 7: process AND bundle mismatch → SHOW(app_mismatch)")
    func gate7AppMismatch() {
        var i = Inputs()
        i.frontPID = .init(100)
        i.dockFs = .init(isFullScreen: true, pid: 100)
        i.nowPlayingPID = .init(200)
        i.frontBundle = "com.front.App"
        i.nowPlayingParentBundle = "com.np.App"
        #expect(i.decision == .showAppMismatch)
    }

    @Test("Gate 7: bundle match passes when process mismatches")
    func gate7BundleMatch() {
        var i = Inputs()
        i.frontPID = .init(100)
        i.dockFs = .init(isFullScreen: true, pid: 100)
        i.nowPlayingPID = .init(200)
        i.frontBundle = "com.same.App"
        i.nowPlayingParentBundle = "com.same.App"
        #expect(i.decision == .hide)
    }

    @Test("Gate 7: process match passes when bundle mismatches")
    func gate7ProcessMatch() {
        var i = Inputs()
        i.frontPID = .init(100)
        i.dockFs = .init(isFullScreen: true, pid: 100)
        i.nowPlayingPID = .init(100)
        i.frontBundle = "com.front.App"
        i.nowPlayingParentBundle = "com.np.App"
        #expect(i.decision == .hide)
    }

    @Test("Gate 7: empty parent bundle disables the bundle path")
    func gate7EmptyParentBundleNoBundleMatch() {
        var i = Inputs()
        i.frontPID = .init(100)
        i.dockFs = .init(isFullScreen: true, pid: 100)
        i.nowPlayingPID = .init(200)
        i.frontBundle = ""
        i.nowPlayingParentBundle = ""
        #expect(i.decision == .showAppMismatch)
    }

    // MARK: - Gate 8: window-title refinement

    @Test("Gate 8: title contains NP title → HIDE")
    func gate8TitleContains() {
        var i = Inputs()
        i.frontWindowTitle = "Track X — YouTube — Google Chrome"
        i.nowPlayingTitle = "Track X"
        #expect(i.decision == .hide)
    }

    @Test("Gate 8: title doesn't contain NP title → SHOW(window_mismatch)")
    func gate8TitleMismatch() {
        var i = Inputs()
        i.frontWindowTitle = "Settings — Google Chrome"
        i.nowPlayingTitle = "Track X"
        #expect(i.decision == .showWindowMismatch)
    }

    @Test("Gate 8: case-sensitive (intentional)")
    func gate8CaseSensitive() {
        var i = Inputs()
        i.frontWindowTitle = "TRACK X — App"
        i.nowPlayingTitle = "Track X"
        #expect(i.decision == .showWindowMismatch)
    }

    @Test("Gate 8: nil window title is lenient → HIDE")
    func gate8NilWindowTitleLenient() {
        var i = Inputs()
        i.frontWindowTitle = nil
        #expect(i.decision == .hide)
    }

    @Test("Gate 8: empty window title is lenient → HIDE")
    func gate8EmptyWindowTitleLenient() {
        var i = Inputs()
        i.frontWindowTitle = ""
        #expect(i.decision == .hide)
    }

    @Test("Gate 8: nil NP title is lenient → HIDE")
    func gate8NilNowPlayingTitleLenient() {
        var i = Inputs()
        i.nowPlayingTitle = nil
        #expect(i.decision == .hide)
    }

    @Test("Gate 8: empty NP title is lenient → HIDE")
    func gate8EmptyNowPlayingTitleLenient() {
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
