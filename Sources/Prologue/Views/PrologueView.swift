import STDesign
import SwiftUI

/// The whole introduction inside the main window: the progress line and the gold progress rule on top, the step
/// as a page that slides (forward from the right, back from the left), and the controls along the bottom
/// (spec 4.1). The greeting shows on its own, without chrome. While motion is reduced pages change in place and
/// every step shows its final state at once; reducing motion mid-step completes whatever was playing.
public struct PrologueView: View {
    private let model: PrologueModel

    @Environment(\.stTheme) private var theme
    @Environment(\.stSoundPlayer) private var sound

    public init(model: PrologueModel) {
        self.model = model
    }

    private var flow: PrologueFlow { model.flow }
    private var showsChrome: Bool { flow.step != .greeting }

    public var body: some View {
        ZStack(alignment: .top) {
            STColor.background
            VStack(spacing: 0) {
                if showsChrome {
                    PrologueProgressHeader(flow: flow)
                        .transition(.opacity)
                }
                pages
                if showsChrome {
                    PrologueFooter(model: model)
                        .transition(.opacity)
                }
            }
            if showsChrome {
                PrologueProgressRule(progress: flow.progress)
                    .transition(.opacity)
            }
            if flow.isConfirmingSkip {
                SkipIntroductionPrompt(model: model)
                    .transition(.opacity)
            }
            PrologueShortcuts(model: model)
        }
        .animation(STMotion.resolve(STMotion.standard, reduce: theme.reduceMotion), value: showsChrome)
        .animation(STMotion.resolve(.easeOut(duration: 0.2), reduce: theme.reduceMotion), value: flow.isConfirmingSkip)
        .background(AnimationCompleter(animations: model.animations))
        .onChange(of: flow.visit) { _, _ in sound.play(.page) }
        .onChange(of: theme.reduceMotion) { _, reduced in
            guard reduced else { return }
            model.animations.completeAll()
            // The Finale can outlast its title's gate, so finish it here too.
            model.completeFinale()
        }
    }

    private var pages: some View {
        ZStack {
            page(for: flow.step)
                .id(flow.visit)
                .transition(.asymmetric(
                    insertion: .modifier(active: PageSlide(model: model, isInsertion: true, isActive: true),
                                         identity: PageSlide(model: model, isInsertion: true, isActive: false)),
                    removal: .modifier(active: PageSlide(model: model, isInsertion: false, isActive: true),
                                       identity: PageSlide(model: model, isInsertion: false, isActive: false))))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(STMotion.resolve(STMotion.page, reduce: theme.reduceMotion), value: flow.visit)
    }

    @ViewBuilder private func page(for step: PrologueStep) -> some View {
        if step == .greeting {
            GreetingView(model: model, settled: theme.reduceMotion)
        } else if let permission = step.permission {
            PermissionStepView(model: model, permission: permission)
        } else if let companion = step.companion {
            CompanionStepView(model: model, companion: companion)
        } else if let trial = step.trial {
            TrialStepView(model: model, trial: trial)
        } else if step == .youreSet {
            YoureSetView(model: model, settled: theme.reduceMotion)
        } else {
            OpenSToolsView(model: model)
        }
    }
}

/// The page turn. It reads the direction from the model when it renders, so a page leaving after a Back slides the
/// right way even though it was put up by a Continue.
private struct PageSlide: ViewModifier {
    let model: PrologueModel
    let isInsertion: Bool
    let isActive: Bool

    @Environment(\.stTheme) private var theme

    func body(content: Content) -> some View {
        let sign: CGFloat = model.flow.direction == .forward ? 1 : -1
        let distance: CGFloat = theme.reduceMotion ? 0 : 64
        let x = isActive ? (isInsertion ? sign * distance : -sign * distance) : 0
        content
            .offset(x: x)
            .opacity(isActive ? 0 : 1)
    }
}

/// Part names and the step count (spec D12).
struct PrologueProgressHeader: View {
    let flow: PrologueFlow
    @Environment(\.stTheme) private var theme

    var body: some View {
        // Centered when there's room; beside the count when the sidebar is back and the page is narrower.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                count.hidden()
                Spacer(minLength: 16)
                parts
                Spacer(minLength: 16)
                count
            }
            HStack(spacing: 0) {
                parts
                Spacer(minLength: 12)
                count
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(flow.step.part.title), step \(flow.step.number) of \(PrologueStep.count)")
    }

    private var parts: some View {
        HStack(spacing: 10) {
            ForEach(ProloguePart.allCases, id: \.self) { part in
                Text(part.title)
                    .stStyle(.label)
                    .foregroundStyle(color(for: part))
                if part != ProloguePart.allCases.last {
                    Text("\u{00B7}").stStyle(.label).foregroundStyle(theme.inkTertiary)
                }
            }
        }
        .fixedSize()
    }

    private var count: some View {
        Text("Step \(flow.step.number) of \(PrologueStep.count)")
            .stStyle(.label)
            .foregroundStyle(theme.inkTertiary)
            .monospacedDigit()
            .fixedSize()
    }

    private func color(for part: ProloguePart) -> Color {
        if part == flow.step.part { return theme.accent }
        return part.rawValue < flow.step.part.rawValue ? theme.inkSecondary : theme.inkTertiary
    }
}

/// The thin gold rule across the top of the window that fills as the introduction goes on.
struct PrologueProgressRule: View {
    let progress: Double
    @Environment(\.stTheme) private var theme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(STColor.rule)
                Rectangle().fill(theme.accent).frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: 2)
        .stAnimation(STMotion.standard, value: progress)
        .accessibilityHidden(true)
    }
}

/// Back, Skip introduction, Skip step and Continue (spec 4.1). The keys live in `PrologueShortcuts`.
struct PrologueFooter: View {
    let model: PrologueModel

    private enum Copy {
        static let back = "Back"
        static let skipIntroduction = "Skip introduction"
        static let skipStep = "Skip step"
        static let next = "Continue"
    }

    private var flow: PrologueFlow { model.flow }
    private var isLast: Bool { flow.isLastStep }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(STColor.rule).frame(height: 1).accessibilityHidden(true)
            HStack(spacing: 20) {
                Button(Copy.back) { model.back() }
                    .buttonStyle(STButtonStyle(.secondary))
                    .disabled(!flow.canGoBack)
                    .help("Back (\u{2318}[)")
                if !isLast {
                    Button(Copy.skipIntroduction) { model.requestSkipIntroduction() }
                        .buttonStyle(STButtonStyle(.quiet))
                        .help("Skip introduction (Esc)")
                }
                Spacer(minLength: 12)
                if !isLast {
                    Button(Copy.skipStep) { model.skipStep() }
                        .buttonStyle(STButtonStyle(.quiet))
                        .help("Skip step (\u{2318}])")
                    Button(Copy.next) { model.next() }
                        .buttonStyle(STButtonStyle(.primary))
                        .keyboardShortcut(.defaultAction)
                        .help("Continue (Return)")
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .disabled(flow.isConfirmingSkip)
    }
}

/// The keys that work on every step, the greeting included: ⌘[ Back, ⌘] Skip step, Esc Skip introduction (or, while
/// it asks, Keep going).
struct PrologueShortcuts: View {
    let model: PrologueModel

    var body: some View {
        ZStack {
            Button("Back") { model.back() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.flow.canGoBack)
            Button("Skip step") { model.skipStep() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.flow.canMoveOn || model.flow.isLastStep)
            Button("Skip introduction") {
                if model.flow.isConfirmingSkip { model.cancelSkipIntroduction() } else { model.requestSkipIntroduction() }
            }
            .keyboardShortcut(.cancelAction)
            .disabled(model.flow.isLastStep && !model.flow.isConfirmingSkip)
        }
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// "Skip the introduction? You can replay it from the Help menu." — Skip / Keep going (spec 4.1, D11).
struct SkipIntroductionPrompt: View {
    let model: PrologueModel

    private enum Copy {
        static let question = "Skip the introduction?"
        static let detail = "You can replay it from the Help menu."
        static let skip = "Skip"
        static let keepGoing = "Keep going"
    }

    @Environment(\.stTheme) private var theme

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .contentShape(Rectangle())
                .onTapGesture { model.cancelSkipIntroduction() }
                .accessibilityHidden(true)
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            VStack(alignment: .leading, spacing: 0) {
                Text(Copy.question)
                    .stStyle(.sectionTitle)
                    .foregroundStyle(STColor.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(Copy.detail)
                    .stStyle(.body)
                    .foregroundStyle(theme.inkSecondary)
                    .padding(.top, 8)
                HStack(spacing: 12) {
                    Spacer()
                    Button(Copy.skip) { model.confirmSkipIntroduction() }
                        .buttonStyle(STButtonStyle(.secondary))
                    Button(Copy.keepGoing) { model.cancelSkipIntroduction() }
                        .buttonStyle(STButtonStyle(.primary))
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 22)
            }
            .padding(24)
            .frame(width: 400)
            .background(STColor.raised, in: shape)
            .overlay { shape.strokeBorder(STColor.rule, lineWidth: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }
}
