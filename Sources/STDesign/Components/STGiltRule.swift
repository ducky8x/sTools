import SwiftUI

/// A 1 pt accent line under a page title. It draws left to right over 0.6 s when it appears;
/// with Reduce Motion, or `animatesIn == false`, it is simply there.
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
                guard animatesIn, !theme.reduceMotion else { return }
                withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.6)) { isDrawn = true }
            }
            .accessibilityHidden(true)
    }
}
