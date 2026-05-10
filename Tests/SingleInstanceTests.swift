// Pin the parsing semantics of `readDaemonPID(at:)` against temp
// files so the production lock-file path isn't touched.

import Foundation
@testable import houdini
import Testing

@Suite("readDaemonPID")
struct ReadDaemonPIDTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("houdini-test-\(UUID().uuidString).pid")
    }

    private func write(_ content: String, to url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("Missing file returns nil")
    func missingFile() {
        let url = tempURL()
        #expect(readDaemonPID(at: url) == nil)
    }

    @Test("Empty file returns nil")
    func emptyFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("", to: url)
        #expect(readDaemonPID(at: url) == nil)
    }

    @Test("Whitespace-only file returns nil")
    func whitespaceOnly() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("   \n\t  \n", to: url)
        #expect(readDaemonPID(at: url) == nil)
    }

    @Test("Bare PID parses")
    func barePID() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("12345", to: url)
        #expect(readDaemonPID(at: url) == 12345)
    }

    @Test("PID with trailing newline parses (production write format)")
    func pidWithNewline() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("12345\n", to: url)
        #expect(readDaemonPID(at: url) == 12345)
    }

    @Test("PID with surrounding whitespace parses")
    func pidWithSurroundingWhitespace() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("  12345  \n", to: url)
        #expect(readDaemonPID(at: url) == 12345)
    }

    @Test("Non-numeric content returns nil")
    func nonNumeric() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("not-a-pid", to: url)
        #expect(readDaemonPID(at: url) == nil)
    }

    @Test("Mixed-content content returns nil (strict parse)")
    func mixedContent() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("12345abc", to: url)
        #expect(readDaemonPID(at: url) == nil)
    }
}
