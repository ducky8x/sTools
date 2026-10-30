import SwiftUI

/// A page's title. It stays on one line and shrinks only as far as its room needs, never below `STTitleFit.floor` of its
/// size. Where even that is too wide it wraps between words, aimed at `STTitleFit.wrappedScale`. While it is on one line
/// its row keeps the height of the title at full size, so the switch beside it and everything under the header stay where
/// they are. Only a title that wraps makes the header taller.
struct STPageTitle: View {
    private let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        STPageTitleLayout {
            Text(title)
                .stStyle(.pageTitle)
                .foregroundStyle(STColor.ink)
                .lineLimit(2)
                .minimumScaleFactor(STTitleFit.floor)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// How a title sits in the room it is given.
enum STTitleFit: Equatable {
    /// The least a title shrinks to, as a fraction of its size.
    static let floor: CGFloat = 0.7
    /// At the floor a title needs up to 1% more room than 70% of its one-line width, depending on the text size, and a line
    /// a hair short loses its last letters to an ellipsis. So one line is chosen only with 2% to spare.
    static let slack: CGFloat = 1.02
    /// The size a wrapped title is aimed at, as a fraction of its size. It comes out at or a little under that, and never
    /// under `floor`. Aimed at the floor itself, the two lines don't fit the height offered for them at some text sizes, and
    /// the title falls back to one line with an ellipsis.
    static let wrappedScale: CGFloat = 0.8

    /// On one line, at full size.
    case full
    /// On one line, shrunk to the room.
    case shrunk
    /// On two lines, between words.
    case wrapped

    /// How a title whose one line is `lineWidth` wide fits in `room`.
    init(lineWidth: CGFloat, room: CGFloat) {
        if room >= lineWidth {
            self = .full
        } else if room >= lineWidth * Self.floor * Self.slack {
            self = .shrunk
        } else {
            self = .wrapped
        }
    }
}

/// Offers the title's `Text` the room and the height that suit how it fits. A `Text` that may take two lines wraps before it
/// shrinks, so while one line fits (shrunk) it is offered the height of one line, and only one line fits in that. When the
/// title has to wrap it is offered the height of two lines at `wrappedScale`. While the title is on one line the layout
/// answers with the height of one line at full size, whatever size the title was shrunk to.
private struct STPageTitleLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let line = text.sizeThatFits(.unspecified)
        guard let room = proposal.width else { return line }
        switch STTitleFit(lineWidth: line.width, room: room) {
        case .full: return line
        case .shrunk: return CGSize(width: room, height: line.height)
        case .wrapped: return text.sizeThatFits(offer(room: room, line: line, fit: .wrapped))
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        guard let text = subviews.first else { return }
        let line = text.sizeThatFits(.unspecified)
        let fit = STTitleFit(lineWidth: line.width, room: bounds.width)
        text.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: offer(room: bounds.width, line: line, fit: fit))
    }

    private func offer(room: CGFloat, line: CGSize, fit: STTitleFit) -> ProposedViewSize {
        switch fit {
        case .full: ProposedViewSize(width: room, height: nil)
        case .shrunk: ProposedViewSize(width: room, height: line.height)
        case .wrapped: ProposedViewSize(width: room, height: line.height * 2 * STTitleFit.wrappedScale)
        }
    }
}
