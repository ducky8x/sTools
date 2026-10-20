import STDesign
import SwiftUI

/// The typewriter reveal (spec 3.4 `type`): characters arrive 18 ms apart, each settling in with a short fade and
/// a 2 pt rise. The full text is laid out from the start, so nothing reflows as it types. A bump of
/// `completionCount` shows everything at once; with Reduce Motion the whole text crossfades in instead.
struct TypewriterText: View {
    let text: String
    /// Typing starts when this becomes true (immediately, if it already is).
    let isStarted: Bool
    let completionCount: Int
    /// How many characters' worth of time each one takes to fade in; longer is softer.
    var fadeSpan: Double = 5
    var onFinished: () -> Void = {}

    @Environment(\.stTheme) private var theme
    @State private var progress: Double = 0
    @State private var hasStarted = false
    @State private var hasFinished = false
    /// `completionCount` when this appeared: a later value means "complete" arrived before the typing began.
    @State private var countAtAppear: Int?

    private var target: Double { Double(text.count) + fadeSpan }

    /// How long the typing takes, for the animation gate.
    static func duration(of text: String, fadeSpan: Double = 5) -> Duration {
        .milliseconds(Int((Double(text.count) + fadeSpan) * 18))
    }

    var body: some View {
        Group {
            if theme.reduceMotion {
                Text(text).opacity(progress > 0 ? 1 : 0)
            } else {
                Text(text).textRenderer(TypewriterRenderer(progress: progress, fadeSpan: fadeSpan))
            }
        }
        .onAppear {
            if countAtAppear == nil { countAtAppear = completionCount }
            if isStarted { start() }
        }
        .onChange(of: isStarted) { _, started in if started { start() } }
        .onChange(of: completionCount) { _, _ in finishNow() }
    }

    private func start() {
        guard !hasStarted else { return }
        if let countAtAppear, countAtAppear != completionCount {
            finishNow()
            return
        }
        hasStarted = true
        let animation = theme.reduceMotion ? STMotion.reducedFade : .linear(duration: target * 0.018)
        withAnimation(animation) { progress = target } completion: { finish() }
    }

    private func finishNow() {
        guard hasStarted || isStarted, !hasFinished else { return }
        hasStarted = true
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { progress = target }
        finish()
    }

    private func finish() {
        guard !hasFinished else { return }
        hasFinished = true
        onFinished()
    }
}

/// Draws glyph `i` at opacity `(progress - i) / fadeSpan`, risen by up to 2 pt while it fades in.
private struct TypewriterRenderer: TextRenderer {
    var progress: Double
    let fadeSpan: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var index = 0.0
        for line in layout {
            for run in line {
                for glyph in run {
                    let amount = min(max((progress - index) / fadeSpan, 0), 1)
                    index += 1
                    guard amount > 0 else { continue }
                    var copy = context
                    copy.opacity = amount
                    copy.translateBy(x: 0, y: (1 - amount) * 2)
                    copy.draw(glyph)
                }
            }
        }
    }
}
