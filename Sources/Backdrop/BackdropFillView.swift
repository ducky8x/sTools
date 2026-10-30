import CoreGraphics
import STDesign
import SwiftUI

/// Draws one fill (spec 5.2.3) at whatever size it's given — the backdrop panel's full display, or a
/// small preview plate. `opacity` applies to the finished fill as a whole (spec 5.2.4 "Opacity").
///
/// An Animated fill draws its `player` when it's given one (the panel). Without one (the page's preview) it draws
/// `image`, the animation's first frame, fitted the same way.
struct BackdropFillView: View {
    let fill: BackdropSettings.Fill
    let image: CGImage?
    var player: (any BackdropPlayer)?
    var opacity: Double = 1

    var body: some View {
        GeometryReader { proxy in
            content(size: proxy.size)
        }
        .opacity(opacity)
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        switch fill.kind {
        case .color:
            STColorWellHex.color(from: fill.color)
        case .linearGradient:
            LinearGradient(colors: gradientColors, startPoint: linearStart, endPoint: linearEnd)
        case .radialGradient:
            RadialGradient(
                colors: gradientColors,
                center: UnitPoint(x: fill.gradientCenterX, y: fill.gradientCenterY),
                startRadius: 0,
                endRadius: fill.gradientRadius * diagonal(of: size))
        case .image, .animated:
            ZStack {
                STColorWellHex.color(from: fill.imageBackgroundColor)
                if fill.kind == .animated, let player {
                    BackdropAnimationHost(player: player, mode: fill.imageContentMode)
                } else if let image {
                    let rect = BackdropImageLayout.rect(
                        imageSize: CGSize(width: image.width, height: image.height), containerSize: size, mode: fill.imageContentMode)
                    Image(image, scale: 1, label: Text(""))
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }

    private var gradientColors: [Color] {
        [STColorWellHex.color(from: fill.gradientStartColor), STColorWellHex.color(from: fill.gradientEndColor)]
    }

    /// `gradientAngleDegrees` (0 = left to right, increasing clockwise) as a unit-square gradient line.
    private var linearStart: UnitPoint {
        let radians = fill.gradientAngleDegrees * .pi / 180
        return UnitPoint(x: 0.5 - cos(radians) / 2, y: 0.5 - sin(radians) / 2)
    }

    private var linearEnd: UnitPoint {
        let radians = fill.gradientAngleDegrees * .pi / 180
        return UnitPoint(x: 0.5 + cos(radians) / 2, y: 0.5 + sin(radians) / 2)
    }

    private func diagonal(of size: CGSize) -> CGFloat {
        (size.width * size.width + size.height * size.height).squareRoot()
    }
}
