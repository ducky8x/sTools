import Testing
@testable import NBBOverlay

@Suite("NBB backoff")
struct NBBBackoffTests {
    @Test func startsAtHalfASecond() {
        #expect(NBBBackoff.initialSeconds == 0.5)
    }

    @Test func doublesEachStep() {
        var value = NBBBackoff.initialSeconds
        value = NBBBackoff.next(afterSeconds: value)
        #expect(value == 1)
        value = NBBBackoff.next(afterSeconds: value)
        #expect(value == 2)
        value = NBBBackoff.next(afterSeconds: value)
        #expect(value == 4)
    }

    @Test func capsAtFiveSeconds() {
        var value = NBBBackoff.initialSeconds
        for _ in 0..<10 { value = NBBBackoff.next(afterSeconds: value) }
        #expect(value == 5)
    }
}
