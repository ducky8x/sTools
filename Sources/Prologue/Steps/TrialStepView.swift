import STDesign
import SwiftUI

/// Steps 9–14: one tool tried on the real screen (spec 4.2). The checklist on the left ticks itself as the user
/// does each thing, each item can be skipped; the tool's own controls sit on the right.
struct TrialStepView: View {
    let model: PrologueModel
    let trial: PrologueTrial

    private enum Copy {
        static func title(_ trial: PrologueTrial) -> String {
            switch trial {
            case .crosshair: "Crosshair"
            case .timerOverlay: "Timer Overlay"
            case .windowBackdrop: "Window Backdrop"
            case .nbbOverlay: "NBB Overlay"
            case .screenRecording: "Screen Recording"
            case .keyRebinder: "Key Rebinder"
            }
        }

        static func standfirst(_ trial: PrologueTrial) -> String {
            switch trial {
            case .crosshair: "Try it out. Items tick themselves as you go."
            case .timerOverlay: "Run a test countdown. Items tick themselves as you go."
            case .windowBackdrop: "Hide everything behind the game. Items tick themselves as you go."
            case .nbbOverlay: "Show Ninjabrain Bot over the game. Items tick themselves as you go."
            case .screenRecording: "Arrange a canvas and record a short test. Items tick themselves as you go."
            case .keyRebinder: "See your rebinds on the keyboard. Items tick themselves as you go."
            }
        }
    }

    var body: some View {
        if let content = model.host?.trial(trial) {
            TrialPage(model: model, trial: trial, title: Copy.title(trial), standfirst: Copy.standfirst(trial), content: content)
        } else {
            StepPage { StepTitle(model: model, title: Copy.title(trial), standfirst: Copy.standfirst(trial)) }
        }
    }
}

private struct TrialPage: View {
    let model: PrologueModel
    let trial: PrologueTrial
    let title: String
    let standfirst: String
    let content: TrialContent

    var body: some View {
        let items = content.items()
        let done = content.completed()
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(model: model, title: title, standfirst: standfirst)
                .padding(.horizontal, 28)
                .padding(.top, 26)
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    TrialChecklist(model: model, trial: trial, items: items)
                        .padding(.leading, 28)
                        .padding(.trailing, 18)
                        .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
                .frame(width: 262)
                Rectangle().fill(STColor.rule).frame(width: 1).accessibilityHidden(true)
                ScrollView {
                    content.controls()
                        .padding(.leading, 20)
                        .padding(.trailing, 24)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
            }
            .frame(maxHeight: .infinity)
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: done, initial: true) { _, ids in model.record(done: ids, items: items, for: trial) }
        .onAppear(perform: content.onAppear)
        .onDisappear(perform: content.onDisappear)
    }
}

/// The checklist: a ring per item that a seal stamps over when it's done, Skip for anything still to do.
private struct TrialChecklist: View {
    let model: PrologueModel
    let trial: PrologueTrial
    let items: [ChecklistItem]

    private enum Copy {
        static let skip = "Skip"
        static let skipped = "Skipped"
        static let optional = "Optional"
        static let allDone = "All done. Continue when you\u{2019}re ready."

        static func progress(_ done: Int, of total: Int) -> String { "\(done) of \(total) done" }
    }

    @Environment(\.stTheme) private var theme

    var body: some View {
        let list = model.checklist(for: trial, items: items)
        // The same condition as Continue's (`PrologueModel.canContinue`): every item, optional ones too, done or skipped.
        let isComplete = list.isComplete
        VStack(alignment: .leading, spacing: 0) {
            let next = items.first { list.state(of: $0.id) == .pending }?.id
            ForEach(items) { item in
                row(item, state: list.state(of: item.id), isNext: item.id == next)
                if item.id != items.last?.id {
                    Rectangle().fill(STColor.rule).frame(height: 1).accessibilityHidden(true)
                }
            }
            Text(isComplete ? Copy.allDone : Copy.progress(list.doneCount, of: items.count))
                .stStyle(.caption)
                .foregroundStyle(isComplete ? theme.accent : theme.inkTertiary)
                .padding(.top, 14)
                .contentTransition(.opacity)
                .stAnimation(STMotion.standard, value: isComplete)
        }
    }

    private func row(_ item: ChecklistItem, state: ChecklistItemState, isNext: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StatusMark(isDone: state == .done)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .stStyle(.body)
                    .foregroundStyle(state == .pending || state == .done ? STColor.ink : theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = note(for: item, state: state, isNext: isNext) {
                    Text(note)
                        .stStyle(.caption)
                        .foregroundStyle(theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
                tags(item, state: state)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .stAnimation(STMotion.quick, value: state)
        .stAnimation(STMotion.standard, value: isNext)
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if state == .pending {
                Button(Copy.skip) { model.skipItem(item.id, items: items, in: trial) }
            }
        }
    }

    private func note(for item: ChecklistItem, state: ChecklistItemState, isNext: Bool) -> String? {
        if state == .unavailable { return item.unavailableReason }
        return state == .pending && isNext ? item.detail : nil
    }

    /// Optional and Skipped as small caps, and Skip for anything still to do.
    @ViewBuilder private func tags(_ item: ChecklistItem, state: ChecklistItemState) -> some View {
        let words = [item.isOptional ? Copy.optional : nil, state == .skipped ? Copy.skipped : nil].compactMap { $0 }
        if !words.isEmpty || state == .pending {
            HStack(spacing: 10) {
                if !words.isEmpty {
                    Text(words.joined(separator: " \u{00B7} "))
                        .stStyle(.label)
                        .foregroundStyle(theme.inkTertiary)
                }
                if state == .pending {
                    Button(Copy.skip) { model.skipItem(item.id, items: items, in: trial) }
                        .buttonStyle(STButtonStyle(.quiet))
                        .accessibilityHidden(true)
                }
            }
        }
    }
}
