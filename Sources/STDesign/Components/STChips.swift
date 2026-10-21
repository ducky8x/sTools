import SwiftUI

/// Toggleable chips for picking any mix of options: a selected chip is filled with the accent, the others are
/// `surface` capsules with a `stroke` outline. The chips wrap onto new rows instead of overflowing. Each chip is a
/// button with the selected trait, and the chips read as one group named `label`.
public struct STChips<Value: Hashable>: View {
    @Binding private var selection: Set<Value>
    private let options: [STSegmentedOption<Value>]
    private let label: String

    @Environment(\.stSoundPlayer) private var sound
    @Environment(\.isEnabled) private var isEnabled

    /// - Parameter label: Names the group for VoiceOver ("Hold", "Does").
    public init(selection: Binding<Set<Value>>, options: [STSegmentedOption<Value>], label: String) {
        _selection = selection
        self.options = options
        self.label = label
    }

    public var body: some View {
        STFlowLayout(spacing: 8) {
            ForEach(options) { option in
                let isSelected = selection.contains(option.value)
                Button(option.title) { toggle(option.value) }
                    .buttonStyle(STChipStyle(isSelected: isSelected))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func toggle(_ value: Value) {
        guard isEnabled else { return }
        sound.play(.click)
        selection = STChipsLogic.toggled(value, in: selection)
    }
}

/// What a chip click does to the selection. Pure, so it can be tested.
enum STChipsLogic {
    /// `selection` with `value` added when it was missing, or removed when it was there. Other values stay.
    static func toggled<Value: Hashable>(_ value: Value, in selection: Set<Value>) -> Set<Value> {
        var result = selection
        if result.remove(value) == nil { result.insert(value) }
        return result
    }
}

/// One chip's look: today's capsule, plus the house press dip and gold focus ring.
private struct STChipStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        STChipBody(isSelected: isSelected, configuration: configuration)
    }
}

private struct STChipBody: View {
    let isSelected: Bool
    let configuration: ButtonStyleConfiguration

    @Environment(\.stTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .stStyle(.label)
            .foregroundStyle(isSelected ? STColor.background : STColor.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? theme.accent : STColor.surface, in: Capsule())
            .overlay(Capsule().stroke(theme.stroke, lineWidth: isSelected ? 0 : 1))
            .overlay {
                Capsule()
                    .stroke(theme.accentStroke, lineWidth: 2)
                    .padding(-3)
                    .opacity(isFocused && isEnabled ? 1 : 0)
            }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .stAnimation(STMotion.press, value: configuration.isPressed)
            .focusEffectDisabled()
    }
}

/// Lays its subviews out left to right at their ideal sizes, wrapping onto a new row before one that would
/// overflow the proposed width. An item wider than the row sits alone on its own row. Rows are top-aligned, and
/// the layout is as wide as its widest row.
public struct STFlowLayout: Layout {
    /// The gap between neighbors and between rows.
    public var spacing: CGFloat

    public init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        STFlowLayoutMath.arrange(sizes(of: subviews), width: proposal.width ?? .infinity, spacing: spacing).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Arranged for the same proposal as `sizeThatFits`, so the rows match the size the parent was told.
        let sizes = sizes(of: subviews)
        let arrangement = STFlowLayoutMath.arrange(sizes, width: proposal.width ?? .infinity, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            let origin = arrangement.origins[index]
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                          anchor: .topLeading, proposal: ProposedViewSize(sizes[index]))
        }
    }

    private func sizes(of subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }
}

/// `STFlowLayout`'s row math. Pure, so it can be tested.
enum STFlowLayoutMath {
    struct Arrangement: Equatable {
        /// Each item's top-left corner, in the order the sizes were given.
        var origins: [CGPoint]
        /// The widest row by the height of all rows with `spacing` between them. Zero for no items.
        var size: CGSize
    }

    static func arrange(_ sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> Arrangement {
        var origins: [CGPoint] = []
        origins.reserveCapacity(sizes.count)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for size in sizes {
            // The first item of a row always stays, however wide it is.
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            widest = max(widest, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return Arrangement(origins: origins, size: CGSize(width: widest, height: sizes.isEmpty ? 0 : y + rowHeight))
    }
}
