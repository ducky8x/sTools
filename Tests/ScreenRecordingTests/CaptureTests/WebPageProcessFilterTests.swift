import CoreAudio
import Foundation
import Testing
@testable import ScreenRecording

/// Which of Core Audio's audio processes are sTools' own web pages' helpers. The processes are made up, and so is who
/// works for whom: nothing here asks Core Audio or the system anything.
@Suite("Which audio processes are sTools' web pages'")
struct WebPageProcessFilterTests {
    /// sTools is process 100 and works for itself. Its WebKit helpers are 201 (graphics and media) and 202 (web
    /// content). Safari is 300, with helpers 301 and 302 of the same names. 203 is an XPC service of sTools' that is
    /// not WebKit's.
    private let worksFor: [Int32: Int32] = [100: 100, 201: 100, 202: 100, 203: 100, 300: 300, 301: 300, 302: 300]

    private func process(_ object: AudioObjectID, _ pid: Int32, _ bundleID: String) -> AudioProcessInfo {
        AudioProcessInfo(object: object, pid: pid, bundleID: bundleID)
    }

    private var everything: [AudioProcessInfo] {
        [
            process(11, 100, "com.ducky8x.sTools"),
            process(12, 201, "com.apple.WebKit.GPU"),
            process(13, 202, "com.apple.WebKit.WebContent"),
            process(14, 203, "com.example.SomeService"),
            process(15, 300, "com.apple.Safari"),
            process(16, 301, "com.apple.WebKit.GPU"),
            process(17, 302, "com.apple.WebKit.WebContent"),
        ]
    }

    private func filtered(_ processes: [AudioProcessInfo], ownPID: Int32 = 100, worksFor: [Int32: Int32]? = nil) -> [AudioObjectID] {
        let table = worksFor ?? self.worksFor
        return ProcessTapCapture.ownWebViewProcesses(among: processes, ownPID: ownPID, responsiblePID: { table[$0] })
    }

    @Test func itKeepsTheWebKitHelpersThatWorkForSTools() {
        #expect(filtered(everything) == [12, 13])
    }

    /// Safari's tabs have helpers with the very same bundle IDs; they work for Safari, so they are never in it.
    @Test func anotherAppsWebPagesAreNeverIn() {
        let safariOnly = everything.filter { [15, 16, 17].contains($0.object) }
        #expect(filtered(safariOnly).isEmpty)
        #expect(!filtered(everything).contains(16) && !filtered(everything).contains(17))
    }

    /// sTools' own process plays its interface sounds and Timer Overlay's alarm; they are not web pages.
    @Test func sToolsOwnProcessIsNeverIn() {
        #expect(!filtered(everything).contains(11))
        // Even a process of sTools' that carries a WebKit bundle ID is left out when it is sTools' own.
        #expect(filtered([process(21, 100, "com.apple.WebKit.GPU")]).isEmpty)
    }

    @Test func aProcessThatIsNotWebKitsIsNeverIn() {
        #expect(!filtered(everything).contains(14))
        #expect(filtered([process(31, 201, "com.apple.WebKitFake.GPU")]).isEmpty, "the prefix ends at the dot")
    }

    /// When the system can't say whom a helper works for, no sound is better than another app's.
    @Test func aHelperWhoseOwnerIsUnknownIsLeftOut() {
        #expect(filtered(everything, worksFor: [100: 100, 202: 100]) == [13], "201 has no answer")
        #expect(filtered(everything, worksFor: [:]).isEmpty, "the system answers nothing at all")
    }

    /// An app started from a terminal or a debugger works for that program, and so do its helpers; either way they are
    /// its own.
    @Test func anAppStartedByAnotherProgramStillFindsItsHelpers() {
        let startedByATerminal: [Int32: Int32] = [100: 90, 201: 90, 202: 100, 300: 300, 301: 300]
        #expect(filtered(everything, worksFor: startedByATerminal) == [12, 13])
    }

    @Test func theAnswerKeepsCoreAudiosOrder() {
        let reversed = Array(everything.reversed())
        #expect(filtered(reversed) == [13, 12])
    }
}

/// The one private call this feature makes. These ask the system nothing about sound, so they cost no permission.
@Suite("Who a process works for")
struct ProcessResponsibilityTests {
    /// If a macOS update takes the call away, this fails, and the web pages' sound is silent for a reason one test
    /// names, instead of being silent in a recording.
    @Test func thisMacAnswers() {
        #expect(ProcessResponsibility.isAvailable)
        #expect(ProcessResponsibility.responsiblePID(of: getpid()).map { $0 > 0 } == true)
    }

    @Test func aProcessThatIsNotThereHasNoAnswer() {
        #expect(ProcessResponsibility.responsiblePID(of: 2_000_000_000) == nil)
    }
}
