import SwiftUI

/// One choice in an `STSegmented`.
public struct STSegmentedOption<Value: Hashable>: Identifiable {
    public let value: Value
    public let title: String
    /// What VoiceOver calls the option when its title isn't what it should say ("Command 1 to Command 5" for
    /// "⌘1–⌘5"); nil reads the title.
    public let spokenTitle: String?
    public var id: Value { value }

    public init(_ value: Value, _ title: String, spokenTitle: String? = nil) {
        self.value = value
        self.title = title
        self.spokenTitle = spokenTitle
    }

    /// What VoiceOver says for the option: its spoken title, else its title.
    public var accessibilityTitle: String { spokenTitle ?? title }
}

/// Arrow-key navigation for `STSegmented`, kept pure so it can be tested.
enum STSegmentedNavigation {
    /// The index reached by moving `offset` places from `current`, clamped to the ends (no wrapping).
    /// With no current selection, a forward move lands on the first option and a backward move on the last.
    static func index(from current: Int?, offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return offset >= 0 ? 0 : count - 1 }
        return min(max(current + offset, 0), count - 1)
    }
}

/// How a segmented control lays its options out.
enum STSegmentedLayout {
    /// The space between options on a line.
    static let spacing: CGFloat = 18
    /// The space between lines, when the options wrap.
    static let lineSpacing: CGFloat = 4
}

extension EnvironmentValues {
    /// Whether the `STSegmented` it reaches lets its options wrap onto further lines, a whole option at a time, when they
    /// don't fit on one: `STChoiceRow`'s last resort. Off, the options stay on one line.
    @Entry var stSegmentedWraps: Bool = false
}

/// Lays its subviews out left to right, each at its own size, and starts a new line before one that would pass the width
/// it is offered, so a line break falls between subviews and never inside one. With no width to go by, one line.
struct STWrappingRow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private struct Line {
        var items: [(subview: LayoutSubview, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews, width: proposal.width)
        let gaps = lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: lines.map(\.width).max() ?? 0, height: lines.map(\.height).reduce(0, +) + gaps)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, width: proposal.width ?? bounds.width) {
            var x = bounds.minX
            for item in line.items {
                item.subview.place(at: CGPoint(x: x, y: y + (line.height - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat?) -> [Line] {
        var lines = [Line()]
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            var line = lines.removeLast()
            let gap = line.items.isEmpty ? 0 : spacing
            if let width, !line.items.isEmpty, line.width + gap + size.width > width + 0.5 {
                lines.append(line)
                line = Line()
            }
            line.width += (line.items.isEmpty ? 0 : spacing) + size.width
            line.height = max(line.height, size.height)
            line.items.append((subview, size))
            lines.append(line)
        }
        return lines
    }
}

/// Small-caps words with an accent underline that slides to the selection.
///
/// The left and right arrow keys move the selection while the control has keyboard focus, and a click anywhere on it
/// gives it that: on an option, or beside the options (between them or in the padding around them). With macOS's
/// keyboard navigation off, its default, Tab never reaches the control, so a click is the way in. VoiceOver reads each
/// option as a button, by its `accessibilityTitle`, the chosen one selected, in a group named `label` when one is given.
public struct STSegmented<Value: Hashable>: View {
    @Binding private var selection: Value
    private let options: [STSegmentedOption<Value>]
    private let label: String?

    @Environment(\.stTheme) private var theme
    @Environment(\.stSoundPlayer) private var sound
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.stSegmentedWraps) private var wraps
    @FocusState private var isFocused: Bool
    @Namespace private var underlineSpace

    /// - Parameter label: Names the options' group for VoiceOver ("Key set"); give it where no settings row already
    ///   names the control, as `STSettingsRow` does.
    public init(selection: Binding<Value>, options: [STSegmentedOption<Value>], label: String? = nil) {
        _selection = selection
        self.options = options
        self.label = label
    }

    public var body: some View {
        let layout = wraps
            ? AnyLayout(STWrappingRow(spacing: STSegmentedLayout.spacing, lineSpacing: STSegmentedLayout.lineSpacing))
            : AnyLayout(HStackLayout(spacing: STSegmentedLayout.spacing))
        layout {
            ForEach(options) { option in
                STSegmentedItem(title: option.title, spokenTitle: option.accessibilityTitle,
                                isSelected: option.value == selection,
                                underlineSpace: underlineSpace) {
                    focus()
                    choose(option.value)
                }
            }
        }
        .stAnimation(STMotion.quick, value: selection)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        // A click beside the options focuses the control too, as a click on one does; the options' buttons take
        // the clicks on them first.
        .contentShape(Rectangle())
        .onTapGesture { focus() }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(theme.accentStroke, lineWidth: 2)
                .opacity(isFocused ? 1 : 0)
        }
        .opacity(isEnabled ? 1 : 0.4)
        .focusable(isEnabled)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
        .accessibilityElement(children: .contain)
        .stAccessibilityLabel(label)
    }

    /// Gives the control keyboard focus, so the arrow keys move its selection.
    private func focus() {
        if isEnabled { isFocused = true }
    }

    private func choose(_ value: Value) {
        guard isEnabled, value != selection else { return }
        selection = value
        sound.play(.click)
    }

    private func move(_ offset: Int) -> KeyPress.Result {
        let current = options.firstIndex { $0.value == selection }
        guard let target = STSegmentedNavigation.index(from: current, offset: offset, count: options.count),
              target != current else { return .handled }
        choose(options[target].value)
        return .handled
    }
}

private struct STSegmentedItem: View {
    let title: String
    /// What VoiceOver calls the option.
    let spokenTitle: String
    let isSelected: Bool
    let underlineSpace: Namespace.ID
    let action: () -> Void

    @Environment(\.stTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .stStyle(.label)
                .foregroundStyle(isSelected || isHovering ? STColor.ink : theme.inkSecondary)
                .padding(.vertical, 4)
                .background(alignment: .bottom) {
                    if isSelected {
                        Rectangle()
                            .fill(theme.accent)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "underline", in: underlineSpace)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovering = $0 }
        .accessibilityLabel(spokenTitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension View {
    /// Names the element for VoiceOver when `label` is given; without one it keeps what it has.
    @ViewBuilder
    func stAccessibilityLabel(_ label: String?) -> some View {
        if let label { accessibilityLabel(label) } else { self }
    }
}
