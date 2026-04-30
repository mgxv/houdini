// Pin the chunk-splitting + boundary semantics of the per-stream
// line accumulator used by AdapterClient and DockSpaceWatcher.

import Foundation
@testable import houdini
import Testing

@Suite("LineBuffer.ingest")
struct LineBufferTests {
    /// Helper: ingest one chunk and return all the lines emitted as Strings.
    private func feed(
        _ chunks: String...,
        into buffer: inout LineBuffer,
    ) -> [String] {
        var emitted: [String] = []
        for chunk in chunks {
            buffer.ingest(Data(chunk.utf8)) { line in
                emitted.append(String(decoding: line, as: UTF8.self))
            }
        }
        return emitted
    }

    @Test("Single complete line emits once and clears the buffer")
    func singleLine() {
        var buffer = LineBuffer()
        let lines = feed("hello\n", into: &buffer)
        #expect(lines == ["hello"])
        #expect(buffer.pendingBytes == 0)
    }

    @Test("Two lines in one chunk emit in order")
    func twoLinesOneChunk() {
        var buffer = LineBuffer()
        let lines = feed("a\nb\n", into: &buffer)
        #expect(lines == ["a", "b"])
        #expect(buffer.pendingBytes == 0)
    }

    @Test("A line split across chunks emits once after the newline arrives")
    func splitAcrossChunks() {
        var buffer = LineBuffer()
        let first = feed("hel", into: &buffer)
        #expect(first.isEmpty)
        #expect(buffer.pendingBytes == 3)

        let second = feed("lo\n", into: &buffer)
        #expect(second == ["hello"])
        #expect(buffer.pendingBytes == 0)
    }

    @Test("Trailing partial line stays buffered until the next newline")
    func trailingPartial() {
        var buffer = LineBuffer()
        let first = feed("first\nsec", into: &buffer)
        #expect(first == ["first"])
        #expect(buffer.pendingBytes == 3) // "sec"

        let second = feed("ond\n", into: &buffer)
        #expect(second == ["second"])
        #expect(buffer.pendingBytes == 0)
    }

    @Test("Chunk with no newline never emits, pendingBytes accumulates")
    func noNewline() {
        var buffer = LineBuffer()
        let lines = feed("no_newline_here", into: &buffer)
        #expect(lines.isEmpty)
        #expect(buffer.pendingBytes == "no_newline_here".utf8.count)
    }

    @Test("Empty chunk is a no-op")
    func emptyChunk() {
        var buffer = LineBuffer()
        var emitted: [String] = []
        buffer.ingest(Data()) { emitted.append(String(decoding: $0, as: UTF8.self)) }
        #expect(emitted.isEmpty)
        #expect(buffer.pendingBytes == 0)
    }

    @Test("Consecutive newlines preserve empty lines")
    func consecutiveNewlines() {
        var buffer = LineBuffer()
        let lines = feed("\n\n\n", into: &buffer)
        #expect(lines == ["", "", ""])
        #expect(buffer.pendingBytes == 0)
    }

    @Test("Stream of many chunks preserves global ordering")
    func manyChunks() {
        var buffer = LineBuffer()
        var emitted: [String] = []
        for chunk in ["a", "\nbb", "\n", "ccc\n", "ddd"] {
            buffer.ingest(Data(chunk.utf8)) { line in
                emitted.append(String(decoding: line, as: UTF8.self))
            }
        }
        #expect(emitted == ["a", "bb", "ccc"])
        #expect(buffer.pendingBytes == 3) // "ddd" still pending
    }

    @Test("UTF-8 multibyte characters preserved across chunk boundaries")
    func utf8Multibyte() {
        // "🎵" is a 4-byte UTF-8 sequence; split mid-byte to stress the buffer.
        let bytes = Array("🎵\n".utf8)
        var buffer = LineBuffer()
        var emitted: [String] = []
        buffer.ingest(Data(bytes[0 ..< 2])) { line in
            emitted.append(String(decoding: line, as: UTF8.self))
        }
        #expect(emitted.isEmpty)
        buffer.ingest(Data(bytes[2 ..< bytes.count])) { line in
            emitted.append(String(decoding: line, as: UTF8.self))
        }
        #expect(emitted == ["🎵"])
        #expect(buffer.pendingBytes == 0)
    }
}
