import CoreGraphics

/// Where the keyboard and the mouse sit on the plate, in points. A laptop keyboard leaves room for the mouse
/// beside it; a full-size one is already wide, so the mouse goes underneath, below the keypad.
struct BoardGeometry: Equatable {
    static let mouseScale: CGFloat = 0.75
    static let gap: CGFloat = 0.75

    /// Points per key unit.
    let unit: CGFloat
    let mouseBesideKeyboard: Bool
    /// The mouse's top-left corner, in key units.
    let mouseOrigin: CGPoint
    let size: CGSize

    init(layout: KeyboardLayout, width: CGFloat) {
        let mouse = CGSize(width: MouseLayout.size.width * Self.mouseScale, height: MouseLayout.size.height * Self.mouseScale)
        mouseBesideKeyboard = layout.formFactor == .laptop
        if mouseBesideKeyboard {
            unit = width / (layout.size.width + Self.gap + mouse.width)
            mouseOrigin = CGPoint(x: layout.size.width + Self.gap, y: (layout.size.height - mouse.height) / 2)
            size = CGSize(width: width, height: layout.size.height * unit)
        } else {
            unit = width / layout.size.width
            mouseOrigin = CGPoint(x: layout.size.width - mouse.width, y: layout.size.height + Self.gap)
            size = CGSize(width: width, height: (layout.size.height + Self.gap + mouse.height) * unit)
        }
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
