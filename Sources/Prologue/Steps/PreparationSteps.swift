import STDesign
import STPlatform
import SwiftUI

/// Steps 2–6: one permission each (spec 4.2). Why it is needed, which tools use it, its live status, and one
/// action — Allow… or Show me how. Screen & System Audio Recording also offers Relaunch sTools.
struct PermissionStepView: View {
    let model: PrologueModel
    let permission: Permission

    private enum Copy {
        static let allow = "Allow\u{2026}"
        static let relaunchNote = "Turned it on in System Settings? macOS applies it once sTools opens again."
        static let relaunch = "Relaunch sTools"

        static func usedBy(_ permission: Permission) -> String {
            switch permission {
            case .accessibility: "NBB Overlay, Window Backdrop, Crosshair, Screen Recording"
            case .screenRecording, .appAudio, .microphone, .camera: "Screen Recording"
            }
        }

        static func howTo(_ permission: Permission) -> [String] {
            switch permission {
            case .accessibility:
                ["Press Allow\u{2026}; System Settings opens at Privacy & Security \u{25B8} Accessibility.",
                 "Turn on sTools in the list. If it isn\u{2019}t there, press + and choose sTools from Applications.",
                 "Come back here. The status turns to Ready on its own."]
            case .screenRecording:
                ["Press Allow\u{2026}; System Settings opens at Privacy & Security \u{25B8} Screen & System Audio Recording.",
                 "Turn on sTools under Screen & System Audio Recording.",
                 "If macOS asks to quit and reopen sTools, choose Later and press Relaunch sTools here instead: you\u{2019}ll come back to this step."]
            case .appAudio:
                ["Press Allow\u{2026} and choose Allow when macOS asks.",
                 "Said no before? Turn on sTools in System Settings \u{25B8} Privacy & Security \u{25B8} Screen & System Audio Recording, under System Audio Recording Only."]
            case .microphone:
                ["Press Allow\u{2026} and choose Allow when macOS asks.",
                 "Said no before? Turn on sTools in System Settings \u{25B8} Privacy & Security \u{25B8} Microphone."]
            case .camera:
                ["Press Allow\u{2026} and choose Allow when macOS asks.",
                 "Said no before? Turn on sTools in System Settings \u{25B8} Privacy & Security \u{25B8} Camera."]
            }
        }
    }

    private var isReady: Bool { model.status(of: permission) == .granted }

    var body: some View {
        PreparationPage(model: model, title: permission.title, why: permission.reason, usedBy: Copy.usedBy(permission),
                        isReady: isReady, detail: nil, howTo: Copy.howTo(permission),
                        showsFooter: permission.mayNeedRelaunch && model.relaunchOffered.contains(permission) && !isReady) {
            if !isReady {
                Button(Copy.allow) { Task { await model.allow(permission) } }
                    .buttonStyle(STButtonStyle(.secondary))
            }
        } footer: {
            HStack(spacing: 16) {
                Text(Copy.relaunchNote)
                    .stStyle(.caption)
                    .foregroundStyle(STColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    private enum Copy {
        static let checking = "Checking\u{2026}"

        static func title(_ companion: PrologueCompanion) -> String {
            switch companion {
            case .ninjabrainBot: "Ninjabrain Bot"
            case .karabiner: "Karabiner-Elements"
            }
        }

        static func why(_ companion: PrologueCompanion) -> String {
            switch companion {
            case .ninjabrainBot: "Turn on Ninjabrain Bot\u{2019}s API so sTools can read its results."
            case .karabiner: "Install and set up Karabiner-Elements so sTools can rebind keys."
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
                 "Open its settings (the gear at the top of its window) and choose Advanced.",
                 "Check \u{201C}Enable API (starts HTTP server)\u{201D}. sTools finds it at localhost:52533 within a second."]
            case .karabiner:
                ["Download Karabiner-Elements from karabiner-elements.pqrs.org (version 16.0 or later) and open it.",
                 "In Karabiner-Elements\u{2019} Settings, follow its Setup tab: allow its driver extension and the permissions it asks for.",
                 "Leave it running. sTools checks that it\u{2019}s installed, running and new enough."]
            }
        }
    }

    private var status: CompanionStatus? { model.companionStatuses[companion] }

    var body: some View {
        PreparationPage(model: model, title: Copy.title(companion), why: Copy.why(companion), usedBy: Copy.usedBy(companion),
                        isReady: status?.isReady == true, detail: status == nil ? Copy.checking : status?.detail,
                        howTo: Copy.howTo(companion), showsFooter: false) {
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

/// Numbered steps, each a sentence.
private struct HowToSteps: View {
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
                    Text(step)
                        .stStyle(.body)
                        .foregroundStyle(STColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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
