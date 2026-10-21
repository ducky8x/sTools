import Foundation
import Testing
@testable import TimerOverlay

@Suite("Clock format")
struct ClockFormatTests {
    // MARK: Ported from the merged timer app's checks

    @Test(arguments: [(0, "00:00"), (59, "00:59"), (600, "10:00"), (3600, "1:00:00"), (359_999, "99:59:59")])
    func minutesAndSecondsWithHoursFromAnHour(seconds: Int, text: String) {
        #expect(ClockFormat.string(seconds: seconds) == text)
        #expect(ClockFormat.string(seconds: seconds, format: .minutesAndSeconds) == text)
    }

    // MARK: The Advanced formats

    @Test(arguments: [(0, "0:00"), (9, "0:09"), (150, "2:30"), (3599, "59:59"), (3600, "1:00:00"), (3725, "1:02:05")])
    func shortMinutes(seconds: Int, text: String) {
        #expect(ClockFormat.string(seconds: seconds, format: .shortMinutes) == text)
    }

    @Test(arguments: [(0, "0"), (9, "9"), (150, "150"), (3600, "3600"), (359_999, "359999")])
    func secondsOnly(seconds: Int, text: String) {
        #expect(ClockFormat.string(seconds: seconds, format: .secondsOnly) == text)
    }

    @Test func negativeSecondsShowZero() {
        #expect(ClockFormat.string(seconds: -5) == "00:00")
        #expect(ClockFormat.string(seconds: -5, format: .secondsOnly) == "0")
    }

    @Test func tenthsInEachFormat() {
        #expect(ClockFormat.string(tenths: 99, format: .minutesAndSeconds) == "00:09.9")
        #expect(ClockFormat.string(tenths: 99, format: .shortMinutes) == "0:09.9")
        #expect(ClockFormat.string(tenths: 99, format: .secondsOnly) == "9.9")
        #expect(ClockFormat.string(tenths: 0, format: .minutesAndSeconds) == "00:00.0")
    }

    // MARK: The time left, as the overlay shows it

    @Test func theTimeLeftRoundsUpSoZeroShowsOnlyAtZero() {
        #expect(ClockFormat.string(remaining: 150, format: .minutesAndSeconds, tenths: false) == "02:30")
        #expect(ClockFormat.string(remaining: 149.2, format: .minutesAndSeconds, tenths: false) == "02:30")
        #expect(ClockFormat.string(remaining: 0.001, format: .minutesAndSeconds, tenths: false) == "00:01")
        #expect(ClockFormat.string(remaining: 0, format: .minutesAndSeconds, tenths: false) == "00:00")
        #expect(ClockFormat.string(remaining: 3600.5, format: .shortMinutes, tenths: false) == "1:00:01")
    }

    @Test func tenthsShowOnlyInTheLastTenSeconds() {
        #expect(ClockFormat.string(remaining: 12, format: .minutesAndSeconds, tenths: true) == "00:12")
        #expect(ClockFormat.string(remaining: 10.5, format: .minutesAndSeconds, tenths: true) == "00:11")
        #expect(ClockFormat.string(remaining: 10, format: .minutesAndSeconds, tenths: true) == "00:10.0")
        #expect(ClockFormat.string(remaining: 9.95, format: .minutesAndSeconds, tenths: true) == "00:10.0")
        #expect(ClockFormat.string(remaining: 9.9, format: .minutesAndSeconds, tenths: true) == "00:09.9")
        #expect(ClockFormat.string(remaining: 0.05, format: .minutesAndSeconds, tenths: true) == "00:00.1")
        #expect(ClockFormat.string(remaining: 0, format: .minutesAndSeconds, tenths: true) == "00:00.0")
        #expect(ClockFormat.string(remaining: 9.9, format: .shortMinutes, tenths: true) == "0:09.9")
        #expect(ClockFormat.string(remaining: 9.9, format: .secondsOnly, tenths: true) == "9.9")
        #expect(ClockFormat.string(remaining: 9.9, format: .minutesAndSeconds, tenths: false) == "00:10")
    }

    // MARK: Overtime and zero

    @Test func overtimeCountsUpWholeSeconds() {
        #expect(ClockFormat.overtime(0, format: .minutesAndSeconds) == "+0:00")
        #expect(ClockFormat.overtime(0.999, format: .minutesAndSeconds) == "+0:00")
        #expect(ClockFormat.overtime(7.5, format: .minutesAndSeconds) == "+0:07")
        #expect(ClockFormat.overtime(83, format: .shortMinutes) == "+1:23")
        #expect(ClockFormat.overtime(3723, format: .minutesAndSeconds) == "+1:02:03")
        #expect(ClockFormat.overtime(7, format: .secondsOnly) == "+7")
        #expect(ClockFormat.overtime(-3, format: .minutesAndSeconds) == "+0:00")
    }

    @Test func atZeroHoldsZeroInTheChosenFormat() {
        #expect(ClockFormat.atZero(.holdZero, word: "Time", sinceZero: 4, format: .minutesAndSeconds, tenths: false) == "00:00")
        #expect(ClockFormat.atZero(.holdZero, word: "Time", sinceZero: 4, format: .shortMinutes, tenths: false) == "0:00")
        #expect(ClockFormat.atZero(.holdZero, word: "Time", sinceZero: 4, format: .secondsOnly, tenths: false) == "0")
        #expect(ClockFormat.atZero(.holdZero, word: "Time", sinceZero: 4, format: .minutesAndSeconds, tenths: true) == "00:00.0")
    }

    @Test func atZeroShowsTheWord() {
        #expect(ClockFormat.atZero(.word, word: "Time", sinceZero: 4, format: .minutesAndSeconds, tenths: false) == "Time")
        #expect(ClockFormat.atZero(.word, word: "  Drink  ", sinceZero: 4, format: .minutesAndSeconds, tenths: false) == "Drink")
    }

    @Test func aBlankWordHoldsZeroInstead() {
        #expect(ClockFormat.atZero(.word, word: " ", sinceZero: 4, format: .minutesAndSeconds, tenths: false) == "00:00")
    }

    @Test func atZeroCountsOvertime() {
        #expect(ClockFormat.atZero(.overtime, word: "Time", sinceZero: 7.2, format: .minutesAndSeconds, tenths: true) == "+0:07")
    }
}
