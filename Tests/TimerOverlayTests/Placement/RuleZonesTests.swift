import CoreGraphics
import STPlatform
import Testing
@testable import TimerOverlay

/// A display whose Core Graphics bounds agree with its AppKit frame, for a primary display `primaryHeight` tall.
private func display(
    x: CGFloat = 0, y: CGFloat = 0, width: CGFloat = 1920, height: CGFloat = 1080, scale: CGFloat = 1,
    primaryHeight: CGFloat = 1080
) -> DisplayInfo {
    DisplayInfo(
        id: 1, name: "Display", frame: CGRect(x: x, y: y, width: width, height: height),
        bounds: CGRect(x: x, y: primaryHeight - y - height, width: width, height: height), backingScale: scale,
        pixelSize: CGSize(width: width * scale, height: height * scale), isMain: true)
}

private let hd = display()
/// The owner's 4K display at 2x, which looks like 1920 x 1080.
private let hdRetina = display(scale: 2)
/// A 14-inch MacBook Pro's default resolution.
private let laptop = display(width: 1512, height: 982, scale: 2, primaryHeight: 982)

private func zones(
    _ scale: TimerOverlaySettings.GUIScale, on display: DisplayInfo, minecraft: MinecraftWindow? = nil,
    corner: TimerOverlaySettings.Corner = .topRight
) -> RuleZones {
    var settings = TimerOverlaySettings()
    settings.guiScale = scale
    settings.speedRunIGTCorner = corner
    return RuleZones(settings: settings, display: display, minecraft: minecraft)
}

private extension RuleZones {
    func rects(_ kind: Kind) -> [CGRect] { zones.first { $0.kind == kind }?.rects ?? [] }
}

/// The owner's 40 pt plate at the default spot: x 1336-1489, 50-113 px from the top (spec 5.6.5).
private let defaultPlate = CGRect(x: 1336, y: 967, width: 153, height: 63)

/// A windowed Minecraft: its frame in Core Graphics coordinates, title bar included.
private func window(_ frame: CGRect, fullScreen: Bool = false, minimized: Bool = false) -> MinecraftWindow {
    MinecraftWindow(windowNumber: 7, processID: 42, title: "Minecraft* 1.16.1", frame: frame,
                    isMinimized: minimized, isFullScreen: fullScreen)
}

@Suite("Rule zones")
struct RuleZonesTests {
    // MARK: Minecraft's GUI scale

    @Test(arguments: [
        (CGSize(width: 1920, height: 1080), 4), (CGSize(width: 3840, height: 2160), 9), (CGSize(width: 3024, height: 1964), 8),
        (CGSize(width: 854, height: 480), 2), (CGSize(width: 1708, height: 960), 4), (CGSize(width: 300, height: 200), 1),
    ])
    func autoIsTheLargestScaleThatKeeps320By240(framebuffer: CGSize, expected: Int) {
        #expect(RuleZones.effectiveScale(.auto, framebuffer: framebuffer) == expected)
    }

    @Test func aFixedScaleIsCappedAtAutosLikeMinecraftDoes() {
        let fullHD = CGSize(width: 1920, height: 1080)
        #expect(RuleZones.effectiveScale(.fixed(1), framebuffer: fullHD) == 1)
        #expect(RuleZones.effectiveScale(.fixed(3), framebuffer: fullHD) == 3)
        #expect(RuleZones.effectiveScale(.fixed(6), framebuffer: fullHD) == 4)
        #expect(RuleZones.effectiveScale(.fixed(3), framebuffer: CGSize(width: 854, height: 480)) == 2)
    }

    // MARK: GUI scale 3 on 1920 x 1080, the owner's setup

    /// Every rectangle matches the speedrun rules' own figure (rules v8, A.2.note: a 1920 x 1080 screenshot of
    /// 1.16.1 at GUI scale 3 with the required parts outlined) to the pixel: toasts from x 1440 and above y 480,
    /// "Game paused" over x 864-1055 and y 30-56, SpeedRunIGT's two lines with their outline over x 1677-1889 and
    /// y 33-107, chat over x 0-977 and y 690-959. The figure's hotbar box starts at the hearts (y 963) because
    /// that player wears no armor; the zone includes the armor row (y 933).
    @Test func guiScale3MatchesTheRulesFigure() {
        let zones = zones(.fixed(3), on: hd)
        #expect(zones.scale == 3)
        #expect(zones.rects(.hotbar) == [CGRect(x: 684, y: 0, width: 552, height: 147), CGRect(x: 600, y: 0, width: 87, height: 69)])
        #expect(zones.rects(.chat) == [CGRect(x: 0, y: 120, width: 978, height: 270)])
        #expect(zones.rects(.toasts) == [CGRect(x: 1440, y: 600, width: 480, height: 480)])
        #expect(zones.rects(.gamePaused) == [CGRect(x: 864, y: 1023, width: 192, height: 27)])
        #expect(zones.rects(.speedRunIGT) == [CGRect(x: 1677, y: 972, width: 213, height: 75)])
    }

    @Test func guiScale2() {
        let zones = zones(.fixed(2), on: hd)
        #expect(zones.scale == 2)
        #expect(zones.rects(.hotbar).first == CGRect(x: 776, y: 0, width: 368, height: 98))
        #expect(zones.rects(.chat) == [CGRect(x: 0, y: 80, width: 652, height: 180)])
        #expect(zones.rects(.toasts) == [CGRect(x: 1600, y: 760, width: 320, height: 320)])
        #expect(zones.rects(.gamePaused) == [CGRect(x: 896, y: 1042, width: 128, height: 18)])
        #expect(zones.rects(.speedRunIGT) == [CGRect(x: 1746, y: 978, width: 142, height: 68)])
    }

    @Test func guiScale4() {
        let zones = zones(.fixed(4), on: hd)
        #expect(zones.scale == 4)
        #expect(zones.rects(.hotbar).first == CGRect(x: 592, y: 0, width: 736, height: 196))
        #expect(zones.rects(.chat) == [CGRect(x: 0, y: 160, width: 1304, height: 360)])
        #expect(zones.rects(.toasts) == [CGRect(x: 1280, y: 440, width: 640, height: 640)])
        #expect(zones.rects(.gamePaused) == [CGRect(x: 832, y: 1004, width: 256, height: 36)])
        #expect(zones.rects(.speedRunIGT) == [CGRect(x: 1604, y: 964, width: 284, height: 84)])
    }

    @Test func autoOn1080pIsScale4() {
        #expect(zones(.auto, on: hd) == zones(.fixed(4), on: hd))
    }

    // MARK: The default spot (spec 5.6.5, Timer round E2a)

    @Test func theDefaultSpotOverlapsTheToastColumnByAbout50Px() throws {
        let zones = zones(.fixed(3), on: hd)
        #expect(zones.covered(by: defaultPlate) == [.toasts])
        let toasts = try #require(zones.rects(.toasts).first)
        #expect(toasts.intersection(defaultPlate).width == 49)
    }

    @Test func atAutoTheToastColumnReachesFurtherIn() {
        #expect(zones(.auto, on: hd).covered(by: defaultPlate) == [.toasts])
    }

    // MARK: Retina

    /// Minecraft 1.16.1 draws into GLFW's full-resolution framebuffer on a Retina display, so GUI scale 3 on a 2x
    /// display is half the size in points: the toasts start at x 1680 and the default spot covers nothing.
    @Test func guiScale3OnA2xDisplayIsHalfTheSize() {
        let zones = zones(.fixed(3), on: hdRetina)
        #expect(zones.scale == 3)
        #expect(zones.rects(.toasts) == [CGRect(x: 1680, y: 840, width: 240, height: 240)])
        #expect(zones.covered(by: defaultPlate).isEmpty)
    }

    @Test func guiScale6OnA2xDisplayLooksLikeGUIScale3At1x() {
        let retina = zones(.fixed(6), on: hdRetina)
        let normal = zones(.fixed(3), on: hd)
        for kind in RuleZones.Kind.allCases {
            #expect(retina.rects(kind) == normal.rects(kind), "\(kind)")
        }
        #expect(retina.covered(by: defaultPlate) == [.toasts])
        #expect(zones(.auto, on: hdRetina).scale == 9)
    }

    @Test func aMacBookDisplayAtGUIScale3() {
        let zones = zones(.fixed(3), on: laptop)
        #expect(zones.scale == 3)
        #expect(zones.rects(.toasts) == [CGRect(x: 1272, y: 742, width: 240, height: 240)])
        // 1964 px isn't a multiple of 3: Minecraft's GUI is 655 units tall and its last half point is off screen.
        #expect(zones.rects(.hotbar).first == CGRect(x: 618, y: 0, width: 276, height: 73))
        #expect(RuleZones(settings: TimerOverlaySettings(guiScale: .auto), display: laptop, minecraft: nil).scale == 8)
    }

    // MARK: Windowed Minecraft (plan decision 11)

    @Test func aWindowedMinecraftsZonesSitBelowItsTitleBar() throws {
        // 854 x 480 of content, the launcher's default, plus the 28 pt title bar, on the MacBook display.
        let minecraft = window(CGRect(x: 100, y: 100, width: 854, height: 508))
        let zones = zones(.fixed(3), on: laptop, minecraft: minecraft)
        let content = CGRect(x: 100, y: 982 - 608, width: 854, height: 480)
        #expect(zones.content == content)
        for zone in zones.zones {
            for rect in zone.rects { #expect(content.contains(rect), "\(zone.kind)") }
        }
        let toasts = try #require(zones.rects(.toasts).first)
        #expect(toasts.maxY == content.maxY, "the toasts start right under the title bar")
        #expect(toasts.maxX == content.maxX)
        #expect(zones.scale == 3, "1708 x 960 px allows scale 4")
    }

    @Test func aSmallWindowCapsTheScale() {
        let minecraft = window(CGRect(x: 533, y: 286, width: 854, height: 508))
        let zones = zones(.fixed(3), on: hd, minecraft: minecraft)
        #expect(zones.scale == 2, "854 x 480 px at 1x allows scale 2 at most")
        #expect(zones.content == CGRect(x: 533, y: 286, width: 854, height: 480))
    }

    @Test func fullScreenHasNoTitleBar() {
        let native = window(CGRect(x: 0, y: 0, width: 1920, height: 1080), fullScreen: true)
        #expect(RuleZones.contentRect(minecraft: native, on: hd) == hd.frame)
        // Minecraft's own full screen is a borderless window covering the display.
        let borderless = window(CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(RuleZones.contentRect(minecraft: borderless, on: hd) == hd.frame)
    }

    @Test func withoutAUsableWindowTheZonesAssumeMinecraftFillsTheDisplay() {
        #expect(RuleZones.contentRect(minecraft: nil, on: hd) == hd.frame)
        let minimized = window(CGRect(x: 100, y: 100, width: 854, height: 508), minimized: true)
        #expect(RuleZones.contentRect(minecraft: minimized, on: hd) == hd.frame)
        let elsewhere = window(CGRect(x: 3000, y: 100, width: 854, height: 508))
        #expect(RuleZones.contentRect(minecraft: elsewhere, on: hd) == hd.frame, "on another display")
    }

    @Test func aWindowOnADisplayAboveTheMainOneConverts() {
        // A display above the main one: Core Graphics y is negative there.
        let upper = DisplayInfo(
            id: 2, name: "Upper", frame: CGRect(x: 0, y: 1080, width: 1440, height: 900),
            bounds: CGRect(x: 0, y: -900, width: 1440, height: 900), backingScale: 1,
            pixelSize: CGSize(width: 1440, height: 900), isMain: false)
        // 100 pt below the upper display's top edge: AppKit's top is 1980 - 100, and the content starts 28 pt lower.
        let minecraft = window(CGRect(x: 100, y: -800, width: 854, height: 508))
        #expect(RuleZones.contentRect(minecraft: minecraft, on: upper) == CGRect(x: 100, y: 1880 - 28 - 480, width: 854, height: 480))
    }

    @Test func theTitleBarIs28Points() {
        #expect(RuleZones.titleBarHeight == 28)
    }

    // MARK: SpeedRunIGT's corner

    @Test func theTimerCornerMirrorsTheDefaultPosition() {
        #expect(zones(.fixed(3), on: hd, corner: .topLeft).rects(.speedRunIGT) == [CGRect(x: 30, y: 972, width: 213, height: 75)])
        #expect(zones(.fixed(3), on: hd, corner: .bottomRight).rects(.speedRunIGT) == [CGRect(x: 1677, y: 33, width: 213, height: 75)])
        #expect(zones(.fixed(3), on: hd, corner: .bottomLeft).rects(.speedRunIGT) == [CGRect(x: 30, y: 33, width: 213, height: 75)])
    }

    // MARK: Covering

    @Test func aFrameAwayFromEveryZoneCoversNothing() {
        let zones = zones(.fixed(3), on: hd)
        #expect(zones.covered(by: CGRect(x: 1000, y: 600, width: 150, height: 60)).isEmpty)
    }

    @Test func touchingAnEdgeIsNotCovering() {
        let zones = zones(.fixed(3), on: hd)
        #expect(zones.covered(by: CGRect(x: 1290, y: 700, width: 150, height: 60)).isEmpty, "right edge on the toasts' left edge")
        #expect(zones.covered(by: CGRect(x: 1291, y: 700, width: 150, height: 60)) == [.toasts])
    }

    @Test func coveredZonesComeInOrder() {
        let zones = zones(.fixed(3), on: hd)
        let wide = CGRect(x: 1400, y: 980, width: 400, height: 60)
        #expect(zones.covered(by: wide) == [.toasts, .speedRunIGT])
        let offhand = CGRect(x: 610, y: 10, width: 20, height: 20)
        #expect(zones.covered(by: offhand) == [.hotbar], "the offhand slot is part of the hotbar")
    }

    @Test func theLineNamesWhatIsCovered() {
        #expect(RuleZones.coverLine(for: []) == nil)
        #expect(RuleZones.coverLine(for: [.toasts]) == "Covers the toasts")
        #expect(RuleZones.coverLine(for: [.toasts, .speedRunIGT]) == "Covers the toasts and SpeedRunIGT\u{2019}s timer")
        #expect(RuleZones.coverLine(for: [.chat, .toasts, .gamePaused]) == "Covers chat, the toasts and Game Paused")
    }

    @Test func eachKindHasAName() {
        for kind in RuleZones.Kind.allCases { #expect(!kind.name.isEmpty) }
    }
}

private extension TimerOverlaySettings {
    init(guiScale: GUIScale) {
        self.init()
        self.guiScale = guiScale
    }
}
