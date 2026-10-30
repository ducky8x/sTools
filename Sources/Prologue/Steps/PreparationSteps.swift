import STDesign
import STPlatform
import SwiftUI

/// Steps 2–6: one permission each (spec 4.2). Why it is needed, which tools use it, its live status, and one
/// action — Allow… or Show me how. Screen & System Audio Recording also offers Relaunch sTools.
struct PermissionStepView: View {
    let model: PrologueModel
    let permission: Permission

    /// Internal so the app's tests can check the tool list against the sidebar's order.
    enum Copy {
        static let allow = "Allow\u{2026}"
        static let relaunch = "Relaunch sTools"

        static func usedBy(_ permission: Permission) -> String {
            switch permission {
            case .accessibility: "Crosshair, Timer Overlay, NBB Overlay, Screen Recording, Window Backdrop"
            case .screenRecording, .appAudio, .microphone, .camera: "Screen Recording"
            }
        }

        static func howTo(_ permission: Permission) -> [String] {
            switch permission {
            case .accessibility:
                ["Press Allow. System Settings will open at Privacy & Security \u{25B8} Accessibility.",
                 "Turn on sTools in the list. If it isn\u{2019}t there, press + and choose sTools in the Applications folder."]
            case .screenRecording:
                ["Press Allow, System Settings opens at Privacy & Security \u{25B8} Screen & System Audio Recording.",
                 "Turn on sTools in the list. If it isn\u{2019}t there, press + and choose sTools in the Applications folder.",
                 "If macOS asks to quit and reopen sTools, choose Later, then press Relaunch sTools here. You\u{2019}ll come back to this step."]
            case .appAudio:
                ["Press Allow, then choose Allow when macOS asks.",
                 "If you chose Don\u{2019}t Allow before, turn on sTools in System Settings \u{25B8} Privacy & Security \u{25B8} Screen & System Audio Recording, under System Audio Recording Only."]
            case .microphone:
                ["Press Allow, then choose Allow when macOS asks.",
                 "If you chose Don\u{2019}t Allow before, turn on sTools in System Settings \u{25B8} Privacy & Security \u{25B8} Microphone."]
            case .camera:
                ["Press Allow, then choose Allow when macOS asks.",
                 "If you chose Don\u{2019}t Allow before, turn on sTools in System Settings \u{25B8} Privacy & Security \u{25B8} Camera."]
            }
        }
    }

    private var isReady: Bool { model.status(of: permission) == .granted }

    var body: some View {
        PreparationPage(model: model, title: permission.title, why: permission.reason, usedBy: Copy.usedBy(permission),
                        isReady: isReady, detail: nil, howTo: Copy.howTo(permission), note: nil,
                        showsFooter: permission.mayNeedRelaunch && model.relaunchOffered.contains(permission) && !isReady) {
            if !isReady {
                Button(Copy.allow) { Task { await model.allow(permission) } }
                    .buttonStyle(STButtonStyle(.secondary))
            }
        } footer: {
            HStack(spacing: 16) {
                Spacer(minLength: 8)
                Button(Copy.relaunch) { model.relaunch() }
                    .buttonStyle(STButtonStyle(.secondary))
            }
        }
        .onAppear { model.startPollingPermissions() }
        .onDisappear { model.stopPollingPermissions() }
    }
}

/// Steps 7 and 8: Ninjabrain Bot's API and Karabiner-Elements, checked live through the app.
struct CompanionStepView: View {
    let model: PrologueModel
    let companion: PrologueCompanion

    /// Internal so the app's tests can check the wording.
    enum Copy {
        static let checking = "Checking\u{2026}"

        static func title(_ companion: PrologueCompanion) -> String {
            switch companion {
            case .ninjabrainBot: "Ninjabrain Bot"
            case .karabiner: "Karabiner-Elements"
            }
        }

        static func why(_ companion: PrologueCompanion) -> String {
            switch companion {
            case .ninjabrainBot: "Lets sTools read Ninjabrain Bot\u{2019}s results through its API."
            case .karabiner: "Lets sTools rebind keys through Karabiner-Elements."
            }
        }

        static func usedBy(_ companion: PrologueCompanion) -> String {
            switch companion {
            case .ninjabrainBot: "NBB Overlay"
            case .karabiner: "Key Rebinder"
            }
        }

        static func howTo(_ companion: PrologueCompanion) -> [String] {
            switch companion {
            case .ninjabrainBot:
                ["Open Ninjabrain Bot.",
                 "In Ninjabrain Bot, click the gear at the top and choose Advanced.",
                 "Check \u{201C}Enable API (starts HTTP server).\u{201D}"]
            case .karabiner:
                ["Download Karabiner-Elements from [karabiner-elements.pqrs.org](https://karabiner-elements.pqrs.org) (version 16.0 or later) and open it.",
                 "Follow the Karabiner setup.",
                 "Leave it running."]
            }
        }

        /// A line under the plate; Karabiner-Elements is someone else's app (M9).
        static func note(_ companion: PrologueCompanion) -> String? {
            switch companion {
            case .ninjabrainBot: nil
            case .karabiner: "Karabiner-Elements is a third-party app that is not associated with sTools."
            }
        }
    }

    private var status: CompanionStatus? { model.companionStatuses[companion] }

    var body: some View {
        PreparationPage(model: model, title: Copy.title(companion), why: Copy.why(companion), usedBy: Copy.usedBy(companion),
                        isReady: status?.isReady == true, detail: status == nil ? Copy.checking : status?.detail,
                        howTo: Copy.howTo(companion), note: Copy.note(companion), showsFooter: false) {
            if let title = status?.actionTitle, status?.isReady == false {
                Button(title) { model.performAction(for: companion) }
                    .buttonStyle(STButtonStyle(.secondary))
            }
        } footer: {
            EmptyView()
        }
        .onAppear { model.startWatching(companion) }
        .onDisappear { model.stopWatching(companion) }
    }
}

private enum PreparationCopy {
    static let usedBy = "Used by"
    static let ready = "Ready"
    static let notSetUp = "Not set up"
    static let showMeHow = "Show me how"
    static let hide = "Hide steps"
}

/// The shared layout of a Preparations step: title, why, used by, and a plate with the live status, the action,
/// and Show me how.
private struct PreparationPage<Actions: View, Footer: View>: View {
    let model: PrologueModel
    let title: String
    let why: String
    let usedBy: String
    let isReady: Bool
    let detail: String?
    let howTo: [String]
    /// A caption under the plate, when the step has one.
    let note: String?
    let showsFooter: Bool
    @ViewBuilder let actions: Actions
    @ViewBuilder let footer: Footer

    @Environment(\.stTheme) private var theme
    @State private var showsHow = false

    var body: some View {
        StepPage {
            StepTitle(model: model, title: title, standfirst: why)
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(PreparationCopy.usedBy)
                    .stStyle(.label)
                    .foregroundStyle(theme.inkTertiary)
                Text(usedBy)
                    .stStyle(.body)
                    .foregroundStyle(theme.inkSecondary)
            }
            .padding(.top, 16)
            .accessibilityElement(children: .combine)

            STPlate {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 14) {
                        StatusMark(isDone: isReady)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(isReady ? PreparationCopy.ready : PreparationCopy.notSetUp)
                                .stStyle(.sectionTitle)
                                .foregroundStyle(isReady ? STColor.ink : theme.inkSecondary)
                                .contentTransition(.opacity)
                            if let detail {
                                Text(detail)
                                    .stStyle(.caption)
                                    .foregroundStyle(theme.inkTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        Spacer(minLength: 12)
                        actions
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    .stAnimation(STMotion.standard, value: isReady)

                    footerSection

                    Rectangle().fill(STColor.rule).frame(height: 1).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 12) {
                        Button(showsHow ? PreparationCopy.hide : PreparationCopy.showMeHow) { showsHow.toggle() }
                            .buttonStyle(STButtonStyle(.quiet))
                        if showsHow {
                            HowToSteps(steps: howTo)
                                .transition(.opacity.combined(with: .offset(y: -4)))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .stAnimation(STMotion.standard, value: showsHow)
                }
            }
            .padding(.top, 22)

            if let note {
                Text(note)
                    .stStyle(.caption)
                    .foregroundStyle(theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
        }
    }

    @ViewBuilder private var footerSection: some View {
        if showsFooter {
            VStack(spacing: 0) {
                Rectangle().fill(STColor.rule).frame(height: 1).accessibilityHidden(true)
                footer
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .transition(.opacity)
        }
    }
}

/// Numbered steps, each a sentence. A step may hold a Markdown link (`[text](https://…)`), which shows as a
/// clickable link.
struct HowToSteps: View {
    let steps: [String]
    @Environment(\.stTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .font(STFont.figures(13 * theme.textScale, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 14, alignment: .leading)
                    Text(Self.text(of: step))
                        .stStyle(.body)
                        .foregroundStyle(STColor.ink)
                        .tint(theme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The step with its Markdown links made clickable; any other text is shown as it is.
    static func text(of step: String) -> AttributedString {
        guard step.contains("](") else { return AttributedString(step) }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: step, options: options)) ?? AttributedString(step)
    }
}

/// A hairline ring that a gold seal stamps over when done.
struct StatusMark: View {
    let isDone: Bool
    @Environment(\.stTheme) private var theme

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(theme.stroke, lineWidth: 1.25)
                .frame(width: 22 * theme.textScale, height: 22 * theme.textScale)
                .opacity(isDone ? 0 : 1)
            STSeal(isStamped: isDone)
        }
        .accessibilityHidden(!isDone)
    }
}
