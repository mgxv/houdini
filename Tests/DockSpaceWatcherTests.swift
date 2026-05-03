// Pin the parser against real captured Dock log lines. If a future
// macOS quietly changes the dock-visibility format these tests will
// fail loudly on the first CI run on the new runner image, instead
// of silently degrading the daemon's FS detection.

@testable import houdini
import Testing

@Suite("DockSpaceWatcher.parse")
struct DockSpaceWatcherTests {
    @Test("Solo fullscreen Space: extracts the tile pid")
    func soloFullScreen() {
        let line = """
        Space Forces Hidden: 1 <FullscreenSpace: 0xba6076bc0> \
        {uuid=57761582-1E7D-494C-9D70-579529282DFF fullscreen=true \
        space=CGSSpace(spid: 139)} \
        {tiles=[<TileSpace: 0x0000000ba681edc0> {orig-uuid= pid=4796 \
        appName=Ghostty name=~/Desktop space=CGSSpace(spid: 141)}]
        """
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(isFullScreen: true, fsOwnerPID: FSOwnerPID(4796))))
    }

    @Test("Split View: emits fullscreen=true with the first tile pid")
    func splitView() {
        let line = """
        Space Forces Hidden: 1 <FullscreenSpace: 0xba680c980> \
        {uuid=22625E57-2B3F-43C2-8DE3-0923FDA25877 fullscreen=true \
        space=CGSSpace(spid: 303)} \
        {tiles=[<TileSpace: 0x0000000ba6a79aa0> {orig-uuid= pid=1738 \
        appName=Google Chrome name=YouTube space=CGSSpace(spid: 305)}, \
        <TileSpace: 0x0000000ba6a78c00> {orig-uuid= pid=36772 \
        appName=Safari name=YouTube space=CGSSpace(spid: 398)}]
        """
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(isFullScreen: true, fsOwnerPID: FSOwnerPID(1738))))
    }

    @Test("Exit fullscreen: ManagedSpace line → fullscreen=false, no pid")
    func exitFullScreen() {
        let line = """
        Space Forces Hidden: 0 <ManagedSpace: 0xba696d500> \
        {uuid= fullscreen=false space=CGSSpace(spid: 1)}
        """
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(isFullScreen: false, fsOwnerPID: nil)))
    }

    @Test("Exit message that happens to carry a pid: extracts it")
    func exitWithPid() {
        // Captured in the wild: some exit messages do carry a pid.
        let line = "Space Forces Hidden: 0 fullscreen=false pid=36772"
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(isFullScreen: false, fsOwnerPID: FSOwnerPID(36772))))
    }

    @Test("Stay-space-change: maps to .staySpaceChange")
    func staySpaceChange() {
        let line = "Skipping no-op state update, state=1, hiddenDockMode=0"
        #expect(DockSpaceWatcher.parse(line) == .staySpaceChange)
    }

    @Test("Unrelated lines: return nil")
    func unrelatedLinesReturnNil() {
        #expect(DockSpaceWatcher.parse("Dock: Visible") == nil)
        #expect(DockSpaceWatcher.parse("Autohide Pref Value: 0") == nil)
        #expect(DockSpaceWatcher.parse("") == nil)
    }

    @Test("`spid:` with colon doesn't match the pid regex")
    func spidColonDoesNotMatch() {
        // Dock currently uses `spid: N` (colon). The parser's
        // `\bpid=\d+` regex requires `=`, so the space-id never
        // contaminates the pid extraction.
        let line = "fullscreen=true space=CGSSpace(spid: 139)"
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(isFullScreen: true, fsOwnerPID: nil)))
    }

    @Test("Defensive: `spid=` with equals doesn't match either")
    func spidEqualsDoesNotMatch() {
        // Hypothetical future format. The `\b` word boundary in the
        // regex means `spid=139` shouldn't be picked up as `pid=139`.
        let line = "fullscreen=true spid=139"
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(isFullScreen: true, fsOwnerPID: nil)))
    }
}
