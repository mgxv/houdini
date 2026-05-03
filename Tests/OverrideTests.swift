// Pin the per-tab override key + window-title normalizer that back
// the sticky `overrideMap` in Controller. Decision-gate semantics
// are pinned by MenuBarDecisionTests; these cases cover only the
// keying/normalization helpers.

@testable import houdini
import Testing

@Suite("normalizeWindowTitle")
struct NormalizeWindowTitleTests {
    @Test("Strips trailing ' - Audio playing'")
    func stripsAudioPlaying() {
        #expect(
            normalizeWindowTitle("Euphoria - HBO Max - Audio playing - Google Chrome - John Doe")
                == "Euphoria - HBO Max - Google Chrome - John Doe",
        )
    }

    @Test("Strips trailing ' - Audio muted'")
    func stripsAudioMuted() {
        #expect(
            normalizeWindowTitle("Page - Audio muted - Google Chrome")
                == "Page - Google Chrome",
        )
    }

    @Test("Strips leading '(N) ' notification counter")
    func stripsNotificationPrefix() {
        #expect(
            normalizeWindowTitle("(3) Inbox - Gmail - Google Chrome")
                == "Inbox - Gmail - Google Chrome",
        )
    }

    @Test("Strips counter and audio annotation together")
    func stripsBoth() {
        #expect(
            normalizeWindowTitle("(12) Track - Audio playing - Google Chrome")
                == "Track - Google Chrome",
        )
    }

    @Test("Trims whitespace at the boundaries")
    func trimsWhitespace() {
        #expect(normalizeWindowTitle("  Page Title  ") == "Page Title")
    }

    @Test("Idempotent — second pass is a no-op")
    func idempotent() {
        let once = normalizeWindowTitle("(7) Track - Audio playing - Chrome")
        #expect(normalizeWindowTitle(once) == once)
    }

    @Test("Untouched when no patterns match")
    func passthrough() {
        #expect(
            normalizeWindowTitle("Plain Title — Some App")
                == "Plain Title — Some App",
        )
    }

    @Test("Preserves the empty string")
    func preservesEmpty() {
        #expect(normalizeWindowTitle("") == "")
    }

    // MARK: - Real-world wobble parity

    @Test("Real log wobble: HBO Max title with/without 'Audio playing' collapse equal")
    func realWorldHBOMaxWobble() {
        let bare = "Andale • HBO Max - Google Chrome - John Doe"
        let annotated = "Andale • HBO Max - Audio playing - Google Chrome - John Doe"
        #expect(normalizeWindowTitle(bare) == normalizeWindowTitle(annotated))
    }

    @Test("Strips both 'Audio playing' and 'Audio muted' if somehow co-present")
    func stripsBothAnnotations() {
        #expect(
            normalizeWindowTitle("Page - Audio playing - Audio muted - Chrome")
                == "Page - Chrome",
        )
    }

    // MARK: - Audio-annotation negative cases (don't over-strip)

    @Test("'Audio playing' without leading ' - ' is preserved")
    func audioRequiresHyphenSeparator() {
        #expect(
            normalizeWindowTitle("How Audio playing works - Tutorial - Chrome")
                == "How Audio playing works - Tutorial - Chrome",
        )
    }

    @Test("'audio playing' (lowercase) is preserved")
    func audioCaseSensitive() {
        #expect(
            normalizeWindowTitle("Page - audio playing - Chrome")
                == "Page - audio playing - Chrome",
        )
    }

    // MARK: - Counter regex negative cases

    @Test("Counter not at start of string is preserved")
    func counterMidStringPreserved() {
        #expect(
            normalizeWindowTitle("Title with (3) reference - Site")
                == "Title with (3) reference - Site",
        )
    }

    @Test("Counter without trailing whitespace is preserved")
    func counterWithoutTrailingSpacePreserved() {
        #expect(normalizeWindowTitle("(3)Title") == "(3)Title")
    }

    @Test("Parens with non-digit content are preserved")
    func counterNonDigitPreserved() {
        #expect(normalizeWindowTitle("(abc) Title") == "(abc) Title")
    }

    @Test("Empty parens are preserved")
    func emptyParensPreserved() {
        #expect(normalizeWindowTitle("() Title") == "() Title")
    }

    @Test("Multi-digit counter strips correctly")
    func multiDigitCounter() {
        #expect(normalizeWindowTitle("(999) Inbox") == "Inbox")
    }

    // MARK: - Empty-result edge

    @Test("Title that becomes empty after stripping returns empty string")
    func emptyAfterNormalization() {
        // `overrideKey()` guards against keying on this — pin the
        // helper's contract.
        #expect(normalizeWindowTitle(" - Audio playing") == "")
        #expect(normalizeWindowTitle("(3)   ") == "")
    }
}

@Suite("OverrideKey")
struct OverrideKeyTests {
    @Test("Equal when all three fields match")
    func equality() {
        let a = OverrideKey(
            frontBundle: "com.google.Chrome",
            windowTitle: "Track",
            nowPlayingTitle: "Show",
        )
        let b = OverrideKey(
            frontBundle: "com.google.Chrome",
            windowTitle: "Track",
            nowPlayingTitle: "Show",
        )
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("Different windowTitle → different key")
    func differentTitle() {
        let a = OverrideKey(frontBundle: "com.google.Chrome", windowTitle: "Track A")
        let b = OverrideKey(frontBundle: "com.google.Chrome", windowTitle: "Track B")
        #expect(a != b)
    }

    @Test("Different bundle → different key (collision-by-title guard)")
    func differentBundle() {
        let a = OverrideKey(frontBundle: "com.google.Chrome", windowTitle: "GitHub")
        let b = OverrideKey(frontBundle: "com.apple.Safari", windowTitle: "GitHub")
        #expect(a != b)
    }

    @Test("Same key in a Set/Dict replaces — no contradictory entries")
    func dictReplacesOnDuplicateKey() {
        let key = OverrideKey(frontBundle: "com.google.Chrome", windowTitle: "Track")
        var map: [OverrideKey: Overrule] = [:]
        map[key] = .forceHide
        map[key] = .forceShow
        #expect(map.count == 1)
        #expect(map[key] == .forceShow)
    }

    @Test("Multiple distinct keys coexist in the same map")
    func multipleEntries() {
        var map: [OverrideKey: Overrule] = [:]
        map[OverrideKey(frontBundle: "com.google.Chrome", windowTitle: "Euphoria")] = .forceHide
        map[OverrideKey(frontBundle: "com.apple.Safari", windowTitle: "Wiki")] = .forceShow
        map[OverrideKey(frontBundle: "com.apple.Terminal", windowTitle: "tail -f log")] =
            .forceHide
        #expect(map.count == 3)
        #expect(map[OverrideKey(frontBundle: "com.google.Chrome", windowTitle: "Euphoria")] ==
            .forceHide)
        #expect(map[OverrideKey(frontBundle: "com.apple.Safari", windowTitle: "Wiki")] ==
            .forceShow)
        #expect(map[OverrideKey(frontBundle: "com.apple.Terminal", windowTitle: "tail -f log")]
            == .forceHide)
    }

    @Test("Normalized title produces the same key across audio-annotation wobble")
    func normalizationCollapsesWobble() {
        let bare = "Euphoria - HBO Max - Google Chrome - John Doe"
        let annotated = "Euphoria - HBO Max - Audio playing - Google Chrome - John Doe"
        let bareKey = OverrideKey(
            frontBundle: "com.google.Chrome",
            windowTitle: normalizeWindowTitle(bare),
        )
        let annotatedKey = OverrideKey(
            frontBundle: "com.google.Chrome",
            windowTitle: normalizeWindowTitle(annotated),
        )
        #expect(bareKey == annotatedKey)
    }

    // MARK: - Case + whitespace sensitivity

    @Test("Window title comparison is case-sensitive")
    func titleCaseSensitive() {
        let lower = OverrideKey(frontBundle: "com.x.App", windowTitle: "track")
        let upper = OverrideKey(frontBundle: "com.x.App", windowTitle: "Track")
        #expect(lower != upper)
    }

    @Test("Bundle id comparison is case-sensitive")
    func bundleCaseSensitive() {
        let lower = OverrideKey(frontBundle: "com.example.app", windowTitle: "X")
        let mixed = OverrideKey(frontBundle: "com.Example.App", windowTitle: "X")
        #expect(lower != mixed)
    }

    @Test("Window title comparison is whitespace-sensitive")
    func titleWhitespaceSensitive() {
        let nospace = OverrideKey(frontBundle: "com.x.App", windowTitle: "Track")
        let trailing = OverrideKey(frontBundle: "com.x.App", windowTitle: "Track ")
        #expect(nospace != trailing)
    }

    // MARK: - Map operations

    @Test("Removing an entry frees the slot for re-insertion")
    func removeAndReinsert() {
        let key = OverrideKey(frontBundle: "com.google.Chrome", windowTitle: "Track")
        var map: [OverrideKey: Overrule] = [key: .forceHide]
        #expect(map[key] == .forceHide)
        map.removeValue(forKey: key)
        #expect(map[key] == nil)
        map[key] = .forceShow
        #expect(map[key] == .forceShow)
        #expect(map.count == 1)
    }

    @Test("Distinct keys insert independently regardless of insertion order")
    func insertOrderIndependent() {
        let k1 = OverrideKey(frontBundle: "a", windowTitle: "X")
        let k2 = OverrideKey(frontBundle: "b", windowTitle: "X")
        let k3 = OverrideKey(frontBundle: "c", windowTitle: "X")
        var forward: [OverrideKey: Overrule] = [:]
        forward[k1] = .forceHide; forward[k2] = .forceShow; forward[k3] = .forceHide
        var reverse: [OverrideKey: Overrule] = [:]
        reverse[k3] = .forceHide; reverse[k2] = .forceShow; reverse[k1] = .forceHide
        #expect(forward == reverse)
    }

    // MARK: - nowPlayingTitle field

    @Test("Hashable distinguishes by NP title (other fields equal)")
    func hashableIncludesNP() {
        let a = OverrideKey(frontBundle: "com.x", windowTitle: "W", nowPlayingTitle: "A")
        let b = OverrideKey(frontBundle: "com.x", windowTitle: "W", nowPlayingTitle: "B")
        #expect(a != b)
    }

    @Test("nowPlayingTitle defaults to nil — back-compat with two-arg init")
    func npDefaultsNil() {
        let a = OverrideKey(frontBundle: "com.x", windowTitle: "W")
        let b = OverrideKey(frontBundle: "com.x", windowTitle: "W", nowPlayingTitle: nil)
        #expect(a == b)
    }
}

@Suite("OverrideKey.matchesByWindow")
struct OverrideKeyMatchesByWindowTests {
    @Test("Same bundle + same window title → true")
    func exactMatch() {
        let key = OverrideKey(frontBundle: "com.x.App", windowTitle: "Track A")
        #expect(key.matchesByWindow(frontBundle: "com.x.App", windowTitle: "Track A"))
    }

    @Test("Different bundle → false")
    func bundleMismatch() {
        let key = OverrideKey(frontBundle: "com.x.App", windowTitle: "Track")
        #expect(!key.matchesByWindow(frontBundle: "com.y.App", windowTitle: "Track"))
    }

    @Test("Different window title → false")
    func titleMismatch() {
        let key = OverrideKey(frontBundle: "com.x.App", windowTitle: "Track A")
        #expect(!key.matchesByWindow(frontBundle: "com.x.App", windowTitle: "Track B"))
    }

    @Test("nil queried title → false (no match without a window context)")
    func queryNil() {
        let key = OverrideKey(frontBundle: "com.x.App", windowTitle: "Track")
        #expect(!key.matchesByWindow(frontBundle: "com.x.App", windowTitle: nil))
    }

    @Test("Empty queried title → false")
    func queryEmpty() {
        let key = OverrideKey(frontBundle: "com.x.App", windowTitle: "Track")
        #expect(!key.matchesByWindow(frontBundle: "com.x.App", windowTitle: ""))
    }

    @Test("Stored NP title irrelevant for window match")
    func npIgnored() {
        let key = OverrideKey(
            frontBundle: "com.x.App",
            windowTitle: "Track",
            nowPlayingTitle: "Show",
        )
        #expect(key.matchesByWindow(frontBundle: "com.x.App", windowTitle: "Track"))
    }

    @Test("Whitespace-only difference → false (no implicit normalization on lookup)")
    func whitespaceSensitive() {
        let key = OverrideKey(frontBundle: "com.x.App", windowTitle: "Track")
        #expect(!key.matchesByWindow(frontBundle: "com.x.App", windowTitle: "Track "))
    }

    @Test("Case difference → false (case-sensitive)")
    func caseSensitive() {
        let key = OverrideKey(frontBundle: "com.x.App", windowTitle: "Track")
        #expect(!key.matchesByWindow(frontBundle: "com.x.App", windowTitle: "track"))
    }
}

@Suite("OverrideKey.matchesByNowPlaying")
struct OverrideKeyMatchesByNPTests {
    @Test("Same bundle + same NP title → true")
    func exactMatch() {
        let key = OverrideKey(
            frontBundle: "com.x.App",
            windowTitle: "Track",
            nowPlayingTitle: "Show",
        )
        #expect(key.matchesByNowPlaying(frontBundle: "com.x.App", nowPlayingTitle: "Show"))
    }

    @Test("Stored NP title nil → false (won't bridge no-NP pins)")
    func storedNil() {
        let key = OverrideKey(
            frontBundle: "com.x.App",
            windowTitle: "Track",
            nowPlayingTitle: nil,
        )
        #expect(!key.matchesByNowPlaying(frontBundle: "com.x.App", nowPlayingTitle: "Show"))
    }

    @Test("Queried NP title nil → false")
    func queryNil() {
        let key = OverrideKey(
            frontBundle: "com.x.App",
            windowTitle: "Track",
            nowPlayingTitle: "Show",
        )
        #expect(!key.matchesByNowPlaying(frontBundle: "com.x.App", nowPlayingTitle: nil))
    }

    @Test("Stored NP title empty → false")
    func storedEmpty() {
        let key = OverrideKey(
            frontBundle: "com.x.App",
            windowTitle: "Track",
            nowPlayingTitle: "",
        )
        #expect(!key.matchesByNowPlaying(frontBundle: "com.x.App", nowPlayingTitle: ""))
    }

    @Test("Different bundle → false even when NP titles match")
    func bundleMismatch() {
        let key = OverrideKey(
            frontBundle: "com.x.App",
            windowTitle: "Track",
            nowPlayingTitle: "Show",
        )
        #expect(!key.matchesByNowPlaying(frontBundle: "com.y.App", nowPlayingTitle: "Show"))
    }

    @Test("NP-title comparison is case-sensitive")
    func caseSensitive() {
        let key = OverrideKey(
            frontBundle: "com.x.App",
            windowTitle: "Track",
            nowPlayingTitle: "Show",
        )
        #expect(!key.matchesByNowPlaying(frontBundle: "com.x.App", nowPlayingTitle: "show"))
    }

    @Test("Whitespace difference → false (no normalization on NP titles)")
    func whitespaceSensitive() {
        let key = OverrideKey(
            frontBundle: "com.x.App",
            windowTitle: "Track",
            nowPlayingTitle: "Show",
        )
        #expect(!key.matchesByNowPlaying(frontBundle: "com.x.App", nowPlayingTitle: "Show "))
    }

    // MARK: - Real-world parity

    @Test("HBO scenario: window changes per episode, NP title stable")
    func hboEpisodeRoll() {
        // User pinned while watching episode 1 — both fields captured.
        let pinned = OverrideKey(
            frontBundle: "com.google.Chrome",
            windowTitle: "Euphoria S01E01 - HBO Max",
            nowPlayingTitle: "Euphoria",
        )
        // Episode 2: window title changed, NP title stable.
        #expect(!pinned.matchesByWindow(
            frontBundle: "com.google.Chrome",
            windowTitle: "Euphoria S01E02 - HBO Max",
        ))
        #expect(pinned.matchesByNowPlaying(
            frontBundle: "com.google.Chrome",
            nowPlayingTitle: "Euphoria",
        ))
    }
}

@Suite("OverrideKey.overlaps")
struct OverrideKeyOverlapsTests {
    @Test("Same window title → overlap (same logical pin, different NP)")
    func sameWindow() {
        let a = OverrideKey(frontBundle: "com.x", windowTitle: "W", nowPlayingTitle: "A")
        let b = OverrideKey(frontBundle: "com.x", windowTitle: "W", nowPlayingTitle: "B")
        #expect(a.overlaps(b))
        #expect(b.overlaps(a))
    }

    @Test("Same NP title → overlap (HBO-style episode roll)")
    func sameNP() {
        let a = OverrideKey(frontBundle: "com.x", windowTitle: "W1", nowPlayingTitle: "Same")
        let b = OverrideKey(frontBundle: "com.x", windowTitle: "W2", nowPlayingTitle: "Same")
        #expect(a.overlaps(b))
        #expect(b.overlaps(a))
    }

    @Test("Different bundle → no overlap even when both titles match")
    func differentBundle() {
        let a = OverrideKey(frontBundle: "com.x", windowTitle: "W", nowPlayingTitle: "S")
        let b = OverrideKey(frontBundle: "com.y", windowTitle: "W", nowPlayingTitle: "S")
        #expect(!a.overlaps(b))
        #expect(!b.overlaps(a))
    }

    @Test("Both NPs nil — different windows stay distinct")
    func bothNPNilDifferentWindows() {
        let a = OverrideKey(frontBundle: "com.x", windowTitle: "W1", nowPlayingTitle: nil)
        let b = OverrideKey(frontBundle: "com.x", windowTitle: "W2", nowPlayingTitle: nil)
        #expect(!a.overlaps(b))
    }

    @Test("One NP nil, other non-nil — no NP-axis bridge")
    func oneNPNil() {
        let a = OverrideKey(frontBundle: "com.x", windowTitle: "W1", nowPlayingTitle: "S")
        let b = OverrideKey(frontBundle: "com.x", windowTitle: "W2", nowPlayingTitle: nil)
        #expect(!a.overlaps(b))
        #expect(!b.overlaps(a))
    }

    @Test("Both axes match — overlap (trivially)")
    func bothMatch() {
        let a = OverrideKey(frontBundle: "com.x", windowTitle: "W", nowPlayingTitle: "S")
        let b = OverrideKey(frontBundle: "com.x", windowTitle: "W", nowPlayingTitle: "S")
        #expect(a.overlaps(b))
    }

    @Test("Wholly distinct on both axes → no overlap (coexist in map)")
    func disjoint() {
        let a = OverrideKey(frontBundle: "com.x", windowTitle: "W1", nowPlayingTitle: "S1")
        let b = OverrideKey(frontBundle: "com.x", windowTitle: "W2", nowPlayingTitle: "S2")
        #expect(!a.overlaps(b))
    }

    @Test("Reflexive: a key always overlaps itself")
    func reflexive() {
        let withNP = OverrideKey(
            frontBundle: "com.x",
            windowTitle: "W",
            nowPlayingTitle: "S",
        )
        let withoutNP = OverrideKey(frontBundle: "com.x", windowTitle: "W")
        #expect(withNP.overlaps(withNP))
        #expect(withoutNP.overlaps(withoutNP))
    }

    @Test("Symmetric: a.overlaps(b) ⇔ b.overlaps(a)")
    func symmetric() {
        let pairs: [(OverrideKey, OverrideKey)] = [
            // window-axis overlap
            (
                OverrideKey(frontBundle: "com.x", windowTitle: "W", nowPlayingTitle: "A"),
                OverrideKey(frontBundle: "com.x", windowTitle: "W", nowPlayingTitle: "B"),
            ),
            // np-axis overlap
            (
                OverrideKey(frontBundle: "com.x", windowTitle: "W1", nowPlayingTitle: "S"),
                OverrideKey(frontBundle: "com.x", windowTitle: "W2", nowPlayingTitle: "S"),
            ),
            // disjoint
            (
                OverrideKey(frontBundle: "com.x", windowTitle: "W1", nowPlayingTitle: "S1"),
                OverrideKey(frontBundle: "com.x", windowTitle: "W2", nowPlayingTitle: "S2"),
            ),
        ]
        for (a, b) in pairs {
            #expect(a.overlaps(b) == b.overlaps(a))
        }
    }
}

// MARK: - Override-map re-pin behavior

/// End-to-end tests over the filter+insert pattern from
/// `Controller.toggleOverrule`. Doesn't instantiate Controller (it's
/// `@MainActor` with live watchers); instead pins the algorithmic
/// contract: re-pinning under an overlapping context replaces, while
/// disjoint pins coexist.
@Suite("Override map re-pin behavior")
struct OverrideMapRepinTests {
    /// Mirror of the inline pattern in `Controller.toggleOverrule`.
    private func repin(
        _ map: inout [OverrideKey: Overrule],
        _ key: OverrideKey,
        _ value: Overrule,
    ) {
        map = map.filter { !$0.key.overlaps(key) }
        map[key] = value
    }

    @Test("HBO: pin on episode 1 → episode-2 lookup hits via NP title")
    func hboEpisodeMatch() {
        let ep1 = OverrideKey(
            frontBundle: "com.google.Chrome",
            windowTitle: "Euphoria S01E01 - HBO Max",
            nowPlayingTitle: "Euphoria",
        )
        let map: [OverrideKey: Overrule] = [ep1: .forceHide]

        // Same scan resolveOverrule does on the NP-fallback pass.
        let hit = map.first { $0.key.matchesByNowPlaying(
            frontBundle: "com.google.Chrome",
            nowPlayingTitle: "Euphoria",
        ) }
        #expect(hit?.value == .forceHide)
    }

    @Test("Re-pin on episode 2 drops the episode-1 entry; one entry remains")
    func hboRepinReplaces() {
        let ep1 = OverrideKey(
            frontBundle: "com.google.Chrome",
            windowTitle: "Euphoria S01E01 - HBO Max",
            nowPlayingTitle: "Euphoria",
        )
        let ep2 = OverrideKey(
            frontBundle: "com.google.Chrome",
            windowTitle: "Euphoria S01E02 - HBO Max",
            nowPlayingTitle: "Euphoria",
        )
        var map: [OverrideKey: Overrule] = [ep1: .forceHide]

        repin(&map, ep2, .forceHide)
        #expect(map.count == 1)
        #expect(map[ep1] == nil)
        #expect(map[ep2] == .forceHide)
    }

    @Test("Re-pin on the exact same key flips the value (no duplicates)")
    func sameKeyReplaces() {
        let key = OverrideKey(
            frontBundle: "com.google.Chrome",
            windowTitle: "Track",
            nowPlayingTitle: "Show",
        )
        var map: [OverrideKey: Overrule] = [key: .forceHide]
        repin(&map, key, .forceShow)
        #expect(map.count == 1)
        #expect(map[key] == .forceShow)
    }

    @Test("Same NP title across different bundles → coexist")
    func differentBundleCoexists() {
        let chrome = OverrideKey(
            frontBundle: "com.google.Chrome",
            windowTitle: "W",
            nowPlayingTitle: "Show",
        )
        let safari = OverrideKey(
            frontBundle: "com.apple.Safari",
            windowTitle: "W",
            nowPlayingTitle: "Show",
        )
        var map: [OverrideKey: Overrule] = [:]
        repin(&map, chrome, .forceHide)
        repin(&map, safari, .forceShow)
        #expect(map.count == 2)
        #expect(map[chrome] == .forceHide)
        #expect(map[safari] == .forceShow)
    }

    @Test("Wholly distinct pins (different window AND different NP) coexist")
    func disjointPinsCoexist() {
        let pin1 = OverrideKey(
            frontBundle: "com.google.Chrome",
            windowTitle: "Window A",
            nowPlayingTitle: "Show A",
        )
        let pin2 = OverrideKey(
            frontBundle: "com.google.Chrome",
            windowTitle: "Window B",
            nowPlayingTitle: "Show B",
        )
        var map: [OverrideKey: Overrule] = [:]
        repin(&map, pin1, .forceHide)
        repin(&map, pin2, .forceShow)
        #expect(map.count == 2)
        #expect(map[pin1] == .forceHide)
        #expect(map[pin2] == .forceShow)
    }

    @Test("Window-only overlap: re-pin on same window with different NP replaces")
    func windowOnlyOverlap() {
        let original = OverrideKey(
            frontBundle: "com.google.Chrome",
            windowTitle: "Track",
            nowPlayingTitle: "Show A",
        )
        let repin1 = OverrideKey(
            frontBundle: "com.google.Chrome",
            windowTitle: "Track",
            nowPlayingTitle: "Show B",
        )
        var map: [OverrideKey: Overrule] = [original: .forceHide]
        repin(&map, repin1, .forceShow)
        #expect(map.count == 1)
        #expect(map[repin1] == .forceShow)
    }

    @Test("Three overlapping pins fold into one after the third re-pin")
    func chainedOverlapsFold() {
        // All three share the same NP title — each new pin overlaps
        // its predecessor, so the map never grows beyond one entry.
        let a = OverrideKey(
            frontBundle: "com.google.Chrome",
            windowTitle: "W1",
            nowPlayingTitle: "Show",
        )
        let b = OverrideKey(
            frontBundle: "com.google.Chrome",
            windowTitle: "W2",
            nowPlayingTitle: "Show",
        )
        let c = OverrideKey(
            frontBundle: "com.google.Chrome",
            windowTitle: "W3",
            nowPlayingTitle: "Show",
        )
        var map: [OverrideKey: Overrule] = [:]
        repin(&map, a, .forceHide)
        repin(&map, b, .forceShow)
        repin(&map, c, .forceHide)
        #expect(map.count == 1)
        #expect(map[c] == .forceHide)
    }
}
