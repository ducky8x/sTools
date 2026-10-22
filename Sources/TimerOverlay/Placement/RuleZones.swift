import CoreGraphics
import STPlatform

/// The parts of Minecraft 1.16.1's screen the speedrun rules need visible in a run's video, where the game draws
/// them (spec 5.6.5): the hotbar with the bars above it, chat, the toasts, *Game Paused* and SpeedRunIGT's timer
/// (rules v8, A.2.9 and A.2.10). The rule guides outline them while the plate is dragged. Advisory only.
///
/// A value: built once per drag and per display change from the GUI scale setting, Minecraft's drawing area and
/// the display's backing scale; each mouse move only asks `covered(by:)`. The timer never reads the game's files
/// or screen (spec 5.6.8), so the GUI scale is a setting and Minecraft's window comes from Accessibility.
/// Rectangles are AppKit global points, inside Minecraft's drawing area. Sources are listed with `GUILayout` below.
public struct RuleZones: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        /// The hotbar, the offhand slot and the bars above it: XP, health, food, armor and air.
        case hotbar
        /// Chat's unfocused message lines, at their default width and height.
        case chat
        /// Advancement and recipe toasts: five slots down the top-right corner.
        case toasts
        /// The "Game Paused" title of a pause without the menu (F3 + Esc).
        case gamePaused
        /// SpeedRunIGT's two timer lines, in the corner the settings name.
        case speedRunIGT

        /// What the guides' line calls the zone (placeholder wording for M9).
        public var name: String {
            switch self {
            case .hotbar: "the hotbar"
            case .chat: "chat"
            case .toasts: "the toasts"
            case .gamePaused: "Game Paused"
            case .speedRunIGT: "SpeedRunIGT\u{2019}s timer"
            }
        }
    }

    public struct Zone: Equatable, Sendable {
        public let kind: Kind
        /// AppKit global points. One rectangle, except the hotbar's, which adds the offhand slot.
        public let rects: [CGRect]

        public init(kind: Kind, rects: [CGRect]) {
            self.kind = kind
            self.rects = rects
        }
    }

    /// A windowed Minecraft's title bar, above its drawing area (plan decision 11). Measured on macOS 27.0.1 for
    /// an app linked against the macOS 11-15 SDKs, as every Java runtime checked is (11.1-14.2); an app linked
    /// against the 26 SDK gets 32 pt. To confirm on the owner's Mac (hardware check 5).
    public static let titleBarHeight: CGFloat = 28

    /// Every zone, in `Kind.allCases` order.
    public let zones: [Zone]
    /// The GUI scale Minecraft draws at: the setting, capped at Auto's scale as Minecraft caps it.
    public let scale: Int
    /// Minecraft's drawing area, AppKit global points.
    public let content: CGRect

    /// The zones for a GUI scale setting and Minecraft's drawing area on a display with `backingScale`.
    public init(
        guiScale: TimerOverlaySettings.GUIScale, speedRunIGTCorner: TimerOverlaySettings.Corner, content: CGRect,
        backingScale: CGFloat
    ) {
        let backing = backingScale > 0 ? backingScale : 1
        // Minecraft draws into GLFW's full-resolution framebuffer: the drawing area in pixels.
        let framebuffer = CGSize(width: (content.width * backing).rounded(), height: (content.height * backing).rounded())
        let scale = Self.effectiveScale(guiScale, framebuffer: framebuffer)
        let layout = GUILayout(framebuffer: framebuffer, scale: scale)
        let pointsPerUnit = CGFloat(scale) / backing
        self.scale = scale
        self.content = content
        zones = Kind.allCases.map { kind in
            let rects = layout.rects(for: kind, corner: speedRunIGTCorner).compactMap { unit -> CGRect? in
                let rect = CGRect(
                    x: content.minX + unit.minX * pointsPerUnit, y: content.maxY - unit.maxY * pointsPerUnit,
                    width: unit.width * pointsPerUnit, height: unit.height * pointsPerUnit)
                // The GUI rounds up, so a unit can hang past the right or bottom edge; that part isn't drawn.
                let drawn = rect.intersection(content)
                return drawn.isEmpty ? nil : drawn
            }
            return Zone(kind: kind, rects: rects)
        }
    }

    /// The zones for `settings` on `display`: inside Minecraft's window when it's on that display, otherwise
    /// assuming Minecraft fills the display (plan decision 11).
    public init(settings: TimerOverlaySettings, display: DisplayInfo, minecraft: MinecraftWindow?) {
        self.init(
            guiScale: settings.guiScale, speedRunIGTCorner: settings.speedRunIGTCorner,
            content: Self.contentRect(minecraft: minecraft, on: display), backingScale: display.backingScale)
    }

    /// The zones `frame` overlaps (touching an edge doesn't count), in `Kind.allCases` order. Cheap: run it on every
    /// mouse move of a drag.
    public func covered(by frame: CGRect) -> [Kind] {
        zones.filter { zone in zone.rects.contains { $0.overlaps(frame) } }.map(\.kind)
    }

    /// The guides' line under the plate, such as "Covers the toasts and SpeedRunIGT's timer" (placeholder wording
    /// for M9). Nil when nothing is covered.
    public static func coverLine(for kinds: [Kind]) -> String? {
        let names = kinds.map(\.name)
        guard let last = names.last else { return nil }
        let list = names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
        return "Covers " + list
    }

    // MARK: - Minecraft's window

    /// Minecraft 1.16.1's GUI scale for a setting and a framebuffer in pixels (`Window.calculateScale`): it counts
    /// up from 1 while the next scale still leaves 320 x 240 units, and stops early at a fixed setting. Auto is
    /// that largest scale, and a larger setting is capped at it.
    public static func effectiveScale(_ setting: TimerOverlaySettings.GUIScale, framebuffer: CGSize) -> Int {
        let width = Int(framebuffer.width.rounded())
        let height = Int(framebuffer.height.rounded())
        let stop = switch setting {
        case .auto: 0
        case .fixed(let scale): scale
        }
        var scale = 1
        while scale != stop, scale < width, scale < height, width / (scale + 1) >= 320, height / (scale + 1) >= 240 {
            scale += 1
        }
        return scale
    }

    /// Where Minecraft draws, in AppKit global points (plan decision 11).
    /// - In full screen (macOS's own, or Minecraft's borderless window covering the display) it's the window.
    /// - Windowed, it's the window below its title bar.
    /// - Without a window on `display` (none, minimized, or on another display) it's the whole display.
    public static func contentRect(
        minecraft window: MinecraftWindow?, on display: DisplayInfo, titleBarHeight: CGFloat = RuleZones.titleBarHeight
    ) -> CGRect {
        guard let window, !window.isMinimized, window.frame.width > 0, window.frame.height > 0 else { return display.frame }
        // Any display gives the primary display's height: AppKit's minY is that height minus Core Graphics' maxY.
        let primaryHeight = display.frame.minY + display.bounds.maxY
        let frame = DisplayGeometry.convertToAppKit(cgRect: window.frame, primaryScreenHeight: primaryHeight)
        guard frame.overlaps(display.frame) else { return display.frame }
        if window.isFullScreen || window.frame.isAbout(display.bounds) { return frame }
        return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: max(0, frame.height - titleBarHeight))
    }
}

// MARK: - Minecraft 1.16.1's HUD

// Sources (researched 2026-10-21; positions in GUI units, x right and y down from the drawing area's top-left):
// - Minecraft 1.16.1's client, decompiled (Yarn: InGameHud, ChatHud, ToastManager, GameMenuScreen, ChatScreen,
//   Window; MCP: IngameGui, NewChatGui, ToastGui, IngameMenuScreen, ChatScreen, MainWindow):
//   - The hotbar is 182 x 22 at (w/2 - 91, h - 22); the selected slot's frame reaches 1 unit further each side and
//     up. The offhand slot is 29 x 24 at (w/2 - 120, h - 23), left of it while the main hand is right (the default).
//   - The XP bar is at h - 29 and its level at h - 35; health and food rows at h - 39; armor and air at h - 49. More
//     hearts (absorption, more than 20 health) push armor up 10 a row, past this zone.
//   - Chat is drawn from (0, h - 48), moved by (2, 8): each line is 9 tall with its background from -2 to width + 4,
//     so 10 unfocused lines fill x 0-326 and y (h - 130)-(h - 40). Width is 320 (narrowed to (pixels - 3) / scale
//     in a small window). An open chat shows 20 lines, up to h - 220, plus the input bar over the whole width at
//     h - 14; the zone keeps the unfocused block, as the rules' figure does.
//   - Toasts are 160 x 32, at (w - 160, slot x 32) for five slots.
//   - F3 + Esc pauses without the menu and draws "Game paused" (en_us, 64 units wide) centered at y 10; with Esc's
//     menu the title is "Game Menu" at y 40 instead, so only the first is the rules' "Game Paused text" (A.2.9.b,
//     A.5.4.b).
//   - The GUI is ceil(pixels / scale) units, and `Window.calculateScale` gives the scale (see `effectiveScale`).
// - Forge 1.16.x `ForgeIngameGui` (github.com/MinecraftForge/MinecraftForge, branch 1.16.x) re-implements the HUD
//   with the same numbers: chat at height - 48, bar rows starting 39 and 49 up.
// - The speedrun rules v8 (github.com/Minecraft-Java-Edition-Speedrunning/rules, rules.typ A.2.9, A.2.10 and the
//   A.2.note figure, images/f3.png): a 1920 x 1080 screenshot of 1.16.1 at GUI scale 3 with the required parts
//   outlined. Every zone here matches it to the pixel at that scale (see RuleZonesTests).
// - SpeedRunIGT, branch 1.16.1 (github.com/RedLime/SpeedRunIGT): SpeedRunOptions puts RTA at (0.983, 0.035) and
//   IGT at (0.983, 0.08) of the GUI by default, both at scale 1 with an outline, right-aligned (TimerElement) when
//   the text would pass the right edge, which it always does there. "RTA: 00:00.000" is 70 units wide; an hour or
//   more adds 8 to the left. That's the top right, as spec 5.6.7 says. Other corners mirror it; the runner's own
//   position is a guess.
// - minecraft.wiki/w/Options: chat 320 wide, 180 focused and 90 unfocused; Auto is the largest scale that keeps
//   320 x 240.
// - Retina: 1.16.1 on macOS uses LWJGL 3.2.1 (Mojang's 1.16.1 version JSON), whose GLFW 3.3 gives windows full
//   Retina framebuffers unless GLFW_COCOA_RETINA_FRAMEBUFFER is turned off (glfw.org window guide), and
//   1.16.1 never turns it off. The GUI is sized in those pixels, so a GUI unit is scale / backing scale points.
//   High confidence, not yet seen on the owner's Mac (hardware check 5); mods such as noRetina turn it off.

/// Minecraft 1.16.1's HUD in GUI units for one framebuffer and scale.
private struct GUILayout {
    /// "RTA: 00:00.000" and "IGT: 00:00.000" in Minecraft's font: digits and letters 6, I 4, colon and point 2,
    /// space 4. The RTA line is the wider, so it sets the box.
    static let timerTextWidth = 70

    /// The GUI's size: the framebuffer divided by the scale, rounded up (`Window.setScaleFactor`).
    let width: Int
    let height: Int
    let chatWidth: Int

    init(framebuffer: CGSize, scale: Int) {
        let pixels = (width: Int(framebuffer.width), height: Int(framebuffer.height))
        let scale = max(scale, 1)
        width = Int((Double(pixels.width) / Double(scale)).rounded(.up))
        height = Int((Double(pixels.height) / Double(scale)).rounded(.up))
        chatWidth = min(320, max(0, Int(Double(pixels.width - 3) / Double(scale))))
    }

    func rects(for kind: RuleZones.Kind, corner: TimerOverlaySettings.Corner) -> [CGRect] {
        let middle = width / 2
        switch kind {
        case .hotbar:
            return [
                units(middle - 92, height - 49, middle + 92, height),
                units(middle - 120, height - 23, middle - 91, height + 1),
            ]
        case .chat:
            return [units(0, height - 130, chatWidth + 6, height - 40)]
        case .toasts:
            return [units(width - 160, 0, width, 160)]
        case .gamePaused:
            return [units(middle - 32, 10, middle + 32, 19)]
        case .speedRunIGT:
            // Java's float math and truncation, as SpeedRunIGT places its lines. The box includes the outline.
            let right = Int(Float(0.983) * Float(width))
            let rtaTop = Int(Float(0.035) * Float(height))
            let igtTop = Int(Float(0.08) * Float(height))
            var box = (minX: right - Self.timerTextWidth, minY: rtaTop - 1, maxX: right + 1, maxY: igtTop + 8)
            if corner == .topLeft || corner == .bottomLeft {
                box = (width - box.maxX, box.minY, width - box.minX, box.maxY)
            }
            if corner == .bottomLeft || corner == .bottomRight {
                box = (box.minX, height - box.maxY, box.maxX, height - box.minY)
            }
            return [units(box.minX, box.minY, box.maxX, box.maxY)]
        }
    }

    private func units(_ minX: Int, _ minY: Int, _ maxX: Int, _ maxY: Int) -> CGRect {
        CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

extension CGRect {
    /// Shares some area with `other`; touching edges don't count.
    fileprivate func overlaps(_ other: CGRect) -> Bool {
        let shared = intersection(other)
        return !shared.isNull && shared.width > 0 && shared.height > 0
    }

    /// The same rectangle, give or take half a point on each edge.
    fileprivate func isAbout(_ other: CGRect) -> Bool {
        abs(minX - other.minX) <= 0.5 && abs(minY - other.minY) <= 0.5
            && abs(maxX - other.maxX) <= 0.5 && abs(maxY - other.maxY) <= 0.5
    }
}
