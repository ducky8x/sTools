import STDesign
import SwiftUI

/// Step 14 (spec 4.2): "You're set." typewrites, a rule draws, and every tool switched on during the trials turns
/// off in turn — the sidebar is back, so each switch can be seen going off.
struct YoureSetView: View {
    let model: PrologueModel

    private enum Copy {
        static let title = "You\u{2019}re set."
        static let line = "The tools you tried are off again. Switch any of them on from the sidebar whenever you play."
    }

    @Environment(\.stTheme) private var theme
    @Environment(\.stSoundPlayer) private var sound
    @State private var typed = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            TypewriterText(text: Copy.title, isStarted: true, completionCount: model.animations.completionCount,
                           fadeSpan: 8, onFinished: finishTyping)
                .font(STFont.display(56 * theme.textScale))
                .foregroundStyle(STColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
            DrawnRule(isDrawn: typed)
                .frame(width: 180)
                .padding(.top, 14)
            Text(Copy.line)
                .stStyle(.standfirst)
                .foregroundStyle(theme.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
                .padding(.top, 18)
                .opacity(typed ? 1 : 0)
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            model.animations.run(for: TypewriterText.duration(of: Copy.title, fadeSpan: 8) + .milliseconds(900))
        }
        .onChange(of: model.animations.completionCount) { _, _ in
            finishTyping()
            model.completeFinale()
        }
        .onChange(of: model.finaleSwitchedOff.count) { old, new in
            if new > old { sound.play(.click) }
        }
    }

    private func finishTyping() {
        guard !typed else { return }
        withAnimation(STMotion.resolve(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.6), reduce: theme.reduceMotion)) {
            typed = true
        }
        model.runFinale()
    }
}

/// Step 15: Open sTools, and the introduction slides away to Home.
struct OpenSToolsView: View {
    let model: PrologueModel

    private enum Copy {
        static let line = "Everything you set up is waiting on Home."
        static let open = "Open sTools"
        static let replay = "Replay this introduction any time from Help \u{25B8} Replay Introduction."
    }

    @Environment(\.stTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            PrologueMark(lineProgress: 1, fillAmount: 1, lineColor: STColor.gold, fillColor: STColor.gold)
                .frame(width: 108, height: 82)
            Text(Copy.line)
                .stStyle(.standfirst)
                .foregroundStyle(theme.inkSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 28)
            Button(Copy.open) { model.next() }
                .buttonStyle(STButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .padding(.top, 26)
            Text(Copy.replay)
                .stStyle(.caption)
                .foregroundStyle(theme.inkTertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 22)
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
