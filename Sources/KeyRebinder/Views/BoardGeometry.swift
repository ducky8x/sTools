import CoreGraphics

/// Where the keyboard and the mouse sit on the plate, in points. Keys never shrink below `minimumUnit` (a key
/// you can read and click). The mouse goes beside the keyboard when that still leaves keys at least that big,
/// else underneath (below the keypad) when that fits; when nothing fits, it stays beside and the plate scrolls.
struct BoardGeometry: Equatable {
    static let mouseScale: CGFloat = 0.75
    static let gap: CGFloat = 0.75
    static let minimumUnit: CGFloat = 36
    static let maximumUnit: CGFloat = 64

    /// Points per key unit.
    let unit: CGFloat
    let mouseBesideKeyboard: Bool
    /// The mouse's top-left corner, in key units.
    let mouseOrigin: CGPoint
    let size: CGSize

    /// The largest board that fits `width`, but never with keys under `minimumUnit`: then the board is wider
    /// than `width` and the plate scrolls sideways.
    init(layout: KeyboardLayout, width: CGFloat) {
        let mouse = Self.mouseSize
        let besideUnits = layout.size.width + Self.gap + mouse.width
        let besideUnit = width / besideUnits
        let belowUnit = width / layout.size.width
        if besideUnit >= Self.minimumUnit {
            self.init(layout: layout, unit: min(besideUnit, Self.maximumUnit), mouseBeside: true)
        } else if belowUnit >= Self.minimumUnit {
            self.init(layout: layout, unit: min(belowUnit, Self.maximumUnit), mouseBeside: false)
        } else {
            // Scrolling anyway: keep the board short, mouse alongside.
            self.init(layout: layout, unit: Self.minimumUnit, mouseBeside: true)
        }
    }

    init(layout: KeyboardLayout, unit: CGFloat, mouseBeside: Bool) {
        let mouse = Self.mouseSize
        self.unit = unit
        mouseBesideKeyboard = mouseBeside
        if mouseBeside {
            mouseOrigin = CGPoint(x: layout.size.width + Self.gap, y: max(0, (layout.size.height - mouse.height) / 2))
            size = CGSize(width: (layout.size.width + Self.gap + mouse.width) * unit, height: max(layout.size.height, mouse.height) * unit)
        } else {
            mouseOrigin = CGPoint(x: layout.size.width - mouse.width, y: layout.size.height + Self.gap)
            size = CGSize(width: layout.size.width * unit, height: (layout.size.height + Self.gap + mouse.height) * unit)
        }
    }

    /// A picture-only board scaled to exactly `width`, however small (the layout chooser's preview).
    static func preview(layout: KeyboardLayout, width: CGFloat) -> BoardGeometry {
        BoardGeometry(layout: layout, unit: width / (layout.size.width + gap + mouseSize.width), mouseBeside: true)
    }

    private static var mouseSize: CGSize {
        CGSize(width: MouseLayout.size.width * mouseScale, height: MouseLayout.size.height * mouseScale)
    }

/// A keyboard key's parts, in points.
    func rects(forKey key: KeyCap) -> [CGRect] {
        key.frames.map { scaled($0, origin: .zero, scale: 1) }
    }

    /// A mouse button's frame, in points.
    func rect(forButton button: KeyCap) -> CGRect {
        scaled(button.frames[0], origin: mouseOrigin, scale: Self.mouseScale)
    }

    /// The mouse's outline, in points.
    var mouseBody: CGRect {
        scaled(CGRect(origin: .zero, size: MouseLayout.size), origin: mouseOrigin, scale: Self.mouseScale)
    }

    private func scaled(_ rect: CGRect, origin: CGPoint, scale: CGFloat) -> CGRect {
        CGRect(
            x: (origin.x + rect.minX * scale) * unit, y: (origin.y + rect.minY * scale) * unit,
            width: rect.width * scale * unit, height: rect.height * scale * unit)
    }
}

/// The few characters drawn on a key for an output: the legend of the key that sends it when the drawn
/// keyboard has one ("esc", "r shift"), "M4" for mouse button 4, "off" for a disabled key.
enum KeyLegend {
    static func short(for event: KarabinerEvent, layout: KeyboardLayout?) -> String {
        switch event {
        case .key("vk_none"):
            return "off"
        case .key:
            let canonical = KeyTable.shared.canonical(event)
            guard let legend = layout?.keys.first(where: { KeyTable.shared.canonical($0.event) == canonical })?.legend else {
                return KeyNames.name(for: event)
            }
            if legend.isEmpty { return "space" }
            // Both shifts (options, commands) share a legend; the right one gets a mark.
            if case .key(let code) = canonical, code.hasPrefix("right_") { return "r \(legend)" }
            return legend
        case .pointing:
            return MouseLayout.buttonNumber(of: event).map { "M\($0)" } ?? KeyNames.name(for: event)
        default:
            return KeyNames.name(for: event)
        }
    }
}
