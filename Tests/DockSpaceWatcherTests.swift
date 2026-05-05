// Pin the parser against real captured Dock log lines. If a future
// macOS quietly changes the dock-visibility format these tests will
// fail loudly on the first CI run on the new runner image, instead
// of silently degrading the daemon's FS detection.

@testable import houdini
import Testing

@Suite("DockSpaceWatcher.parse")
struct DockSpaceWatcherTests {
    @Test("Solo fullscreen Space: extracts the tile pid + name")
    func soloFullScreen() {
        let line = """
        Space Forces Hidden: 1 <FullscreenSpace: 0xba6076bc0> \
        {uuid=57761582-1E7D-494C-9D70-579529282DFF fullscreen=true \
        space=CGSSpace(spid: 139)} \
        {tiles=[<TileSpace: 0x0000000ba681edc0> {orig-uuid= pid=4796 \
        appName=Ghostty name=~/Desktop space=CGSSpace(spid: 141)}]
        """
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(
                isFullScreen: true,
                fsOwnerPID: FSOwnerPID(4796),
                dockWindowTitle: "~/Desktop",
            )))
    }

    @Test("Split View: emits fullscreen=true with the first tile pid + name")
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
            == .fullScreenState(.init(
                isFullScreen: true,
                fsOwnerPID: FSOwnerPID(1738),
                dockWindowTitle: "YouTube",
            )))
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

    // MARK: - dockWindowTitle extraction

    @Test("Real-world Chrome line with curly apostrophe + audio emoji preserves the title verbatim")
    func realWorldChromeAudioEmoji() {
        let line =
            "Space Forces Hidden: 1 <FullscreenSpace: 0x7d98172c0> " +
            "{uuid=B76EDC77-20B6-49CA-A60D-D1D180C704B8 fullscreen=true " +
            "space=CGSSpace(spid: 383)} {tiles=[<TileSpace: 0x00000007d9243d80> " +
            "{orig-uuid= pid=4088 appName=Google Chrome " +
            "name=Walmart\u{2019}s New Plan to Defeat Amazon - YouTube \u{1F50A} " +
            "space=CGSSpace(spid: 385)}]"
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(
                isFullScreen: true,
                fsOwnerPID: FSOwnerPID(4088),
                dockWindowTitle:
                "Walmart\u{2019}s New Plan to Defeat Amazon - YouTube \u{1F50A}",
            )))
    }

    @Test("Missing name= field: dockWindowTitle is nil")
    func missingNameField() {
        let line = "Space Forces Hidden: 1 fullscreen=true pid=4088"
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(
                isFullScreen: true,
                fsOwnerPID: FSOwnerPID(4088),
                dockWindowTitle: nil,
            )))
    }

    @Test("Empty name= value: dockWindowTitle is nil")
    func emptyNameValue() {
        let line = "fullscreen=true pid=4088 appName=Foo name= space=CGSSpace(spid: 1)"
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(
                isFullScreen: true,
                fsOwnerPID: FSOwnerPID(4088),
                dockWindowTitle: nil,
            )))
    }

    @Test("FS exit line carries no dockWindowTitle even if a stray name= is present")
    func exitLineIgnoresName() {
        let line =
            "Space Forces Hidden: 0 fullscreen=false pid=36772 " +
            "name=stale space=CGSSpace(spid: 1)"
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(
                isFullScreen: false,
                fsOwnerPID: FSOwnerPID(36772),
                dockWindowTitle: nil,
            )))
    }

    @Test("Multi-tile picks the title for the first tile only")
    func multiTileFirstTileWins() {
        let line =
            "fullscreen=true {tiles=[<TileSpace> {orig-uuid= pid=1738 " +
            "appName=Google Chrome name=Tab A space=CGSSpace(spid: 305)}, " +
            "<TileSpace> {orig-uuid= pid=36772 appName=Safari " +
            "name=Tab B space=CGSSpace(spid: 398)}]"
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(
                isFullScreen: true,
                fsOwnerPID: FSOwnerPID(1738),
                dockWindowTitle: "Tab A",
            )))
    }

    @Test("appName= immediately before name= isn't mistaken for the title")
    func appNameNotMistakenForName() {
        let line =
            "fullscreen=true pid=4088 appName=Google Chrome " +
            "name=Title space=CGSSpace(spid: 1)"
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(
                isFullScreen: true,
                fsOwnerPID: FSOwnerPID(4088),
                dockWindowTitle: "Title",
            )))
    }

    @Test("Title with trimmable surrounding whitespace is trimmed")
    func titleTrimsWhitespace() {
        let line =
            "fullscreen=true pid=4088 appName=Foo " +
            "name=  Padded   space=CGSSpace(spid: 1)"
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(
                isFullScreen: true,
                fsOwnerPID: FSOwnerPID(4088),
                dockWindowTitle: "Padded",
            )))
    }

    // MARK: - Captured-fixture regression nets

    @Test("Captured shape: simple Netflix title (Chrome FS entry)")
    func capturedNetflix() {
        let line = """
        Space Forces Hidden: 1 <FullscreenSpace: 0x7d98171c0> \
        {uuid=2F6804D5-2EC5-4FD3-BA7D-7731FD3E31FE fullscreen=true \
        space=CGSSpace(spid: 512)} {tiles=[<TileSpace: 0x00000007d9243900> \
        {orig-uuid= pid=4088 appName=Google Chrome name=Netflix \
        space=CGSSpace(spid: 514)}]
        """
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(
                isFullScreen: true,
                fsOwnerPID: FSOwnerPID(4088),
                dockWindowTitle: "Netflix",
            )))
    }

    @Test("Captured shape: periods in title don't false-terminate")
    func capturedPeriodsInTitle() {
        let line = """
        Space Forces Hidden: 1 <FullscreenSpace: 0x7d9816200> \
        {uuid=F0A22BD5-1C1A-4AA1-B1B3-39EA9FA3240E fullscreen=true \
        space=CGSSpace(spid: 538)} {tiles=[<TileSpace: 0x00000007d9243900> \
        {orig-uuid= pid=4088 appName=Google Chrome \
        name=Amazon.com. Spend less. Smile more. \
        space=CGSSpace(spid: 540)}]
        """
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(
                isFullScreen: true,
                fsOwnerPID: FSOwnerPID(4088),
                dockWindowTitle: "Amazon.com. Spend less. Smile more.",
            )))
    }

    @Test("Captured shape: parens + middle-dot in title")
    func capturedParensAndMiddleDot() {
        let line = """
        Space Forces Hidden: 1 <FullscreenSpace: 0x7d9817300> \
        {uuid=36CF1F0D-F20C-4463-8597-3335583B262F fullscreen=true \
        space=CGSSpace(spid: 528)} {tiles=[<TileSpace: 0x00000007d9243900> \
        {orig-uuid= pid=4088 appName=Google Chrome \
        name=octocat (The Octocat) \u{00B7} GitHub \
        space=CGSSpace(spid: 530)}]
        """
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(
                isFullScreen: true,
                fsOwnerPID: FSOwnerPID(4088),
                dockWindowTitle: "octocat (The Octocat) \u{00B7} GitHub",
            )))
    }

    @Test("Captured shape: HBO Max title with backslash-escape annotations passes through verbatim")
    func capturedHBOEscapeAnnotations() {
        // `log stream` emits `\040` (octal space) and `\-h`/`\-i`/`\-f`
        // runs around HBO's web-title bytes; we preserve them as-is,
        // and gate 7 substring matching still works against the
        // human-readable content between the markers.
        let line = """
        Space Forces Hidden: 1 <FullscreenSpace: 0x7d98171c0> \
        {uuid=3D3CB549-EF75-401A-A175-BD884369F7FE fullscreen=true \
        space=CGSSpace(spid: 548)} {tiles=[<TileSpace: 0x00000007d9243900> \
        {orig-uuid= pid=4088 appName=Google Chrome \
        name=\\040\\-hKitty Likes to Dance\\040\\-i \u{2022} HBO Max \
        space=CGSSpace(spid: 550)}]
        """
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(
                isFullScreen: true,
                fsOwnerPID: FSOwnerPID(4088),
                dockWindowTitle:
                "\\040\\-hKitty Likes to Dance\\040\\-i \u{2022} HBO Max",
            )))
    }

    @Test("Captured shape: tilde + slash path in title (Ghostty FS)")
    func capturedTildePath() {
        let line = """
        Space Forces Hidden: 1 <FullscreenSpace: 0x7d9816200> \
        {uuid=8AD00B46-A78D-4217-82B5-83BF1FEFA6DE fullscreen=true \
        space=CGSSpace(spid: 553)} {tiles=[<TileSpace: 0x00000007d9243900> \
        {orig-uuid= pid=4514 appName=Ghostty name=~/Desktop/houdini \
        space=CGSSpace(spid: 555)}]
        """
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(
                isFullScreen: true,
                fsOwnerPID: FSOwnerPID(4514),
                dockWindowTitle: "~/Desktop/houdini",
            )))
    }

    @Test("Captured shape: title with embedded `=`, emoji, Korean, apostrophes")
    func capturedDiverseTitle() {
        // Real Safari capture. The embedded `=` (after `⚡️`) is the
        // critical pin: the parser keys off ` space=CGSSpace` for
        // termination, so any inline `=` inside the title must pass
        // through verbatim.
        let line = """
        Space Forces Hidden: 1 <FullscreenSpace: 0xcaed019c0> \
        {uuid=A7AC0B31-444F-47E2-98F7-1F9087CD337A fullscreen=true \
        space=CGSSpace(spid: 105)} {tiles=[<TileSpace: 0x0000000cae9eca20> \
        {orig-uuid= pid=19746 appName=Safari \
        name=[Pre-release] LISA's upgraded Thai dance\u{26A1}\u{FE0F}= 'Crab dance'\u{266A} (point. poker face\u{1F636}) Knowing bros EP.251 - YouTube \
        space=CGSSpace(spid: 107)}]
        """
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(
                isFullScreen: true,
                fsOwnerPID: FSOwnerPID(19746),
                dockWindowTitle:
                "[Pre-release] LISA's upgraded Thai dance\u{26A1}\u{FE0F}= 'Crab dance'\u{266A} (point. poker face\u{1F636}) Knowing bros EP.251 - YouTube",
            )))
    }

    @Test("Captured shape: name= equals appName= → fallback discarded")
    func capturedTitleEqualsAppName() {
        // `name=<appName>` is Dock's no-real-title fallback (Safari
        // FS re-entry race; also caught here on NordVPN). Discarded.
        // Doubles as the leading-space-rule pin — a broken `name=`
        // would mis-extract a non-nil value and fail this assertion.
        let line = """
        Space Forces Hidden: 1 <FullscreenSpace: 0x7d98171c0> \
        {uuid=DAC75C97-0D6F-4FC2-939A-7970265B1B48 fullscreen=true \
        space=CGSSpace(spid: 558)} {tiles=[<TileSpace: 0x00000007d9243900> \
        {orig-uuid= pid=4334 appName=NordVPN name=NordVPN \
        space=CGSSpace(spid: 560)}]
        """
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(
                isFullScreen: true,
                fsOwnerPID: FSOwnerPID(4334),
                dockWindowTitle: nil,
            )))
    }

    // MARK: - PID sanity

    @Test("pid=0 is rejected as the FS owner; title still extracts")
    func zeroPidRejected() {
        let line =
            "fullscreen=true {tiles=[<TileSpace> {orig-uuid= pid=0 " +
            "appName=Foo name=Bar space=CGSSpace(spid: 1)}]"
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(
                isFullScreen: true,
                fsOwnerPID: nil,
                dockWindowTitle: "Bar",
            )))
    }

    @Test("Multi-digit pids parse correctly")
    func multiDigitPids() {
        let line =
            "fullscreen=true {tiles=[<TileSpace> {orig-uuid= pid=123456 " +
            "appName=Foo name=Bar space=CGSSpace(spid: 1)}]"
        #expect(DockSpaceWatcher.parse(line)
            == .fullScreenState(.init(
                isFullScreen: true,
                fsOwnerPID: FSOwnerPID(123_456),
                dockWindowTitle: "Bar",
            )))
    }
}
