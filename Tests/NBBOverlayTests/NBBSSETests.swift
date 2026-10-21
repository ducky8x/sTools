import Testing
@testable import NBBOverlay

@Suite("SSE line splitter")
struct SSELineSplitterTests {
    @Test func wholeLinesInOneChunkSplitCleanly() {
        var splitter = SSELineSplitter()
        let lines = splitter.feed(Array("data: a\ndata: b\n".utf8))
        #expect(lines == ["data: a", "data: b"])
    }

    @Test func aLineSplitAcrossChunksIsReassembled() {
        var splitter = SSELineSplitter()
        #expect(splitter.feed(Array("data: hel".utf8)) == [])
        #expect(splitter.feed(Array("lo\n".utf8)) == ["data: hello"])
    }

    @Test func crlfLineEndingsAreStripped() {
        var splitter = SSELineSplitter()
        let lines = splitter.feed(Array("data: a\r\ndata: b\r\n".utf8))
        #expect(lines == ["data: a", "data: b"])
    }

    @Test func blankLinesSurviveAsEmptyStrings() {
        var splitter = SSELineSplitter()
        let lines = splitter.feed(Array("data: a\n\ndata: b\n".utf8))
        #expect(lines == ["data: a", "", "data: b"])
    }

    @Test func byteByByteFeedingStillReassemblesCorrectly() {
        var splitter = SSELineSplitter()
        var lines: [String] = []
        for byte in Array("data: {\"a\":1}\n".utf8) {
            lines += splitter.feed([byte])
        }
        #expect(lines == ["data: {\"a\":1}"])
    }

    @Test func multiByteUTF8CharacterSplitAcrossChunksDecodesCorrectly() {
        // "café" — é is 2 UTF-8 bytes; split the chunk right between them.
        let bytes = Array("data: café\n".utf8)
        let splitPoint = bytes.count - 2
        var splitter = SSELineSplitter()
        #expect(splitter.feed(bytes[..<splitPoint]) == [])
        #expect(splitter.feed(bytes[splitPoint...]) == ["data: café"])
    }
}

@Suite("SSE event accumulator")
struct SSEEventAccumulatorTests {
    @Test func singleLineDataDispatchesOnBlankLine() {
        var accumulator = SSEEventAccumulator()
        #expect(accumulator.consume("data: hello") == nil)
        #expect(accumulator.consume("") == "hello")
    }

    @Test func multiLineDataIsJoinedWithNewlines() {
        var accumulator = SSEEventAccumulator()
        #expect(accumulator.consume("data: line1") == nil)
        #expect(accumulator.consume("data: line2") == nil)
        #expect(accumulator.consume("") == "line1\nline2")
    }

    @Test func commentLinesAreIgnored() {
        var accumulator = SSEEventAccumulator()
        #expect(accumulator.consume(": keep-alive") == nil)
        #expect(accumulator.consume("data: hello") == nil)
        #expect(accumulator.consume("") == "hello")
    }

    @Test func otherFieldsAreIgnoredButDontBreakTheData() {
        var accumulator = SSEEventAccumulator()
        #expect(accumulator.consume("event: message") == nil)
        #expect(accumulator.consume("id: 1") == nil)
        #expect(accumulator.consume("data: hello") == nil)
        #expect(accumulator.consume("") == "hello")
    }

    @Test func blankLineWithNoDataDispatchesNothing() {
        var accumulator = SSEEventAccumulator()
        #expect(accumulator.consume("") == nil)
    }

    @Test func dataWithNoLeadingSpaceIsStillRead() {
        var accumulator = SSEEventAccumulator()
        #expect(accumulator.consume("data:hello") == nil)
        #expect(accumulator.consume("") == "hello")
    }

    @Test func twoEventsInARowEachDispatchSeparately() {
        var accumulator = SSEEventAccumulator()
        _ = accumulator.consume("data: first")
        #expect(accumulator.consume("") == "first")
        _ = accumulator.consume("data: second")
        #expect(accumulator.consume("") == "second")
    }
}

@Suite("SSE parser end to end")
struct SSEParserTests {
    @Test func fragmentedChunksEventuallyProduceTheFullEvent() {
        var parser = SSEParser()
        let full = "data: {\"resultType\":\"NONE\"}\n\n"
        var allEvents: [String] = []
        // Feed one byte at a time to simulate a network stream fragmenting arbitrarily.
        for byte in Array(full.utf8) {
            allEvents += parser.feed([byte])
        }
        #expect(allEvents == ["{\"resultType\":\"NONE\"}"])
    }

    @Test func multipleEventsInOneChunk() {
        var parser = SSEParser()
        let chunk = Array("data: a\n\ndata: b\n\n".utf8)
        #expect(parser.feed(chunk) == ["a", "b"])
    }

    @Test func commentOnlyKeepAlivesProduceNoEvents() {
        var parser = SSEParser()
        #expect(parser.feed(Array(": ping\n\n: ping\n\n".utf8)) == [])
    }
}

/// Ninjabrain Bot sends nothing between changes, so a stream must be allowed to stay quiet far longer than
/// URLSession's default minute; otherwise each quiet minute drops it and the reconnect redraws the overlay.
@Test func eventStreamsMayStayQuietForLongerThanAMinute() {
    #expect(URLSessionEventSource.idleTimeout >= 60 * 60)
}
