import Foundation

/// Server-Sent Events parsing (spec 5.1.2), split into two pure, independently testable stages so a
/// fragmented chunk, a multi-line `data:` field, and a dispatch boundary can each be pinned down on
/// their own: bytes → lines (`SSELineSplitter`), lines → dispatched event payloads (`SSEEventAccumulator`).

/// Buffers partial lines across chunk boundaries and emits complete lines, split on `\n` or `\r\n`.
/// Operates on raw bytes (not `String`) so a chunk boundary landing inside a multi-byte UTF-8 character
/// never produces a decoding glitch — only complete lines are ever decoded.
struct SSELineSplitter {
    private var buffer: [UInt8] = []

    mutating func feed<S: Sequence>(_ bytes: S) -> [String] where S.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var lineBytes = Array(buffer[..<newlineIndex])
            if lineBytes.last == 0x0D { lineBytes.removeLast() }
            lines.append(String(decoding: lineBytes, as: UTF8.self))
            buffer.removeFirst(newlineIndex + 1)
        }
        return lines
    }
}

/// Accumulates `data:` lines into one dispatched payload per the SSE spec: a blank line dispatches
/// whatever `data:` lines have built up (joined with `\n`, the standard multi-line `data:` rule);
/// comment lines (starting with `:`) and other fields (`event:`, `id:`, `retry:`) are ignored, since
/// Ninjabrain Bot only ever sends `data:`.
struct SSEEventAccumulator {
    private var dataLines: [String] = []

    /// The dispatched payload if `line` completed an event (a blank line with data pending), else nil.
    mutating func consume(_ line: String) -> String? {
        if line.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            defer { dataLines.removeAll() }
            return dataLines.joined(separator: "\n")
        }
        guard !line.hasPrefix(":") else { return nil }
        guard line.hasPrefix("data:") else { return nil }
        var value = String(line.dropFirst("data:".count))
        if value.hasPrefix(" ") { value.removeFirst() }
        dataLines.append(value)
        return nil
    }
}

/// Turns a raw byte stream into dispatched SSE event payloads.
struct SSEParser {
    private var lineSplitter = SSELineSplitter()
    private var eventAccumulator = SSEEventAccumulator()

    mutating func feed<S: Sequence>(_ bytes: S) -> [String] where S.Element == UInt8 {
        lineSplitter.feed(bytes).compactMap { eventAccumulator.consume($0) }
    }
}
