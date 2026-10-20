import STDesign
import STPlatform
import SwiftUI

// Pages still being built: each shows its title only.

struct PermissionStepView: View {
    let model: PrologueModel
    let permission: Permission
    var body: some View { StepPage { StepTitle(model: model, title: permission.title, standfirst: permission.reason) } }
}

struct CompanionStepView: View {
    let model: PrologueModel
    let companion: PrologueCompanion
    var body: some View { StepPage { StepTitle(model: model, title: companion == .ninjabrainBot ? "Ninjabrain Bot" : "Karabiner-Elements") } }
}

struct TrialStepView: View {
    let model: PrologueModel
    let trial: PrologueTrial
    var body: some View { StepPage { StepTitle(model: model, title: trial.rawValue) } }
}

struct YoureSetView: View {
    let model: PrologueModel
    var body: some View { StepPage { StepTitle(model: model, title: "You\u{2019}re set.") } }
}

struct OpenSToolsView: View {
    let model: PrologueModel
    var body: some View {
        StepPage {
            Button("Open sTools") { model.next() }
                .buttonStyle(STButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
        }
    }
}
