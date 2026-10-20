import Foundation

/// Where every layer of one output frame lands (spec 5.4.2), worked out without touching pixels.
public struct CompositionPlan: Equatable, Sendable {
    public struct Layer: Equatable, Sendable {
        public let key: SourceKey
        /// The part of the source's buffer to show, in buffer pixels with a top-left origin. Already limited to
        /// the buffer's content rect and cropped.
        public let sourceRect: PixelRect
        /// Where that part is drawn, in output pixels with a top-left origin.
        public let destination: PixelRect
        public let opacity: Double
        /// In output pixels.
        public let cornerRadius: Double
        /// Width in output pixels.
        public let borderWidth: Double
        public let borderColorHex: String
    }

    public let outputSize: PixelSize
    /// Back to front: the base layer first, then the layout's sources in stack order.
    public let layers: [Layer]

    /// What the plan needs to know about each frame that is present on this tick.
    public struct FrameGeometry: Equatable, Sendable {
        public var bufferSize: PixelSize
        public var contentRect: PixelRect?

        public init(bufferSize: PixelSize, contentRect: PixelRect? = nil) {
            self.bufferSize = bufferSize
            self.contentRect = contentRect
        }

        public init(_ frame: VideoFrame) {
            self.init(bufferSize: frame.pixelSize, contentRect: frame.contentRect)
        }

        /// The content area of the buffer, clipped to the buffer.
        var content: PixelRect {
            let whole = PixelRect(x: 0, y: 0, width: Double(bufferSize.width), height: Double(bufferSize.height))
            guard let rect = contentRect else { return whole }
            let x = max(0, rect.x), y = max(0, rect.y)
            let maxX = min(whole.width, rect.maxX), maxY = min(whole.height, rect.maxY)
            guard maxX > x, maxY > y else { return whole }
            return PixelRect(x: x, y: y, width: maxX - x, height: maxY - y)
        }
    }

    /// Lays out `frames` for one tick. Sources without a frame are left out. The base layer is fitted into the
    /// canvas (it fills it exactly when the canvas is Minecraft's display); each source's cropped content is
    /// fitted into its frame. Everything is then scaled from canvas to output pixels.
    public static func make(
        layout: RecordingLayout, canvas: PixelSize, output: PixelSize, frames: [SourceKey: FrameGeometry]
    ) -> CompositionPlan {
        let scaleX = Double(output.width) / Double(max(1, canvas.width))
        let scaleY = Double(output.height) / Double(max(1, canvas.height))
        func toOutput(_ rect: PixelRect) -> PixelRect {
            PixelRect(x: rect.x * scaleX, y: rect.y * scaleY, width: rect.width * scaleX, height: rect.height * scaleY)
        }
        let scale = min(scaleX, scaleY)

        var layers: [Layer] = []
        if let base = frames[.base] {
            let content = base.content
            let canvasRect = PixelRect(x: 0, y: 0, width: Double(canvas.width), height: Double(canvas.height))
            let placed = LayoutMath.fit(contentWidth: content.width, contentHeight: content.height, in: canvasRect)
            layers.append(Layer(
                key: .base, sourceRect: content, destination: toOutput(placed),
                opacity: 1, cornerRadius: 0, borderWidth: 0, borderColorHex: "#000000"))
        }
        for source in layout.orderedVideoSources {
            guard let geometry = frames[.source(source.id)] else { continue }
            let content = geometry.content
            let contentSize = PixelSize(width: Int(content.width.rounded()), height: Int(content.height.rounded()))
            let visible = LayoutMath.cropRect(sourceSize: contentSize, crop: source.crop)
            let sourceRect = visible.offsetBy(dx: content.x, dy: content.y)
            let placed = LayoutMath.fit(contentWidth: visible.width, contentHeight: visible.height, in: source.frame)
            guard !placed.isEmpty, source.opacity > 0 else { continue }
            layers.append(Layer(
                key: .source(source.id), sourceRect: sourceRect, destination: toOutput(placed),
                opacity: min(1, max(0, source.opacity)),
                cornerRadius: max(0, source.cornerRadius) * scale,
                borderWidth: max(0, source.border.width) * scale,
                borderColorHex: source.border.colorHex))
        }
        return CompositionPlan(outputSize: output, layers: layers)
    }
}
