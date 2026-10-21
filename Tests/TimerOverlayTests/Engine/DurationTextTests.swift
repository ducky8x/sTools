import Foundation
import Testing
@testable import TimerOverlay

@Suite("Duration text")
struct DurationTextTests {
    @Test(arguments: [(150, "0:02:30"), (1, "0:00:01"), (3600, "1:00:00"), (359_999, "99:59:59"), (0, "0:00:00")])
    func formatsHoursMinutesAndSeconds(seconds: Int, text: String) {
        #expect(DurationText.format(seconds) == text)
    }

    @Test(arguments: [
        ("0:02:30", 150), ("2:30", 150), ("150", 150), (" 1:00:00 ", 3600), ("90:00", 5400),
        ("99:59:59", 359_999), ("0:2:30", 150), ("1:5", 65), ("00:00:45", 45),
    ])
    func parsesHoursMinutesAndSeconds(text: String, seconds: Int) {
        #expect(DurationText.parse(text) == seconds)
    }

    @Test(arguments: [("0", 1), ("0:00:00", 1), ("100:00:00", 359_999), ("999999999", 359_999)])
    func keepsTheValueBetweenOneSecondAnd99_59_59(text: String, seconds: Int) {
        #expect(DurationText.parse(text) == seconds)
    }

    @Test(arguments: [
        "", "  ", "abc", "1:60", "1:2:60", "1:99:00", "1:2:3:4", "::", "1:", ":30", "-5", "+5", "2.5", "1:030",
        "\u{FF11}\u{FF12}", "1 :30", "9999999999",
    ])
    func rejectsWhatIsntADuration(text: String) {
        #expect(DurationText.parse(text) == nil)
    }

    @Test func formattedDurationsParseBack() {
        for seconds in [1, 59, 60, 61, 150, 599, 3599, 3600, 3661, 86_400, 359_999] {
            #expect(DurationText.parse(DurationText.format(seconds)) == seconds)
        }
    }

    @Test func theRangeIsTheSettingsRange() {
        #expect(DurationText.range == TimerOverlaySettings.durationRange)
    }
}
