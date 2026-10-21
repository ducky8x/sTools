import Foundation

/// Notes on the Crosshair page about where the crosshair lands.
enum CrosshairCentering {
    /// Owner-tested: Minecraft draws its crosshair just left of and above the middle (at GUI scale 3 on
    /// 1920 x 1080 its center line covers columns 957-959 and rows 537-539), and the default covers it exactly.
    static let minecraftNote = "With the default settings, this crosshair sits exactly on Minecraft\u{2019}s own when Minecraft covers the menu bar and Dock (1920 \u{00D7} 1080, GUI scale 3)."

    /// Explains when the chosen width can't be split evenly across the display's middle. Nil when it sits
    /// exactly on the middle, when an offset moves it off the middle on purpose, or for an image (placed by
    /// its anchor).
    static func note(for settings: CrosshairSettings, on display: PixelSize) -> String? {
        guard settings.shape != .image, settings.offsetX == 0, settings.offsetY == 0 else { return nil }
        let length = CrosshairShapeMath.centeringLength(shape: settings.shape, size: settings.size, thickness: settings.thickness)
        guard !CrosshairGeometry.centersExactly(length: length, on: display) else { return nil }
        let dimensions = "\(display.width) \u{00D7} \(display.height)"
        if display.width % 2 != display.height % 2 {
            return "This display is \(dimensions) pixels, so its middle falls on a pixel one way and between two pixels the other. "
                + "No crosshair can be exactly centered both ways here."
        }
        let isLine = settings.shape == .plus || settings.shape == .x
        let range = isLine ? CrosshairSettings.thicknessRange : CrosshairSettings.sizeRange
        let choices = [length - 1, length + 1].filter(range.contains).map { "\($0) px" }
        let middle = display.width % 2 == 0 ? "falls between two pixels" : "is a single pixel"
        return "This display is \(dimensions) pixels, so its middle \(middle). "
            + "A \(length) px \(isLine ? "thickness" : "size") can\u{2019}t be split evenly across it, so one side is a pixel longer. "
            + "\(choices.joined(separator: " or ")) is exactly centered."
    }
}
