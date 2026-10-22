import Foundation

/// Pure canvas math: fitting, cropping, clamping and sizing.
public enum LayoutMath {
    /// The smallest side a source frame may have on the canvas.
    public static let minimumFrameSide = 16.0

    /// The largest rectangle with the aspect ratio of `content` that fits inside `rect`, centered in it.
    public static func fit(contentWidth: Double, contentHeight: Double, in rect: PixelRect) -> PixelRect {
        guard contentWidth > 0, contentHeight > 0, rect.width > 0, rect.height > 0 else {
            return PixelRect(x: rect.x, y: rect.y, width: 0, height: 0)
        }
        let scale = min(rect.width / contentWidth, rect.height / contentHeight)
        let w = contentWidth * scale, h = contentHeight * scale
        return PixelRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    public static func fit(_ content: PixelSize, in rect: PixelRect) -> PixelRect {
        fit(contentWidth: Double(content.width), contentHeight: Double(content.height), in: rect)
    }

    /// The part of a `sourceSize` source that remains after cropping, in source pixels (top-left origin).
    public static func cropRect(sourceSize: PixelSize, crop: CropInsets) -> PixelRect {
        let crop = crop.clamped()
        let w = Double(sourceSize.width), h = Double(sourceSize.height)
        let x = (crop.left * w).rounded(), y = (crop.top * h).rounded()
        let right = (w - crop.right * w).rounded(), bottom = (h - crop.bottom * h).rounded()
        return PixelRect(x: x, y: y, width: max(1, right - x), height: max(1, bottom - y))
    }

    /// Where the cropped content of a source lands inside its `frame`: scaled to fit, centered.
    public static func contentRect(sourceSize: PixelSize, crop: CropInsets, in frame: PixelRect) -> PixelRect {
        let visible = cropRect(sourceSize: sourceSize, crop: crop)
        return fit(contentWidth: visible.width, contentHeight: visible.height, in: frame)
    }

    /// Moves and shrinks `frame` until it lies entirely inside the canvas and is at least `minimumSize` per side.
    public static func clamp(_ frame: PixelRect, to canvas: PixelSize, minimumSize: Double = minimumFrameSide) -> PixelRect {
        let cw = Double(canvas.width), ch = Double(canvas.height)
        func finite(_ v: Double, _ fallback: Double) -> Double { v.isFinite ? v : fallback }
        let minW = min(minimumSize, cw), minH = min(minimumSize, ch)
        let width = min(cw, max(minW, finite(frame.width, minW)))
        let height = min(ch, max(minH, finite(frame.height, minH)))
        let x = min(cw - width, max(0, finite(frame.x, 0)))
        let y = min(ch - height, max(0, finite(frame.y, 0)))
        return PixelRect(x: x, y: y, width: width, height: height)
    }

    /// A first frame for a freshly added source: at most a third of the canvas wide (and tall),
    /// aspect preserved, in the bottom-right corner with a margin.
    public static func defaultFrame(forContent content: PixelSize, canvas: PixelSize) -> PixelRect {
        let cw = Double(canvas.width), ch = Double(canvas.height)
        let margin = (min(cw, ch) * 0.02).rounded()
        let box = PixelRect(x: 0, y: 0, width: cw / 3, height: ch / 3)
        let fitted = content.isEmpty ? box : fit(content, in: box)
        let size = PixelSize(width: max(1, Int(fitted.width.rounded())), height: max(1, Int(fitted.height.rounded())))
        let frame = PixelRect(
            x: cw - Double(size.width) - margin, y: ch - Double(size.height) - margin,
            width: Double(size.width), height: Double(size.height))
        return clamp(frame, to: canvas)
    }

    /// The canvas size for `canvas` given the Minecraft display's pixel size. Sides are even.
    public static func canvasSize(_ canvas: CanvasSize, minecraftDisplay: PixelSize) -> PixelSize {
        switch canvas {
        case .minecraftDisplay: (minecraftDisplay.isEmpty ? PixelSize(width: 1920, height: 1080) : minecraftDisplay).evenSized
        case .custom(let size): size.evenSized
        }
    }

    /// The size of the recorded video: the canvas, or the canvas scaled down to the chosen height
    /// (never scaled up). Sides are even.
    public static func outputSize(_ choice: OutputSize, canvas: PixelSize) -> PixelSize {
        guard let target = choice.targetHeight, canvas.height > target else { return canvas.evenSized }
        let width = (Double(canvas.width) * Double(target) / Double(canvas.height)).rounded()
        return PixelSize(width: Int(width), height: target).evenSized
    }
}

/// A guide line the editor draws while snapping.
public struct SnapGuide: Equatable, Hashable, Sendable {
    public enum Axis: Sendable { case vertical, horizontal }
    public enum Target: Sendable { case canvasEdge, canvasCenter, sourceEdge, sourceCenter }

    /// A vertical guide sits at an x position, a horizontal guide at a y position.
    public var axis: Axis
    public var position: Double
    public var target: Target
}

/// The frame after snapping and the guides to show.
public struct SnapResult: Equatable, Sendable {
    public var frame: PixelRect
    public var guides: [SnapGuide]
}

/// Which edges of a frame a resize drag is moving.
public struct ResizeEdges: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let left = ResizeEdges(rawValue: 1)
    public static let right = ResizeEdges(rawValue: 2)
    public static let top = ResizeEdges(rawValue: 4)
    public static let bottom = ResizeEdges(rawValue: 8)
}

/// Snapping for the canvas editor: a dragged frame's edges and center catch on the canvas edges and center
/// and on the edges and centers of the other sources, when they come within `threshold` pixels.
public enum SnapEngine {
    /// The snap distance on a canvas whose shorter side is 1080 pixels.
    public static let defaultThreshold = 8.0

    /// The snap distance on a `canvas`-sized canvas: `defaultThreshold` at 1080 pixels on the shorter side, scaled
    /// with the canvas, so it covers the same share of the canvas (and of the editor's plate) at 1x, 2x or any size.
    public static func threshold(for canvas: PixelSize) -> Double {
        defaultThreshold * Double(max(1, min(canvas.width, canvas.height))) / 1080
    }

    private struct Candidate {
        var position: Double
        var target: SnapGuide.Target
    }

    /// Snaps a frame that is being moved. Each axis snaps independently to its nearest candidate.
    public static func snapMove(
        _ frame: PixelRect, canvas: PixelSize, others: [PixelRect], threshold: Double = defaultThreshold
    ) -> SnapResult {
        let xs = candidates(.vertical, canvas: canvas, others: others)
        let ys = candidates(.horizontal, canvas: canvas, others: others)
        let dx = bestShift(features: [frame.minX, frame.midX, frame.maxX], candidates: xs, threshold: threshold)
        let dy = bestShift(features: [frame.minY, frame.midY, frame.maxY], candidates: ys, threshold: threshold)
        let moved = frame.offsetBy(dx: dx, dy: dy)
        var guides: [SnapGuide] = []
        guides += matchingGuides(.vertical, features: [moved.minX, moved.midX, moved.maxX], candidates: xs)
        guides += matchingGuides(.horizontal, features: [moved.minY, moved.midY, moved.maxY], candidates: ys)
        return SnapResult(frame: moved, guides: guides)
    }

    /// Snaps only the edges a resize drag is moving; the opposite edges stay where they are.
    public static func snapResize(
        _ frame: PixelRect, edges: ResizeEdges, canvas: PixelSize, others: [PixelRect],
        threshold: Double = defaultThreshold, minimumSize: Double = LayoutMath.minimumFrameSide
    ) -> SnapResult {
        let xs = candidates(.vertical, canvas: canvas, others: others)
        let ys = candidates(.horizontal, canvas: canvas, others: others)
        var left = frame.minX, right = frame.maxX, top = frame.minY, bottom = frame.maxY
        if edges.contains(.left) { left += bestShift(features: [left], candidates: xs, threshold: threshold) }
        if edges.contains(.right) { right += bestShift(features: [right], candidates: xs, threshold: threshold) }
        if edges.contains(.top) { top += bestShift(features: [top], candidates: ys, threshold: threshold) }
        if edges.contains(.bottom) { bottom += bestShift(features: [bottom], candidates: ys, threshold: threshold) }
        if right - left < minimumSize {
            if edges.contains(.left) { left = right - minimumSize } else { right = left + minimumSize }
        }
        if bottom - top < minimumSize {
            if edges.contains(.top) { top = bottom - minimumSize } else { bottom = top + minimumSize }
        }
        let result = PixelRect(x: left, y: top, width: right - left, height: bottom - top)
        var movingX: [Double] = []
        var movingY: [Double] = []
        if edges.contains(.left) { movingX.append(result.minX) }
        if edges.contains(.right) { movingX.append(result.maxX) }
        if edges.contains(.top) { movingY.append(result.minY) }
        if edges.contains(.bottom) { movingY.append(result.maxY) }
        let guides = matchingGuides(.vertical, features: movingX, candidates: xs)
            + matchingGuides(.horizontal, features: movingY, candidates: ys)
        return SnapResult(frame: result, guides: guides)
    }

    private static func candidates(_ axis: SnapGuide.Axis, canvas: PixelSize, others: [PixelRect]) -> [Candidate] {
        let length = Double(axis == .vertical ? canvas.width : canvas.height)
        var list = [
            Candidate(position: 0, target: .canvasEdge),
            Candidate(position: length / 2, target: .canvasCenter),
            Candidate(position: length, target: .canvasEdge),
        ]
        for other in others {
            switch axis {
            case .vertical:
                list += [Candidate(position: other.minX, target: .sourceEdge),
                         Candidate(position: other.midX, target: .sourceCenter),
                         Candidate(position: other.maxX, target: .sourceEdge)]
            case .horizontal:
                list += [Candidate(position: other.minY, target: .sourceEdge),
                         Candidate(position: other.midY, target: .sourceCenter),
                         Candidate(position: other.maxY, target: .sourceEdge)]
            }
        }
        return list
    }

    /// The smallest shift (by absolute value) that lines one feature up with one candidate, or 0 if none is close enough.
    private static func bestShift(features: [Double], candidates: [Candidate], threshold: Double) -> Double {
        var best: Double?
        for feature in features {
            for candidate in candidates {
                let shift = candidate.position - feature
                guard abs(shift) <= threshold else { continue }
                if best == nil || abs(shift) < abs(best!) { best = shift }
            }
        }
        return best ?? 0
    }

    private static func matchingGuides(
        _ axis: SnapGuide.Axis, features: [Double], candidates: [Candidate]
    ) -> [SnapGuide] {
        var seen = Set<SnapGuide>()
        var result: [SnapGuide] = []
        for feature in features {
            for candidate in candidates where abs(candidate.position - feature) < 0.5 {
                let guide = SnapGuide(axis: axis, position: candidate.position, target: candidate.target)
                if seen.insert(guide).inserted { result.append(guide) }
            }
        }
        return result
    }
}
