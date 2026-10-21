import STDesign
import SwiftUI

/// Step 1, the welcome ceremony (spec 4.2; about four seconds): pure black fades up to the app's near-black, the
/// mark draws itself in fine gold lines and fills, the wordmark typewrites, a gilt rule draws beneath it, the line
/// typewrites, a soft chime, and Begin. Any click or key completes it at once. With Reduce Motion each stage is a
/// short crossfade.
struct GreetingView: View {
    let model: PrologueModel

    private enum Copy {
        static let wordmark = "sTools"
        static let line = "Five instruments for running Minecraft on a Mac."
        static let begin = "Begin"
    }

    @Environment(\.stTheme) private var theme
    @Environment(\.stSoundPlayer) private var sound

    @State private var blackout = 1.0
    @State private var markOpacity = 1.0
    @State private var lines = 0.0
    @State private var fill = 0.0
    @State private var typesWordmark = false
    @State private var drawsRule = false
    @State private var typesLine = false
    @State private var showsBegin = false
    @State private var ceremony: Task<Void, Never>?

    /// How long the full ceremony runs, Begin included.
    static let length: Duration = .milliseconds(4_100)

    var body: some View {
        ZStack {
            STColor.background
            VStack(spacing: 0) {
                Spacer(minLength: 20)
                // The app icon's gold, whatever the accent color is set to.
                PrologueMark(lineProgress: lines, fillAmount: fill, lineColor: STColor.gold, fillColor: STColor.gold, lineWidth: 1.25)
                    .frame(width: 168, height: 128)
                    .opacity(markOpacity)
                TypewriterText(text: Copy.wordmark, isStarted: typesWordmark,
                               completionCount: model.animations.completionCount, fadeSpan: 12)
                    .font(STFont.greetingWordmark(72 * theme.textScale))
                    .tracking(-0.72 * theme.textScale)
                    .foregroundStyle(STColor.ink)
                    .padding(.top, 30)
                    .accessibilityAddTraits(.isHeader)
                DrawnRule(isDrawn: drawsRule)
                    .frame(width: 236)
                    .padding(.top, 4)
                TypewriterText(text: Copy.line, isStarted: typesLine, completionCount: model.animations.completionCount, fadeSpan: 6)
                    // New York italic, as the spec asks: the bundled text face has no italic.
                    .font(.system(size: 17 * theme.textScale, design: .serif).italic())
                    .foregroundStyle(theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)
                    .padding(.horizontal, 32)
                ZStack {
                    if showsBegin {
                        Button(Copy.begin) { model.next() }
                            .buttonStyle(STButtonStyle(.primary))
                            .keyboardShortcut(.defaultAction)
                            .transition(theme.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                    }
                }
                .frame(height: 40)
                .padding(.top, 34)
                Spacer(minLength: 20)
            }
            Color.black
                .opacity(blackout)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onAppear(perform: begin)
        .onDisappear { ceremony?.cancel() }
        .onChange(of: model.animations.completionCount) { _, _ in completeNow() }
    }

    private func begin() {
        model.animations.run(for: Self.length)
        ceremony = Task { @MainActor in
            if theme.reduceMotion { await playReduced() } else { await playFull() }
        }
    }

    private func playFull() async {
        withAnimation(.easeOut(duration: 0.8)) { blackout = 0 }
        guard await pause(0.35) else { return }
        withAnimation(.easeInOut(duration: 1.5)) { lines = 1 }
        guard await pause(1.3) else { return }
        withAnimation(.easeOut(duration: 0.6)) { fill = 1 }
        guard await pause(0.4) else { return }
        typesWordmark = true
        guard await pause(0.3) else { return }
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.7)) { drawsRule = true }
        guard await pause(0.3) else { return }
        typesLine = true
        guard await pause(1.0) else { return }
        sound.play(.chime)
        withAnimation(STMotion.standard) { showsBegin = true }
    }

    /// Reduce Motion: the same stages, each a short crossfade; nothing draws, rises or types.
    private func playReduced() async {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            markOpacity = 0
            lines = 1
            fill = 1
        }
        withAnimation(STMotion.reducedFade) { blackout = 0 }
        guard await pause(0.3) else { return }
        withAnimation(STMotion.reducedFade) { markOpacity = 1 }
        guard await pause(0.4) else { return }
        typesWordmark = true
        withAnimation(STMotion.reducedFade) { drawsRule = true }
        guard await pause(0.4) else { return }
        typesLine = true
        guard await pause(0.4) else { return }
        sound.play(.chime)
        withAnimation(STMotion.reducedFade) { showsBegin = true }
    }

    /// Sleeps; false when the ceremony was completed or left meanwhile.
    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        return !Task.isCancelled
    }

    private func completeNow() {
        ceremony?.cancel()
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            blackout = 0
            markOpacity = 1
            lines = 1
            fill = 1
            typesWordmark = true
            drawsRule = true
            typesLine = true
            showsBegin = true
        }
    }
}

/// A 1 pt accent rule that draws out from its center when `isDrawn` turns true.
struct DrawnRule: View {
    let isDrawn: Bool
    @Environment(\.stTheme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.accent)
            .frame(height: 1)
            .scaleEffect(x: isDrawn ? 1 : 0, anchor: .center)
            .accessibilityHidden(true)
    }
}
