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
    @Test("Equal when both fields match")
    func equality() {
        let a = OverrideKey(frontBundle: "com.google.Chrome", windowTitle: "Track")
        let b = OverrideKey(frontBundle: "com.google.Chrome", windowTitle: "Track")
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

    @Test("nil bundle is its own slot, distinct from any non-nil")
    func nilBundleDistinct() {
        let nilSlot = OverrideKey(frontBundle: nil, windowTitle: "Doc")
        let chrome = OverrideKey(frontBundle: "com.google.Chrome", windowTitle: "Doc")
        #expect(nilSlot != chrome)
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
        map[OverrideKey(frontBundle: nil, windowTitle: "Terminal")] = .forceHide
        #expect(map.count == 3)
        #expect(map[OverrideKey(frontBundle: "com.google.Chrome", windowTitle: "Euphoria")] ==
            .forceHide)
        #expect(map[OverrideKey(frontBundle: "com.apple.Safari", windowTitle: "Wiki")] ==
            .forceShow)
        #expect(map[OverrideKey(frontBundle: nil, windowTitle: "Terminal")] == .forceHide)
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

    // MARK: - String? bundle distinctions

    @Test("Empty bundle string is distinct from nil bundle")
    func emptyBundleDistinctFromNil() {
        let emptyBundle = OverrideKey(frontBundle: "", windowTitle: "Doc")
        let nilBundle = OverrideKey(frontBundle: nil, windowTitle: "Doc")
        #expect(emptyBundle != nilBundle)
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
        let k3 = OverrideKey(frontBundle: nil, windowTitle: "X")
        var forward: [OverrideKey: Overrule] = [:]
        forward[k1] = .forceHide; forward[k2] = .forceShow; forward[k3] = .forceHide
        var reverse: [OverrideKey: Overrule] = [:]
        reverse[k3] = .forceHide; reverse[k2] = .forceShow; reverse[k1] = .forceHide
        #expect(forward == reverse)
    }
}
