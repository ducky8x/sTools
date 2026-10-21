import SwiftUI

/// One line of advice under a control, in caption type: a note in tertiary ink, or a caution, which leads with a
/// small `danger` dot and reads in full ink. Advice only: it never blocks anything. VoiceOver reads the text alone.
public struct STNoteLine: View {
    public enum Tone: Sendable {
        /// Something to know.
        case note
        /// Something the choice takes away.
        case caution
    }

    private let text: String
    private let tone: Tone

    @Environment(\.stTheme) private var theme

    public init(_ text: String, tone: Tone = .note) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if tone == .caution {
                Circle()
                    .fill(STColor.danger)
                    .frame(width: 6 * theme.textScale, height: 6 * theme.textScale)
                    // Its bottom on the text's baseline, so it sits beside the lowercase letters.
                    .alignmentGuide(.firstTextBaseline) { $0.height }
                    .accessibilityHidden(true)
            }
            Text(text)
                .stStyle(.caption)
                .foregroundStyle(tone == .caution ? STColor.ink : theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
