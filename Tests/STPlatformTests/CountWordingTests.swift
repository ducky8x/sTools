import Testing
@testable import STPlatform

@Suite struct CountWordingTests {
    @Test func oneTakesTheSingularAndEveryOtherCountThePlural() {
        #expect(CountWording.counted(1, "item") == "1 item")
        #expect(CountWording.counted(0, "item") == "0 items")
        #expect(CountWording.counted(2, "item") == "2 items")
        #expect(CountWording.counted(-1, "item") == "-1 items")
    }

    @Test func anIrregularPluralIsGivenOutright() {
        #expect(CountWording.counted(1, "press", plural: "presses") == "1 press")
        #expect(CountWording.counted(3, "press", plural: "presses") == "3 presses")
    }

    @Test func aNounOfSeveralWordsTakesItsPluralAtTheEnd() {
        #expect(CountWording.counted(1, "setting group") == "1 setting group")
        #expect(CountWording.counted(6, "setting group") == "6 setting groups")
    }
}
