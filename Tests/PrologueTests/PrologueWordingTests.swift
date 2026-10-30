import Foundation
import STPlatform
import Testing
@testable import Prologue

/// The Preparations steps' wording after ducky's M9 review: the shorter how-to lists, the Karabiner-Elements link
/// and its note.
@MainActor
@Suite("Prologue wording")
struct PrologueWordingTests {
    /// Accessibility's how-to ends once sTools is on in the list: the status turns to Ready by itself.
    @Test func accessibilityHowToHasTwoSteps() {
        #expect(PermissionStepView.Copy.howTo(.accessibility) == [
            "Press Allow. System Settings will open at Privacy & Security \u{25B8} Accessibility.",
            "Turn on sTools in the list. If it isn\u{2019}t there, press + and choose sTools in the Applications folder.",
        ])
    }

    /// Every path in the how-to lists keeps the ▸ triangle.
    @Test func settingsPathsKeepTheTriangle() {
        for permission in Permission.allCases {
            for step in PermissionStepView.Copy.howTo(permission) where step.contains("Privacy & Security") {
                #expect(step.contains("\u{25B8}"), "\(step)")
            }
        }
    }

    /// The download site in Karabiner-Elements' first step is a link; the step reads as plain text around it.
    @Test func karabinerDownloadSiteIsALink() throws {
        let step = try #require(CompanionStepView.Copy.howTo(.karabiner).first)
        let text = HowToSteps.text(of: step)
        #expect(String(text.characters)
            == "Download Karabiner-Elements from karabiner-elements.pqrs.org (version 16.0 or later) and open it.")
        let links = text.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://karabiner-elements.pqrs.org")!])
    }

    /// A step without a link is shown exactly as written, Markdown-looking characters included.
    @Test func stepsWithoutALinkStayAsWritten() {
        let step = "Turn on sTools in the list. If it isn\u{2019}t there, press + and choose sTools in the Applications folder."
        #expect(String(HowToSteps.text(of: step).characters) == step)
        #expect(HowToSteps.text(of: step).runs.allSatisfy { $0.link == nil })
    }

    /// Karabiner-Elements' step says it's a third-party app; Ninjabrain Bot's step has no such line.
    @Test func karabinerStepCarriesTheThirdPartyNote() {
        #expect(CompanionStepView.Copy.note(.karabiner)
            == "Karabiner-Elements is a third-party app that is not associated with sTools.")
        #expect(CompanionStepView.Copy.note(.ninjabrainBot) == nil)
    }
}
