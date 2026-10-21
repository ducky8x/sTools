import SwiftUI

// MARK: - Pure typing-animation model

/// One edit between two strings: the characters that left and the characters that arrived.
///
/// Ranges are in `Character` (grapheme cluster) offsets, so an emoji sequence, a flag or a
/// letter with a combining accent is always one unit. `insertedUTF16` is the same range as a
/// UTF-16 offset range into the new string, which is what SwiftUI's text layout reports.
struct TypingEdit: Equatable, Sendable {
    var removed: Range<Int>
    var inserted: Range<Int>
    var removedText: String
    var insertedText: String
    var insertedUTF16: Range<Int>
    /// UTF-16 offset in the new string where the removed text used to sit.
    var removalAnchorUTF16: Int { insertedUTF16.lowerBound }
}

/// Diffs the field's old and new string into the glyphs to animate. Pure, no UI.
enum TypingAnimationModel {
    /// Returns nil when nothing changed. Otherwise the shortest middle section that differs:
    /// everything before it and after it is untouched. When characters repeat ("aa" to "aaa") the
    /// common prefix wins, so the inserted character is reported at the end of the run; the two
    /// readings look identical on screen.
    static func diff(from old: String, to new: String) -> TypingEdit? {
        guard old != new else { return nil }
        let oldChars = Array(old)
        let newChars = Array(new)
        let limit = min(oldChars.count, newChars.count)

        var prefix = 0
        while prefix < limit, oldChars[prefix] == newChars[prefix] { prefix += 1 }

        var suffix = 0
        while suffix < limit - prefix,
              oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }

        let removed = prefix..<(oldChars.count - suffix)
        let inserted = prefix..<(newChars.count - suffix)
        let utf16Start = new.utf16.distance(from: new.startIndex, to: new.index(new.startIndex, offsetBy: inserted.lowerBound))
        let utf16End = new.utf16.distance(from: new.startIndex, to: new.index(new.startIndex, offsetBy: inserted.upperBound))
        return TypingEdit(removed: removed,
                          inserted: inserted,
                          removedText: String(oldChars[removed]),
                          insertedText: String(newChars[inserted]),
                          insertedUTF16: utf16Start..<utf16End)
    }

    /// Hebrew, Arabic and related right-to-left blocks. The overlay lays text out left to right,
    /// so the field shows its own text for these.
    static func containsRightToLeft(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF: true
            default: false
            }
        }
    }

    /// Longest removed run that still gets a shrink-out ghost; bigger deletions just vanish.
    static let maxGhostCharacters = 12
}

/// The sideways shake for an invalid field: three full swings that end exactly where they began.
struct STShakeEffect: GeometryEffect {
    static let amplitude: CGFloat = 3
    static let swings = 3.0

    /// Horizontal offset at a progress value; whole numbers of progress give zero.
    static func offset(at progress: CGFloat) -> CGFloat {
        amplitude * sin(progress * .pi * 2 * swings)
    }

    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: Self.offset(at: animatableData), y: 0))
    }
}

enum STTypingMotion {
    /// A new character settling in, or a deleted one shrinking out.
    static let settle: Animation = .easeOut(duration: 0.06)
    /// The sideways shake for invalid input.
    static let shake: Animation = .linear(duration: 0.3)
    /// How far a new character rises into place, in points.
    static let rise: CGFloat = 2
}

extension EnvironmentValues {
    /// Test hook: shows the real text field's own glyphs and hides the overlay, so a render can be
    /// compared against the overlay render.
    @Entry var stRevealsNativeText: Bool = false
}

// MARK: - Renderer

/// Draws the overlay text unchanged except for the newest glyphs, which settle in, and a ghost of
/// the deleted glyphs, which shrinks out where they were. Everything keeps its laid-out position.
struct STTypingRenderer: TextRenderer {
    var progress: Double
    let inserted: Range<Int>?
    let removedText: String
    let removalAnchor: Int
    let rise: CGFloat
    let shrinks: Bool
    let font: Font
    let color: Color

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var displayPadding: EdgeInsets { EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16) }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        let base = Self.baseIndex(layout)
        let isAnimating = progress < 1

        for line in layout {
            for run in line {
                guard isAnimating, let inserted, run.contains(where: { Self.contains(inserted, slice: $0, base: base) }) else {
                    ctx.draw(run)
                    continue
                }
                for slice in run {
                    if Self.contains(inserted, slice: slice, base: base) {
                        var settling = ctx
                        settling.opacity = progress
                        settling.translateBy(x: 0, y: rise * (1 - progress))
                        settling.draw(slice)
                    } else {
                        ctx.draw(slice)
                    }
                }
            }
        }

        if isAnimating, !removedText.isEmpty, let spot = ghostSpot(layout, base: base) {
            var ghost = ctx
            ghost.opacity = 1 - progress
            ghost.translateBy(x: spot.x, y: spot.midY)
            if shrinks { ghost.scaleBy(x: 1 - progress, y: 1 - progress) }
            ghost.draw(ghost.resolve(Text(removedText).font(font).foregroundStyle(color)), at: .zero, anchor: .center)
        }
    }

    private static func baseIndex(_ layout: Text.Layout) -> Text.Layout.CharacterIndex? {
        layout.lazy.flatMap { $0 }.flatMap { $0.characterIndices }.min()
    }

    private static func offset(of slice: Text.Layout.RunSlice, base: Text.Layout.CharacterIndex?) -> Int? {
        guard let base, let first = slice.characterIndices.first else { return nil }
        return base.distance(to: first)
    }

    private static func contains(_ range: Range<Int>, slice: Text.Layout.RunSlice, base: Text.Layout.CharacterIndex?) -> Bool {
        offset(of: slice, base: base).map(range.contains) ?? false
    }

    /// Where the deleted glyphs sat: the left edge of the glyph now at the anchor, or the end of the line.
    private func ghostSpot(_ layout: Text.Layout, base: Text.Layout.CharacterIndex?) -> (x: CGFloat, midY: CGFloat)? {
        guard let line = layout.first else { return nil }
        let midY = line.typographicBounds.rect.midY
        var endX: CGFloat = 0
        for run in line {
            for slice in run {
                let bounds = slice.typographicBounds
                if let at = Self.offset(of: slice, base: base), at >= removalAnchor {
                    return (bounds.origin.x, midY)
                }
                endX = bounds.origin.x + bounds.width
            }
        }
        return (endX, midY)
    }
}

/// The overlay: the field's text, drawn by SwiftUI so the newest glyphs can animate.
struct STTypingText: View {
    let text: String
    let edit: TypingEdit?
    let font: Font
    let color: Color
    let reduceMotion: Bool

    @State private var progress: Double

    init(text: String, edit: TypingEdit?, font: Font, color: Color, reduceMotion: Bool) {
        self.text = text
        self.edit = edit
        self.font = font
        self.color = color
        self.reduceMotion = reduceMotion
        // Settled from the first frame while motion is reduced, so a new glyph never blinks in.
        _progress = State(initialValue: edit == nil || reduceMotion ? 1 : 0)
    }

    var body: some View {
        Text(STTextField.displayString(text))
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .textRenderer(STTypingRenderer(
                progress: progress,
                inserted: edit?.insertedUTF16,
                removedText: removedGhost,
                removalAnchor: edit?.removalAnchorUTF16 ?? 0,
                rise: reduceMotion ? 0 : STTypingMotion.rise,
                shrinks: !reduceMotion,
                font: font,
                color: color))
            .onAppear {
                STMotion.animate(STTypingMotion.settle, reduce: reduceMotion) { progress = 1 }
            }
    }

    private var removedGhost: String {
        guard let edit, edit.removedText.count <= TypingAnimationModel.maxGhostCharacters else { return "" }
        return edit.removedText
    }
}

// MARK: - Text field

/// A borderless single-line field: `surface` fill, a `stroke` baseline that becomes an accent
/// underline on focus. Typing animates (spec section 3.4): each new character settles in with a
/// 2 pt rise, deleted characters shrink out, invalid input shakes once. None of it moves while
/// motion is reduced.
///
/// The real `TextField` stays in charge of editing, caret, selection, paste, input methods and
/// VoiceOver; its glyphs are made transparent and an overlay draws the same text so only the
/// newest glyphs animate. When the text is too long to fit, or reads right to left, the field
/// shows its own glyphs instead and the per-glyph animation is skipped.
public struct STTextField: View {
    private let title: String
    @Binding private var text: String
    private let isInvalid: Bool

    @Environment(\.stTheme) private var theme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.stRevealsNativeText) private var revealsNativeText
    @FocusState private var isFocused: Bool

    @State private var edit: TypingEdit?
    @State private var editSerial = 0
    @State private var shakes: CGFloat = 0
    @State private var fieldSize: CGSize = .zero
    @State private var textSize: CGSize = .zero

    /// Space kept free at the right edge for the caret before the field would start scrolling.
    private static let overflowMargin: CGFloat = 8

    public init(_ title: String, text: Binding<String>, isInvalid: Bool = false) {
        self.title = title
        self._text = text
        self.isInvalid = isInvalid
    }

    /// An empty string has no line to measure, so the overlay draws a space.
    static func displayString(_ text: String) -> String { text.isEmpty ? " " : text }

    private var bodyFont: Font { STFont.text(14 * theme.textScale) }

    private var showsNativeText: Bool {
        revealsNativeText
            || (fieldSize.width > 0 && textSize.width > fieldSize.width - Self.overflowMargin)
            || TypingAnimationModel.containsRightToLeft(text)
    }

    /// At some font sizes the real field draws its line half a point lower than SwiftUI's `Text`;
    /// those are exactly the sizes where the field's frame is a point shorter than the Text's.
    /// Half the height difference closes the gap (verified for 12 to 18.2 pt in the tests).
    private var baselineCorrection: CGFloat {
        guard fieldSize.height > 0, textSize.height > 0 else { return 0 }
        let raw = max(0, min(1, (textSize.height - fieldSize.height) / 2))
        return (raw * displayScale).rounded() / displayScale
    }

    private var caretFraction: CGFloat {
        guard fieldSize.width > 0 else { return 0 }
        return max(0, min(1, textSize.width / fieldSize.width))
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            // Always present so the field has the same height whichever text is showing. Zero
            // width keeps long text from widening the field.
            Text(Self.displayString(text))
                .font(bodyFont)
                .lineLimit(1)
                .fixedSize()
                .hidden()
                .onGeometryChange(for: CGSize.self, of: \.size) { textSize = $0 }
                .frame(width: 0, alignment: .leading)
                .accessibilityHidden(true)

            TextField(title, text: $text, prompt: Text(title).foregroundStyle(theme.inkTertiary))
                .textFieldStyle(.plain)
                .font(bodyFont)
                .foregroundStyle(showsNativeText ? STColor.ink : Color.clear)
                .tint(theme.accent)
                .frame(minWidth: 0, idealWidth: 220, maxWidth: .infinity, alignment: .leading)
                .focused($isFocused)
                .focusEffectDisabled()
                .accessibilityHint(isInvalid ? "Invalid value" : "")
                .onGeometryChange(for: CGSize.self, of: \.size) { fieldSize = $0 }

            if !showsNativeText {
                STTypingText(text: text, edit: edit, font: bodyFont, color: STColor.ink, reduceMotion: theme.reduceMotion)
                    .id(editSerial)
                    .frame(width: 0, alignment: .leading)
                    .offset(y: baselineCorrection)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 6)
        .background(STColor.surface)
        .overlay(alignment: .bottom) { underline }
        .modifier(STShakeEffect(animatableData: shakes))
        .onChange(of: text) { old, new in
            edit = TypingAnimationModel.diff(from: old, to: new)
            editSerial &+= 1
        }
        .onChange(of: isInvalid) { _, invalid in
            guard invalid, !theme.reduceMotion else { return }
            withAnimation(STTypingMotion.shake) { shakes += 1 }
        }
    }

    private var underline: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(isInvalid ? STColor.danger : theme.stroke)
            Rectangle()
                .fill(isInvalid ? STColor.danger : theme.accent)
                .scaleEffect(x: isFocused ? 1 : 0, anchor: UnitPoint(x: caretFraction, y: 0.5))
        }
        .frame(height: 1)
        .clipped()
        .stAnimation(STMotion.standard, value: isFocused)
        .stAnimation(STMotion.quick, value: isInvalid)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
