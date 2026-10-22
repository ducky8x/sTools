import AppKit
import Foundation
import Observation
import STDesign
import SwiftUI
import Testing
@testable import TimerOverlay

// Renders the overlay view offscreen at a fixed 2x, as a Retina display draws it, whatever the main display's scale.
// Nothing is ever ordered onto a screen. With `STOOLS_RENDER_DIR` set, each look and state is also written there as a
// PNG over a dark scene, Minecraft's sky and snow, to be checked by eye.

/// A borderless window that's never shown, with a fixed backing scale, so text is rasterized at the scale it's
/// captured at.
@MainActor
private final class FixedScaleWindow: NSWindow {
    private let scale: CGFloat

    init(size: CGSize, scale: CGFloat) {
        self.scale = scale
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }

    override var backingScaleFactor: CGFloat { scale }
}

/// `view` at its own size, drawn at `scale` pixels per point in a window that's never ordered in.
@MainActor
private func render<V: View>(_ view: V, scale: CGFloat = 2) -> NSBitmapImageRep {
    _ = NSApplication.shared
    STFont.register()
    let host = NSHostingView(rootView: view)
    let size = host.fittingSize
    host.frame = CGRect(origin: .zero, size: size)
    let window = FixedScaleWindow(size: size, scale: scale)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()), pixelsHigh: Int((size.height * scale).rounded()),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    window.contentView = nil
    return rep
}

/// The overlay's own size in points, as SwiftUI lays it out.
@MainActor
private func size(_ content: TimerOverlayContent, _ settings: TimerOverlaySettings, theme: STTheme = STTheme()) -> CGSize {
    STFont.register()
    return NSHostingController(rootView: TimerOverlayView(content: content, settings: settings).environment(\.stTheme, theme))
        .sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
}

private func sameImage(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow,
          let left = a.bitmapData, let right = b.bitmapData else { return false }
    return memcmp(left, right, a.bytesPerRow * a.pixelsHigh) == 0
}

/// The color at point `(x, y)` from the top left, as 0...255 channels.
private func color(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> (red: Int, green: Int, blue: Int, alpha: Int) {
    let scale = CGFloat(rep.pixelsWide) / rep.size.width
    let pixel = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB)
    func byte(_ value: CGFloat?) -> Int { Int(((value ?? 0) * 255).rounded()) }
    return (byte(pixel?.redComponent), byte(pixel?.greenComponent), byte(pixel?.blueComponent), byte(pixel?.alphaComponent))
}

private let renderDirectory = ProcessInfo.processInfo.environment["STOOLS_RENDER_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }

/// The overlay over a dark scene, Minecraft's sky and snow, side by side, for checking by eye.
private struct OverScenes: View {
    let overlay: TimerOverlayView
    let theme: STTheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.scenes.enumerated()), id: \.offset) { _, scene in
                overlay.padding(18).background(scene)
            }
        }
        .environment(\.stTheme, theme)
    }

    static let scenes = [Color(hex: "#1B1F14"), Color(hex: "#78A7FF"), Color(hex: "#FFFFFF")]
}

/// Writes the overlay over the scenes to `<STOOLS_RENDER_DIR>/<name>.png` at 2x, when that variable is set.
@MainActor
private func dump(_ name: String, _ content: TimerOverlayContent, _ settings: TimerOverlaySettings, theme: STTheme = STTheme()) {
    guard let renderDirectory else { return }
    try? FileManager.default.createDirectory(at: renderDirectory, withIntermediateDirectories: true)
    let rep = render(OverScenes(overlay: TimerOverlayView(content: content, settings: settings), theme: theme))
    try? rep.representation(using: .png, properties: [:])?.write(to: renderDirectory.appending(path: "\(name).png"))
}

private func settings(_ change: (inout TimerOverlaySettings) -> Void = { _ in }) -> TimerOverlaySettings {
    var settings = TimerOverlaySettings()
    change(&settings)
    return settings
}

/// The text each state shows in the renders.
private func text(for state: TimerOverlayContent.State) -> String {
    switch state {
    case .counting: "02:30"
    case .nearZeroGold: "00:30"
    case .nearZeroDanger: "00:09"
    case .paused: "01:02"
    case .timesUp: "00:00"
    }
}

@MainActor @Observable
private final class Shown {
    var content: TimerOverlayContent
    var isOn = false

    init(_ content: TimerOverlayContent) { self.content = content }
}

private struct Observed: View {
    let shown: Shown
    let settings: TimerOverlaySettings

    var body: some View { TimerOverlayView(content: shown.content, settings: settings) }
}

/// The control: a swatch whose color change animates, so a capture right after a change inside an animation shows
/// the change still under way. Without a window SwiftUI never advances an animation.
private struct Swatch: View {
    let shown: Shown

    var body: some View {
        Rectangle().fill(shown.isOn ? Color.white : Color.black).frame(width: 40, height: 20)
    }
}

@MainActor
private final class Windowless<Content: View> {
    let host: NSHostingView<Content>

    init(_ view: Content) {
        _ = NSApplication.shared
        STFont.register()
        host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
    }

    func capture() -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
}

@Suite("Timer overlay rendering", .serialized)
@MainActor
struct TimerOverlayRenderTests {
    // MARK: Every look and state, checked by eye

    @Test(arguments: TimerOverlaySettings.Look.allCases)
    func everyLookAndStateDraws(look: TimerOverlaySettings.Look) {
        for state in TimerOverlayContent.State.allCases {
            let content = TimerOverlayContent(text: text(for: state), state: state)
            let drawn = settings { $0.look = look }
            let rep = render(TimerOverlayView(content: content, settings: drawn).environment(\.stTheme, STTheme()))
            #expect(rep.pixelsWide > 40 && rep.pixelsHigh > 20, "\(look) \(state)")
            #expect(rep.pixelsWide % 2 == 0 && rep.pixelsHigh % 2 == 0, "whole points at 2x: \(look) \(state)")
            dump("\(look.rawValue)-\(state.rawValue)", content, drawn)
        }
    }

    @Test func theAdvancedPartsDraw() {
        let variants: [(String, TimerOverlayContent, TimerOverlaySettings)] = [
            ("plate-label", TimerOverlayContent(text: "02:30", label: "Fire res"), settings()),
            ("plate-label-paused", TimerOverlayContent(text: "01:02", state: .paused, label: "Fire res"), settings()),
            ("plate-bar", TimerOverlayContent(text: "01:15", progress: 0.5), settings { $0.progress = .bar }),
            ("plate-ring", TimerOverlayContent(text: "01:15", progress: 0.5), settings { $0.progress = .ring }),
            ("plate-ring-label", TimerOverlayContent(text: "01:15", progress: 0.75, label: "Fire res"), settings { $0.progress = .ring }),
            ("pill-bar-label", TimerOverlayContent(text: "00:20", state: .nearZeroGold, progress: 0.13, label: "Fire res"),
             settings { $0.look = .compactPill; $0.progress = .bar }),
            ("digits-bar", TimerOverlayContent(text: "01:15", progress: 0.5), settings { $0.look = .digitsOnly; $0.progress = .bar }),
            ("digits-ring-timesup", TimerOverlayContent(text: "00:00", state: .timesUp, progress: 0),
             settings { $0.look = .digitsOnly; $0.progress = .ring }),
            ("plate-tenths", TimerOverlayContent(text: "00:09.9", state: .nearZeroDanger), settings()),
            ("plate-word", TimerOverlayContent(text: "Time", state: .timesUp), settings()),
            ("plate-overtime", TimerOverlayContent(text: "+0:07", state: .timesUp), settings()),
            ("plate-hours", TimerOverlayContent(text: "1:00:00"), settings()),
            ("plate-danger-edge", TimerOverlayContent(text: "02:30", showsDangerEdge: true), settings()),
            ("plate-70-percent-gold", TimerOverlayContent(text: "00:30", state: .nearZeroGold), settings { $0.plateOpacityPercent = 70 }),
            ("plate-custom", TimerOverlayContent(text: "02:30"), settings {
                $0.plateColorHex = "#20304A"; $0.edgeColorHex = "#D9AE52"; $0.edgeWidth = 2; $0.cornerRadius = 4; $0.digitColorHex = "#E8F0FF"
            }),
            ("plate-28pt", TimerOverlayContent(text: "02:30"), settings { $0.digitSize = 28 }),
            ("plate-140pt", TimerOverlayContent(text: "02:30"), settings { $0.digitSize = 140 }),
            ("font-new-york", TimerOverlayContent(text: "02:30"), settings { $0.fontFamily = "New York" }),
            ("font-sf-pro", TimerOverlayContent(text: "02:30"), settings { $0.fontFamily = "SF Pro" }),
            ("font-bodoni-moda", TimerOverlayContent(text: "02:30"), settings { $0.fontFamily = "Bodoni Moda" }),
        ]
        for (name, content, drawn) in variants {
            let rep = render(TimerOverlayView(content: content, settings: drawn).environment(\.stTheme, STTheme()))
            #expect(rep.pixelsWide > 40, "\(name)")
            dump(name, content, drawn)
        }
        dump("plate-increase-contrast", TimerOverlayContent(text: "02:30"), settings(), theme: STTheme(increaseContrast: true))
        dump("digits-increase-contrast", TimerOverlayContent(text: "02:30"), settings { $0.look = .digitsOnly },
             theme: STTheme(increaseContrast: true))
    }

    // MARK: What's drawn

    @Test func thePlateIsTheBackgroundAt85Percent() {
        let rep = render(TimerOverlayView(content: TimerOverlayContent(text: "02:30"), settings: TimerOverlaySettings())
            .environment(\.stTheme, STTheme()))
        // Just inside the left edge, past the hairline, beside the digits.
        let fill = color(rep, x: 4, y: rep.size.height / 2)
        #expect(abs(fill.red - 0x0B) <= 2 && abs(fill.green - 0x0A) <= 2 && abs(fill.blue - 0x09) <= 2, "\(fill)")
        #expect(abs(fill.alpha - 217) <= 1, "85% of 255: \(fill.alpha)")
    }

    @Test func atZeroThePlateIsGold() {
        let rep = render(TimerOverlayView(content: TimerOverlayContent(text: "00:00", state: .timesUp), settings: TimerOverlaySettings())
            .environment(\.stTheme, STTheme()))
        let fill = color(rep, x: 4, y: rep.size.height / 2)
        #expect(abs(fill.red - 0xD9) <= 2 && abs(fill.green - 0xAE) <= 2 && abs(fill.blue - 0x52) <= 2, "\(fill)")
    }

    @Test func digitsOnlyLeaveTheirCornersClear() {
        let rep = render(TimerOverlayView(content: TimerOverlayContent(text: "02:30"), settings: settings { $0.look = .digitsOnly })
            .environment(\.stTheme, STTheme()))
        #expect(color(rep, x: 1, y: 1).alpha == 0, "no plate behind the digits")
    }

    @Test func theCapsuleHasRoundEnds() {
        let rep = render(TimerOverlayView(content: TimerOverlayContent(text: "02:30"), settings: settings { $0.look = .compactPill })
            .environment(\.stTheme, STTheme()))
        #expect(color(rep, x: 1, y: 1).alpha == 0, "the corner is outside the round end")
        #expect(color(rep, x: rep.size.width / 2, y: 1).alpha > 0, "the top edge is plate")
    }

    @Test func increaseContrastComesFromTheThemeItIsGiven() {
        let content = TimerOverlayContent(text: "02:30")
        let normal = render(TimerOverlayView(content: content, settings: TimerOverlaySettings()).environment(\.stTheme, STTheme()))
        let raised = render(TimerOverlayView(content: content, settings: TimerOverlaySettings())
            .environment(\.stTheme, STTheme(increaseContrast: true)))
        #expect(!sameImage(normal, raised), "the edge thickens")
    }

    // MARK: Size

    @Test func theFiguresAreTabularSoThePlateNeverShifts() {
        let plain = TimerOverlaySettings()
        let zeros = size(TimerOverlayContent(text: "00:00"), plain)
        #expect(size(TimerOverlayContent(text: "11:11"), plain) == zeros)
        #expect(size(TimerOverlayContent(text: "47:59"), plain) == zeros)
        #expect(size(TimerOverlayContent(text: "00:00", state: .timesUp), plain) == zeros, "the time's-up look keeps the size")
        #expect(size(TimerOverlayContent(text: "00:30", state: .nearZeroGold), plain) == zeros)
    }

    @Test func theSizeIsInWholePoints() {
        for look in TimerOverlaySettings.Look.allCases {
            for digitSize in [28, 33, 40, 57, 140] {
                let measured = size(TimerOverlayContent(text: "02:30", label: "Fire res"), settings { $0.look = look; $0.digitSize = digitSize })
                #expect(measured.width == measured.width.rounded() && measured.height == measured.height.rounded(),
                        "\(look) at \(digitSize): \(measured)")
            }
        }
    }

    @Test func theDefaultPlateIsAboutTheOldOverlaysSize() {
        // The merged timer app's overlay covered 153 x 63 px at 40 pt (spec 5.6.5); the default spot was chosen for it.
        let measured = size(TimerOverlayContent(text: "02:30"), TimerOverlaySettings())
        #expect(measured.width >= 110 && measured.width <= 170, "\(measured)")
        #expect(measured.height >= 50 && measured.height <= 75, "\(measured)")
    }

    @Test func thePlateGrowsWithTheDigits() {
        let small = size(TimerOverlayContent(text: "02:30"), settings { $0.digitSize = 28 })
        let large = size(TimerOverlayContent(text: "02:30"), settings { $0.digitSize = 140 })
        #expect(large.width > small.width * 4 && large.height > small.height * 3)
    }

    @Test func aLabelOrPausedAddsALineAndABarAddsHeight() {
        let plain = size(TimerOverlayContent(text: "02:30"), TimerOverlaySettings())
        #expect(size(TimerOverlayContent(text: "02:30", label: "Fire res"), TimerOverlaySettings()).height > plain.height)
        #expect(size(TimerOverlayContent(text: "02:30", state: .paused), TimerOverlaySettings()).height > plain.height)
        #expect(size(TimerOverlayContent(text: "02:30", progress: 1), settings { $0.progress = .bar }).height > plain.height)
        #expect(size(TimerOverlayContent(text: "02:30", progress: 1), TimerOverlaySettings()) == plain, "no bar unless asked")
    }

    @Test func aRingMakesTheSecondsSquare() {
        let ringed = size(TimerOverlayContent(text: "02:30", progress: 1), settings { $0.progress = .ring })
        #expect(ringed.width == ringed.height)
        #expect(ringed.width > size(TimerOverlayContent(text: "02:30"), TimerOverlaySettings()).width)
    }

    // MARK: Values never animate (spec 3.4)

    @Test func theControlShowsAnAnimationUnderWay() {
        let shown = Shown(TimerOverlayContent(text: ""))
        let hosted = Windowless(Swatch(shown: shown))
        withAnimation(.linear(duration: 10)) { shown.isOn = true }
        let settled = Windowless(Swatch(shown: { let s = Shown(TimerOverlayContent(text: "")); s.isOn = true; return s }())).capture()
        #expect(!sameImage(hosted.capture(), settled), "an animated change is visible part way")
    }

    @Test(arguments: TimerOverlaySettings.Look.allCases)
    func theDigitsColorsAndProgressChangeAtOnceEvenInsideAnAnimation(look: TimerOverlaySettings.Look) {
        let drawn = settings { $0.look = look; $0.progress = .bar }
        let before = TimerOverlayContent(text: "00:31", state: .counting, progress: 0.21)
        let after = TimerOverlayContent(text: "00:30", state: .nearZeroGold, progress: 0.2)
        let shown = Shown(before)
        let hosted = Windowless(Observed(shown: shown, settings: drawn))
        withAnimation(.linear(duration: 10)) { shown.content = after }
        let settled = Windowless(Observed(shown: Shown(after), settings: drawn)).capture()
        #expect(sameImage(hosted.capture(), settled))

        withAnimation(.linear(duration: 10)) { shown.content = TimerOverlayContent(text: "00:00", state: .timesUp, progress: 0) }
        let timesUp = Windowless(Observed(shown: Shown(TimerOverlayContent(text: "00:00", state: .timesUp, progress: 0)),
                                          settings: drawn)).capture()
        #expect(sameImage(hosted.capture(), timesUp), "the time's-up look arrives at once")
    }
}
