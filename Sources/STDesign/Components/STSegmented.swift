import SwiftUI

/// One choice in an `STSegmented`.
public struct STSegmentedOption<Value: Hashable>: Identifiable {
    public let value: Value
    public let title: String
    public var id: Value { value }

    public init(_ value: Value, _ title: String) {
        self.value = value
        self.title = title
    }
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

/// Small-caps words with an accent underline that slides to the selection.
public struct STSegmented<Value: Hashable>: View {
    @Binding private var selection: Value
    private let options: [STSegmentedOption<Value>]

    @Environment(\.stTheme) private var theme
    @Environment(\.stSoundPlayer) private var sound
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool
    @Namespace private var underlineSpace

    public init(selection: Binding<Value>, options: [STSegmentedOption<Value>]) {
        _selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 18) {
            ForEach(options) { option in
                STSegmentedItem(title: option.title,
                                isSelected: option.value == selection,
                                underlineSpace: underlineSpace) {
                    choose(option.value)
                }
            }
        }
        .stAnimation(STMotion.quick, value: selection)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
