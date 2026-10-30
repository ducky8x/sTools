import AppKit
import CoreGraphics
import Foundation
import ImageIO
import STDesign
import STPlatform
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Backdrop

// Renders the Window Backdrop page off screen, at a fixed 2x, in a window that is never shown, with an Animated fill
// chosen from a GIF the test makes. With `STOOLS_RENDER_DIR` set, each render is also written there as a PNG, to be
// looked at.

/// A borderless window that's never shown, with a fixed backing scale, so text is rasterized at the scale it's captured at.
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

/// The page hosted at a fixed width in a window that's never ordered in.
@MainActor
private final class PageStage {
    let host: NSHostingView<AnyView>
    let window: FixedScaleWindow
    private let width: CGFloat
    private let scale = 2

    init(controller: BackdropController, theme: STTheme = STTheme(), width: CGFloat = 620) {
        _ = NSApplication.shared
        STFont.register()
        self.width = width
        let page = BackdropSettingsView(controller: controller)
            .environment(\.stTheme, theme)
            .environment(\.stSoundPlayer, STSoundPlayer.silent)
            .padding(24)
            .frame(width: width, alignment: .topLeading)
            .background(STColor.background)
        host = NSHostingView(rootView: AnyView(page))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(x: 0, y: 0, width: width, height: 100)
        window = FixedScaleWindow(size: host.frame.size, scale: CGFloat(scale))
        window.contentView = host
        fit()
    }

    /// Sizes the host to the page's height at the stage's width.
    func fit() {
        host.layoutSubtreeIfNeeded()
        let height = max(1, host.fittingSize.height.rounded(.up))
        host.setFrameSize(CGSize(width: width, height: height))
        window.setContentSize(host.frame.size)
        host.layoutSubtreeIfNeeded()
    }

    func capture() async -> NSBitmapImageRep {
        // Lets the page's own updates (a first frame that has just come in) reach the view before it's drawn, without
        // holding the main actor: other tests in the process need it.
        let end = SuspendingClock.now.advanced(by: .seconds(0.1))
        repeat {
            fit()
            try? await Task.sleep(for: .milliseconds(20))
        } while SuspendingClock.now < end
        let size = host.bounds.size
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
}

/// Writes `rep` as `<name>.png` into `STOOLS_RENDER_DIR`, when that is set.
private func save(_ rep: NSBitmapImageRep, as name: String) {
    guard let directory = ProcessInfo.processInfo.environment["STOOLS_RENDER_DIR"], !directory.isEmpty,
          let data = rep.representation(using: .png, properties: [:]) else { return }
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try? data.write(to: URL(fileURLWithPath: directory).appending(path: "\(name).png"))
}

/// How many pixels are close to `color`, read straight from the bitmap's bytes (red, green, blue, alpha).
private func count(_ color: RGB, in rep: NSBitmapImageRep, tolerance: Int = 24) -> Int {
    guard let data = rep.bitmapData, rep.bitsPerPixel == 32 else { return 0 }
    var total = 0
    for y in 0..<rep.pixelsHigh {
        let row = data + y * rep.bytesPerRow
        for x in 0..<rep.pixelsWide {
            let offset = x * 4
            if abs(Int(row[offset]) - Int(color.r)) <= tolerance && abs(Int(row[offset + 1]) - Int(color.g)) <= tolerance
                && abs(Int(row[offset + 2]) - Int(color.b)) <= tolerance { total += 1 }
        }
    }
    return total
}

@MainActor
@Suite("Window Backdrop page with an Animated fill", .serialized)
struct BackdropPageRenderTests {
    /// A GIF whose first frame is green and whose second is red, `width` x `height` pixels.
    private func chooseGIF(_ rig: AnimatedRig, width: Int = 40, height: Int = 20) async {
        let gif = TestMedia.writeGIF(to: rig.folder.file("loop.gif"), colors: [.green, .red], delays: [0.1, 0.1], width: width, height: height)
        await rig.controller.importAnimation(from: gif)
    }

    @Test func thePreviewShowsTheFirstFrameFilledToThePlate() async throws {
        let rig = AnimatedRig()
        await chooseGIF(rig)
        #expect(await waitUntil { rig.controller.image(for: rig.controller.settings.fill) != nil })
        let stage = PageStage(controller: rig.controller)
        let rep = await stage.capture()
        save(rep, as: "backdrop-animated-fill")
        // Fill covers the plate, so a good part of it is the GIF's first frame, and none of it the second.
        #expect(count(.green, in: rep) > 20_000)
        #expect(count(.red, in: rep) == 0)
    }

    @Test func fitShowsTheWholeFrameWithTheBackgroundAroundIt() async throws {
        let rig = AnimatedRig()
        // A tall picture in a wide plate: with Fit it stands in the middle with the background beside it.
        await chooseGIF(rig, width: 20, height: 40)
        rig.controller.settings.fill.imageContentMode = .fit
        rig.controller.settings.fill.imageBackgroundColor = "#0000FF"
        #expect(await waitUntil { rig.controller.image(for: rig.controller.settings.fill) != nil })
        let stage = PageStage(controller: rig.controller)
        let rep = await stage.capture()
        save(rep, as: "backdrop-animated-fill-fit")
        let green = count(.green, in: rep), blue = count(.blue, in: rep)
        #expect(green > 2_000, "the frame is there")
        #expect(blue > green, "and the background beside it is more than the frame, because the plate is wider than the frame")
    }

    @Test func aFileThatCantBePlayedShowsAPlainLineInRed() async throws {
        let rig = AnimatedRig()
        await chooseGIF(rig)
        await rig.services.settings.flush()
        let fill = rig.controller.settings.fill
        let calm = await PageStage(controller: rig.controller).capture()
        #expect(count(STColor.danger.rgb, in: calm, tolerance: 30) == 0, "a file that plays has no line")

        // The next launch, with the file gone: the page's first look at the fill finds it out.
        try FileManager.default.removeItem(at: rig.imagesDirectory.appending(path: ((fill.animationName ?? "") as NSString).lastPathComponent))
        let next = AnimatedRig(folder: rig.folder)
        #expect(next.controller.settings.fill == fill)
        _ = next.controller.image(for: fill)
        #expect(await waitUntil { next.controller.animationProblem(for: fill) != nil })
        let broken = await PageStage(controller: next.controller).capture()
        save(broken, as: "backdrop-animated-fill-problem")
        #expect(count(STColor.danger.rgb, in: broken, tolerance: 30) > 50, "the line is drawn in the danger color")
    }

    @Test func theCostNoteDependsOnWhatTheFileTurnsOutToBe() {
        #expect(BackdropFillEditor.costNote(for: .video) == "A video is usually decoded by the Mac\u{2019}s video hardware, so it costs little.")
        #expect(BackdropFillEditor.costNote(for: .gif) == "A GIF is decoded by the CPU, so a large one costs much more than a small one.")
        #expect(BackdropFillEditor.costNote(for: nil) == nil, "nothing is said about a file that isn't known yet")
        #expect(BackdropFillEditor.animationNote == "Loops with no sound and stops while the backdrop is hidden. The preview shows the first frame.")
    }

    @Test func theCostNoteAppearsOnThePageOnceTheFileIsKnown() async throws {
        let rig = AnimatedRig()
        await chooseGIF(rig)
        let fill = rig.controller.settings.fill
        #expect(rig.controller.animationKind(for: fill) == nil, "the first frame hasn't been read yet")
        let before = PageStage(controller: rig.controller)
        let heightBefore = before.host.bounds.height
        #expect(await waitUntil { rig.controller.animationKind(for: fill) == .gif })
        let after = PageStage(controller: rig.controller)
        save(await after.capture(), as: "backdrop-animated-fill-gif")
        #expect(after.host.bounds.height > heightBefore, "a line was added under the Animation row")
    }

    /// Under reduced motion the fill holds still, and the page says so in one line.
    @Test func aLineSaysItHoldsStillWhileMotionIsReduced() async throws {
        #expect(BackdropFillEditor.reducedMotionNote == "Motion is reduced, so it holds still on its first frame.")
        let rig = AnimatedRig()
        await chooseGIF(rig)
        let fill = rig.controller.settings.fill
        _ = rig.controller.image(for: fill) // the page's first look starts reading the file
        #expect(await waitUntil { rig.controller.animationKind(for: fill) == .gif })
        let calm = PageStage(controller: rig.controller, theme: STTheme())
        for theme in [STTheme(motionMode: .reduced), STTheme(systemReduceMotion: true)] {
            let reduced = PageStage(controller: rig.controller, theme: theme)
            #expect(reduced.host.bounds.height > calm.host.bounds.height, "one line is added under the notes")
        }
        save(await PageStage(controller: rig.controller, theme: STTheme(motionMode: .reduced)).capture(), as: "backdrop-animated-fill-reduced")
    }

    @Test func noLineAboutReducedMotionIsAddedToAnotherKindOfFill() async throws {
        let rig = AnimatedRig()
        let calm = PageStage(controller: rig.controller, theme: STTheme())
        let reduced = PageStage(controller: rig.controller, theme: STTheme(motionMode: .reduced))
        #expect(reduced.host.bounds.height == calm.host.bounds.height)
    }

    @Test func anAnimatedFillWithNoFileYetShowsOnlyItsBackground() async throws {
        let rig = AnimatedRig()
        rig.controller.settings.fill.kind = .animated
        rig.controller.settings.fill.imageBackgroundColor = "#00FF00"
        let rep = await PageStage(controller: rig.controller).capture()
        save(rep, as: "backdrop-animated-fill-empty")
        #expect(count(.green, in: rep) > 20_000, "the plate is the fill's background color")
    }
}

private extension Color {
    /// This color as bytes, in sRGB.
    var rgb: RGB {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .black
        func byte(_ value: CGFloat) -> UInt8 { UInt8((value * 255).rounded()) }
        return RGB(byte(color.redComponent), byte(color.greenComponent), byte(color.blueComponent))
    }
}
