import SwiftUI

/// A 1 pt accent line under a page title. It draws left to right over 0.6 s when it appears;
/// while motion is reduced, or with `animatesIn == false`, it is simply there.
public struct STGiltRule: View {
    private let animatesIn: Bool

    @Environment(\.stTheme) private var theme
    @State private var isDrawn: Bool

    public init(animatesIn: Bool = true) {
        self.animatesIn = animatesIn
        _isDrawn = State(initialValue: !animatesIn)
    }

    private var showsFull: Bool { isDrawn || !animatesIn || theme.reduceMotion }

    public var body: some View {
        Rectangle()
            .fill(theme.accent)
            .frame(height: 1)
            .scaleEffect(x: showsFull ? 1 : 0, anchor: .leading)
            .onAppear {
                // Drawn for good either way: a rule that appeared while reduced mustn't vanish when motion returns.
                guard animatesIn, !isDrawn else { return }
                STMotion.animate(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.6), reduce: theme.reduceMotion) { isDrawn = true }
            }
            .accessibilityHidden(true)
    }
}
