import SwiftUI

/// A `surface` panel with a `rule` hairline border and 12 pt corners. Content is clipped to the
/// rounded shape and gets no padding of its own, so previews and canvases can run edge to edge.
public struct STPlate<Content: View>: View {
    private let content: Content
    private let tint: Color?

    /// `tint` washes the plate in a color and draws its edge in it (the NBB Overlay's boat color); nil keeps the plain plate.
    public init(tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    /// How strongly `tint` washes the plate: enough to read from the corner of an eye, while ink stays well above 4.5:1.
    public nonisolated static var tintStrength: Double { 0.30 }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(STColor.surface)
                    if let tint { shape.fill(tint.opacity(Self.tintStrength)) }
                }
            }
            .clipShape(shape)
            .overlay {
                if let tint {
                    shape.strokeBorder(tint, lineWidth: 2)
                } else {
                    shape.strokeBorder(STColor.rule, lineWidth: 1)
                }
            }
    }
}
