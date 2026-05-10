// Pin the JSON schema and round-trip behavior of AppOverrides
// against temp files so the production apps.json isn't touched.

import Foundation
@testable import houdini
import Testing

@Suite("AppOverridesState")
struct AppOverridesStateTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("houdini-test-\(UUID().uuidString).json")
    }

    @Test("Missing file returns .empty")
    func missingFile() {
        let url = tempURL()
        #expect(AppOverridesState.read(at: url) == .empty)
    }

    @Test("Malformed JSON returns .empty")
    func malformedJSON() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "not json at all".write(to: url, atomically: true, encoding: .utf8)
        #expect(AppOverridesState.read(at: url) == .empty)
    }

    @Test("Missing 'deny' key decodes to empty set")
    func missingDenyKey() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "{}".write(to: url, atomically: true, encoding: .utf8)
        #expect(AppOverridesState.read(at: url) == .empty)
    }

    @Test("Populated deny array decodes to a set")
    func populatedDeny() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        {"deny": ["com.spotify.client", "com.apple.Music"]}
        """.write(to: url, atomically: true, encoding: .utf8)
        #expect(AppOverridesState.read(at: url) ==
            AppOverrides(deny: ["com.spotify.client", "com.apple.Music"]))
    }

    @Test("Duplicate entries in source array collapse")
    func duplicatesCollapse() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        {"deny": ["com.spotify.client", "com.spotify.client"]}
        """.write(to: url, atomically: true, encoding: .utf8)
        #expect(AppOverridesState.read(at: url) ==
            AppOverrides(deny: ["com.spotify.client"]))
    }

    @Test("Round-trip: write then read preserves the set")
    func roundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = AppOverrides(deny: ["com.b.app", "com.a.app"])

        try AppOverridesState.write(original, to: url)
        #expect(AppOverridesState.read(at: url) == original)
    }

    @Test("Written JSON is sorted (stable output for diffs)")
    func writeIsSorted() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = AppOverrides(deny: ["com.z.app", "com.a.app"])

        try AppOverridesState.write(original, to: url)
        let json = try String(contentsOf: url, encoding: .utf8)
        if let aIdx = json.range(of: "com.a.app")?.lowerBound,
           let zIdx = json.range(of: "com.z.app")?.lowerBound
        {
            #expect(aIdx < zIdx)
        } else {
            Issue.record("expected both bundle IDs in output: \(json)")
        }
    }
}
