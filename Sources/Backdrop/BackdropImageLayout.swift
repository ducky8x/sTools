import CoreGraphics

/// Where an image fill draws inside its display, for each content mode (spec 5.2.3). Pure geometry,
/// independent of SwiftUI, so every mode's math can be pinned down directly.
enum BackdropImageLayout {
    /// The rect (in the container's own coordinate space, origin top-left) the image should be drawn
    /// into. Degenerate sizes fall back to filling the container rather than producing NaN or zero rects.
    static func rect(imageSize: CGSize, containerSize: CGSize, mode: BackdropSettings.ImageContentMode) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        switch mode {
        case .stretch:
            return CGRect(origin: .zero, size: containerSize)
        case .fill:
            let scale = max(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
            return centered(size: scaled(imageSize, by: scale), in: containerSize)
        case .fit:
            let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
            return centered(size: scaled(imageSize, by: scale), in: containerSize)
        case .center:
            return centered(size: imageSize, in: containerSize)
        }
    }

    private static func scaled(_ size: CGSize, by factor: CGFloat) -> CGSize {
        CGSize(width: size.width * factor, height: size.height * factor)
    }

    private static func centered(size: CGSize, in container: CGSize) -> CGRect {
        CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }
}
