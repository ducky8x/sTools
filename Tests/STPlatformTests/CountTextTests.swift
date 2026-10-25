import Testing
@testable import STPlatform

/// A count with its noun reads in the singular for exactly one, and in the plural otherwise, zero included.
@Suite("Count wording")
struct CountTextTests {
    @Test func oneIsSingularEverythingElsePlural() {
        #expect(CountText.of(1, "frame") == "1 frame")
        #expect(CountText.of(0, "frame") == "0 frames")
        #expect(CountText.of(2, "frame") == "2 frames")
        #expect(CountText.of(-1, "frame") == "-1 frames")
        #expect(CountText.of(1_000, "setting group") == "1000 setting groups")
    }

    @Test func anIrregularPluralIsGivenOutright() {
        #expect(CountText.of(1, "entry", plural: "entries") == "1 entry")
        #expect(CountText.of(3, "entry", plural: "entries") == "3 entries")
    }

    @Test func theVerbAgreesWithTheCount() {
        #expect(CountText.of(1, "frame", verb: ("was", "were")) == "1 frame was")
        #expect(CountText.of(4, "frame", verb: ("was", "were")) == "4 frames were")
    }
}
