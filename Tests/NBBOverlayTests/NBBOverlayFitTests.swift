import AppKit
import STDesign
import SwiftUI
import Testing
@testable import NBBOverlay

// The overlay's content fits its plate (spec 5.1.3): drawn off-screen at 2x in a window that's never ordered in.

/// A borderless window that's never shown, drawing at 2x whatever the real displays are.
@MainActor
private final class FitRenderWindow: NSWindow {
    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }

    override var backingScaleFactor: CGFloat { 2 }
}

@MainActor
private func render<V: View>(_ view: V) -> NSBitmapImageRep {
    _ = NSApplication.shared
    STFont.register()
    let host = NSHostingView(rootView: view)
    let size = host.fittingSize
    host.frame = CGRect(origin: .zero, size: size)
    let window = FitRenderWindow(size: size)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    window.contentView = nil
    return rep
}

/// Pixels within `tolerance` of `hex` (sRGB) in each channel, in the rows `rows` (in points, from the top).
private func pixels(near hex: String, in rep: NSBitmapImageRep, tolerance: Int = 4, rows: Range<Int>? = nil) -> Int {
    let value = Int(hex.dropFirst(), radix: 16)!
    let srgb = NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    guard let inRep = srgb.usingColorSpace(rep.colorSpace), let data = rep.bitmapData, rep.bitsPerPixel == 32 else { return 0 }
    let target = [inRep.redComponent, inRep.greenComponent, inRep.blueComponent].map { Int(($0 * 255).rounded()) }
    let scale = rep.pixelsHigh / Int(rep.size.height)
    let rowRange = rows.map { ($0.lowerBound * scale)..<min($0.upperBound * scale, rep.pixelsHigh) } ?? 0..<rep.pixelsHigh
    var count = 0
    for y in rowRange {
        for x in 0..<rep.pixelsWide {
            let pixel = data + y * rep.bytesPerRow + x * 4
            if pixel[3] == 255, (0..<3).allSatisfy({ abs(Int(pixel[$0]) - target[$0]) <= tolerance }) { count += 1 }
        }
    }
    return count
}

/// Whether two renders of one width draw the same inside the plate's edges, in the rows `rows` (in points, from the top),
/// to within a step of each channel (a rounded corner rasterizes a hair differently at another height).
private func sameInside(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, rows: Range<Int>) -> Bool {
    guard a.pixelsWide == b.pixelsWide, a.bytesPerRow == b.bytesPerRow, let left = a.bitmapData, let right = b.bitmapData else { return false }
    let scale = a.pixelsHigh / Int(a.size.height)
    let inset = 14 * scale
    for y in (rows.lowerBound * scale)..<(rows.upperBound * scale) {
        for byte in (inset * 4)..<((a.pixelsWide - inset) * 4) {
            let offset = y * a.bytesPerRow + byte
            if abs(Int(left[offset]) - Int(right[offset])) > 2 { return false }
        }
    }
    return true
}

private func eyeThrow(_ x: Double, _ z: Double, without: Double, correction: Double, increments: Int, error: Double) -> NBBEvents.EyeThrow {
    NBBEvents.EyeThrow(
        xInOverworld: x, zInOverworld: z, angle: without + correction, angleWithoutCorrection: without, correction: correction,
        correctionIncrements: increments, error: error, type: "NORMAL")
}

/// Five predictions and three throws; only the last throw's angle was adjusted (+0.06, Ninjabrain Bot's green), so the
/// green shows only when the last throw does.
private let fiveAndThree = NBBEvents.Stronghold(
    resultType: .triangulation,
    predictions: [
        NBBEvents.Prediction(chunkX: -141, chunkZ: 108, certainty: 0.874, overworldDistance: 1580.4),
        NBBEvents.Prediction(chunkX: -139, chunkZ: 110, certainty: 0.061, overworldDistance: 1612.2),
        NBBEvents.Prediction(chunkX: -143, chunkZ: 106, certainty: 0.032, overworldDistance: 1549.9),
        NBBEvents.Prediction(chunkX: -138, chunkZ: 104, certainty: 0.018, overworldDistance: 1650.0),
        NBBEvents.Prediction(chunkX: -145, chunkZ: 112, certainty: 0.011, overworldDistance: 1499.7),
    ],
    eyeThrows: [
        eyeThrow(-1374.7, 81.61, without: -80.64, correction: 0, increments: 0, error: 0.0022),
        eyeThrow(-1290.2, 340.1, without: -78.92, correction: 0, increments: 0, error: -0.0041),
        eyeThrow(-1102.5, 512.9, without: -75.12, correction: 0.06, increments: 6, error: 0.0013),
    ],
    playerPosition: NBBEvents.PlayerPosition(
        xInOverworld: -1102.5, zInOverworld: 512.9, horizontalAngle: -75.12, isInOverworld: true, isInNether: false))

/// One prediction and no throws: far shorter than the plate.
private let short = NBBEvents.Stronghold(
    resultType: .triangulation,
    predictions: [NBBEvents.Prediction(chunkX: -41, chunkZ: 108, certainty: 0.94, overworldDistance: 1580)],
    eyeThrows: [], playerPosition: nil)

/// ducky's own overlay: 320 pt wide at 1.6, so a 320 × 200 plate, up to 5 predictions, every column and block on; drawn
/// opaque so its colors are exact.
private func duckysSettings(aspectRatio: Double = 1.6) -> NBBOverlaySettings {
    var settings = NBBOverlaySettings()
    settings.width = 320
    settings.aspectRatio = aspectRatio
    settings.maxPredictionRows = 5
    settings.plateOpacityPercent = 100
    return settings
}

@MainActor
private func overlay(_ stronghold: NBBEvents.Stronghold, _ settings: NBBOverlaySettings, boat: NBBEvents.BoatState? = .measuring) -> NBBOverlayView {
    let content = NBBOverlayLayout.content(
        stronghold: stronghold, blind: nil, divine: nil, boat: nil, allAdvancements: nil, maxPredictionRows: settings.maxPredictionRows)
    return NBBOverlayView(content: content, messages: [], settings: settings, boat: boat.map { NBBEvents.Boat(boatState: $0, boatAngle: nil) })
}

/// The predictions and throws' own size, laid out at the width inside ducky's plate's padding, as the overlay lays them out.
@MainActor
private func naturalSize(_ stronghold: NBBEvents.Stronghold) -> CGSize {
    let settings = duckysSettings()
    let content = NBBOverlayLayout.content(stronghold: stronghold, blind: nil, divine: nil, boat: nil, allAdvancements: nil, maxPredictionRows: 5)
    guard case .triangulation(let data) = content else { return .zero }
    STFont.register()
    return NSHostingController(rootView: NBBNaturalSize(width: 292) { NBBTriangulationBlock(data: data, settings: settings) })
        .sizeThatFits(in: CGSize(width: 292, height: CGFloat.greatestFiniteMagnitude))
}

@Suite("NBB overlay fits its plate")
struct NBBOverlayFitTests {
    /// ducky's report: "the overlay doesnt have the offsets still". At 320 × 200 with a boat, five predictions and three
    /// throws, the last throws fell below the plate's bottom edge and were cut off, their adjustments with them.
    @MainActor @Test func theLastThrowsAdjustmentShowsOnDuckysPlate() {
        let rep = render(overlay(fiveAndThree, duckysSettings()))
        #expect(rep.size == CGSize(width: 320, height: 200))
        // The bottom half of the plate, below the Overworld mark (a green close to the adjustment's).
        #expect(pixels(near: NBBAngleCorrection.colorHex("+0.06"), in: rep, rows: 100..<200) > 10, "the third throw's +0.06 is drawn")
    }

    /// Content that fits isn't scaled: on ducky's 320 × 200 plate a short result draws exactly as on a plate twice as
    /// tall, where the five predictions and three throws draw smaller (scaled to fit) than on the taller plate.
    @MainActor @Test func contentThatFitsIsDrawnAtItsOwnSize() {
        let shortOnDuckys = render(overlay(short, duckysSettings()))
        let shortOnTall = render(overlay(short, duckysSettings(aspectRatio: 0.8)))
        #expect(shortOnTall.size == CGSize(width: 320, height: 400))
        #expect(sameInside(shortOnDuckys, shortOnTall, rows: 0..<150))
        #expect(NBBPlateFit.scale(natural: naturalSize(short), available: CGSize(width: 292, height: 172)) == 1)

        let fullOnDuckys = render(overlay(fiveAndThree, duckysSettings()))
        let fullOnTall = render(overlay(fiveAndThree, duckysSettings(aspectRatio: 0.8)))
        #expect(!sameInside(fullOnDuckys, fullOnTall, rows: 0..<150), "the taller content is scaled on the short plate")
    }

    @Test func theScaleFitsTheTighterSideAndNeverGrows() {
        let room = CGSize(width: 292, height: 172)
        #expect(NBBPlateFit.scale(natural: CGSize(width: 250, height: 120), available: room) == 1, "fits: not scaled")
        #expect(NBBPlateFit.scale(natural: CGSize(width: 100, height: 50), available: room) == 1, "never scaled up")
        #expect(NBBPlateFit.scale(natural: CGSize(width: 250, height: 215), available: room) == 0.8, "taller")
        #expect(NBBPlateFit.scale(natural: CGSize(width: 365, height: 100), available: room) == 0.8, "wider")
        #expect(abs(NBBPlateFit.scale(natural: CGSize(width: 365, height: 172 / 0.7), available: room) - 0.7) < 1e-9, "both: the tighter")
        #expect(NBBPlateFit.scale(natural: .zero, available: room) == 1)
    }

    /// Past the minimum scale the content stays at it and the plate clips the rest, as it did before fitting.
    @Test func theScaleStopsAtTheMinimum() {
        let room = CGSize(width: 292, height: 172)
        #expect(NBBPlateFit.minimumScale == 0.6)
        #expect(NBBPlateFit.scale(natural: CGSize(width: 250, height: 172 / 0.6), available: room) == 0.6)
        #expect(NBBPlateFit.scale(natural: CGSize(width: 250, height: 1000), available: room) == 0.6)
        #expect(NBBPlateFit.scale(natural: CGSize(width: 2000, height: 100), available: room) == 0.6)
        #expect(NBBPlateFit.scale(natural: CGSize(width: 250, height: 100), available: CGSize(width: -5, height: -5)) == 0.6)
    }

    /// A result far taller than the plate (five predictions and ten throws) is drawn at the minimum scale, its top still
    /// there: the top prediction's gold certainty.
    @MainActor @Test func farTallerContentIsDrawnAtTheMinimumAndClipped() {
        var tall = fiveAndThree
        tall.eyeThrows = (0..<10).map { eyeThrow(-1374.7 + Double($0) * 40, 81.61 + Double($0) * 30, without: -80.64, correction: 0, increments: 0, error: 0.001) }
        let settings = duckysSettings()
        let natural = naturalSize(tall)
        #expect(natural.height * NBBPlateFit.minimumScale > 172, "taller than the plate even at the minimum")
        #expect(NBBPlateFit.scale(natural: natural, available: CGSize(width: 292, height: 172)) == NBBPlateFit.minimumScale)
        let rep = render(overlay(tall, settings, boat: nil))
        #expect(rep.size == CGSize(width: 320, height: 200))
        #expect(pixels(near: STPalette.gold, in: rep, tolerance: 8) > 10, "the top prediction's certainty is drawn")
    }
}
