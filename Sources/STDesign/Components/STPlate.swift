import SwiftUI

/// A `surface` panel with a `rule` hairline border and 12 pt corners. Content is clipped to the
/// rounded shape and gets no padding of its own, so previews and canvases can run edge to edge.
public struct STPlate<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .background(STColor.surface, in: shape)
            .clipShape(shape)
            .overlay { shape.strokeBorder(STColor.rule, lineWidth: 1) }
    }
}
