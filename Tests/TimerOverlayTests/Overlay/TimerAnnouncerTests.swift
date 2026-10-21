import Testing
@testable import TimerOverlay

@Suite("Timer announcer")
@MainActor
struct TimerAnnouncerTests {
    @Test func theStartSaysTheDurationInWords() {
        #expect(TimerAnnouncement.started(seconds: 150).text == "Timer started, 2 minutes 30 seconds")
    }

    @Test(arguments: [
        (1, "1 second"), (5, "5 seconds"), (60, "1 minute"), (61, "1 minute 1 second"), (120, "2 minutes"),
        (3600, "1 hour"), (3661, "1 hour 1 minute 1 second"), (7200, "2 hours"), (5400, "1 hour 30 minutes"),
        (359_999, "99 hours 59 minutes 59 seconds"), (0, "0 seconds"),
    ])
    func durationsReadAsWords(seconds: Int, words: String) {
        #expect(TimerAnnouncement.started(seconds: seconds).text == "Timer started, " + words)
    }

    @Test func timesUpSaysSo() {
        #expect(TimerAnnouncement.timesUp.text == "Time\u{2019}s up")
    }

    /// The live announcer hands its text to the post it was given; tests never post a real announcement.
    @Test func theAnnouncerPostsEachAnnouncementOnce() {
        var posted: [String] = []
        let announcer = TimerAnnouncer(post: { posted.append($0) })
        announcer.announce(.started(seconds: 150))
        announcer.announce(.timesUp)
        #expect(posted == ["Timer started, 2 minutes 30 seconds", "Time\u{2019}s up"])
    }
}
