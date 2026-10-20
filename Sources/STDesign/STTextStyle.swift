import SwiftUI

/// One row of the typography table (spec section 3.2). `tracking` is a fraction of the font size (em).
public struct STTextMetrics: Sendable, Equatable {
    public let size: CGFloat
    public let lineHeight: CGFloat
    public let tracking: CGFloat

    /// Tracking in points at this size.
    public var trackingPoints: CGFloat { tracking * size }

    /// Size and line height scaled by the theme's text scale; tracking stays in em.
    public func scaled(by scale: Double) -> STTextMetrics {
        STTextMetrics(size: size * scale, lineHeight: lineHeight * scale, tracking: tracking)
    }
}

public enum STTextStyle: Sendable, CaseIterable {
    case wordmark, pageTitle, sectionTitle, sidebarName, standfirst, body, label, caption

    /// Size, line height and tracking at a text scale of 1.
    public var metrics: STTextMetrics {
        switch self {
        case .wordmark: STTextMetrics(size: 72, lineHeight: 76, tracking: -0.01)
        case .pageTitle: STTextMetrics(size: 40, lineHeight: 44, tracking: 0)
        case .sectionTitle: STTextMetrics(size: 22, lineHeight: 28, tracking: 0)
        case .sidebarName: STTextMetrics(size: 18, lineHeight: 22, tracking: 0)
        case .standfirst: STTextMetrics(size: 16, lineHeight: 22, tracking: 0)
        case .body: STTextMetrics(size: 14, lineHeight: 20, tracking: 0)
        case .label: STTextMetrics(size: 12, lineHeight: 16, tracking: 0.04)
        case .caption: STTextMetrics(size: 12, lineHeight: 16, tracking: 0)
        }
    }

    func font(scale: Double) -> Font {
        let size = metrics.size * scale
        switch self {
        case .wordmark, .pageTitle, .sectionTitle, .sidebarName: return STFont.display(size)
        case .standfirst: return STFont.textItalic(size)
        case .body, .caption: return STFont.text(size)
        case .label: return STFont.label(scale: scale)
        }
    }
}

public extension View {
    /// Applies a spec typography style (spec section 3.2), scaled by the theme's text scale.
    func stStyle(_ style: STTextStyle) -> some View { modifier(STStyleModifier(style: style)) }
}

private struct STStyleModifier: ViewModifier {
    let style: STTextStyle
    @Environment(\.stTheme) private var theme
    func body(content: Content) -> some View {
        let scaled = style.metrics.scaled(by: theme.textScale)
        content
            .font(style.font(scale: theme.textScale))
            .tracking(scaled.trackingPoints)
    }
}
