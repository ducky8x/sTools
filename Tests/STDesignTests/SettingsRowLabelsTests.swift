import AppKit
import SwiftUI
import Testing
@testable import STDesign

// A settings row names its control on the left, so the control must not name itself again
// (STSettingsRow hides its control's labels; STSlider honors that).

@MainActor
private final class VisibilityBox {
    var seen: Visibility?
}

/// Records the labels visibility it is given.
private struct LabelsVisibilityProbe: View {
    let box: VisibilityBox
    @Environment(\.labelsVisibility) private var visibility

    var body: some View {
        box.seen = visibility
        return Color.clear.frame(width: 20, height: 20)
    }
}

/// A view hosted in an unshown window at `width`, as tall as it wants to be.
@MainActor
private final class Hosted {
    let host: NSHostingView<AnyView>
    let window: NSWindow
    let size: CGSize

    init<V: View>(_ view: V, width: CGFloat) {
        _ = NSApplication.shared
        host = hostingView(AnyView(
            view
                .environment(\.stSoundPlayer, STSoundPlayer.silent)
                .frame(width: width)
                .background(STColor.background)))
        host.appearance = NSAppearance(named: .darkAqua)
        size = CGSize(width: width, height: ceil(host.fittingSize.height))
        host.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        let end = Date().addingTimeInterval(0.15)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        } while Date() < end
    }

    /// The view at 1 pixel per point.
    func capture() -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    deinit {
        MainActor.assumeIsolated { window.contentView = nil }
    }
}

@MainActor
private func fittingHeight<V: View>(_ view: V, width: CGFloat = 360) -> CGFloat {
    hostingView(view.environment(\.stSoundPlayer, STSoundPlayer.silent).frame(width: width)).fittingSize.height
}

private func rgb(_ rep: NSBitmapImageRep, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
    guard let data = rep.bitmapData else { return (0, 0, 0) }
    let p = data + y * rep.bytesPerRow + x * (rep.bitsPerPixel / 8)
    return (Int(p[0]), Int(p[1]), Int(p[2]))
}

/// How many pixels in the rectangle are brighter than `threshold` (the mean of the three channels). The background
/// is near black; 70 catches every control color, 140 only text and the thumb (not the `stroke` track).
private func lightPixels(_ rep: NSBitmapImageRep, x: Range<Int>, y: Range<Int>, threshold: Int = 70) -> Int {
    var count = 0
    for py in y.clamped(to: 0..<rep.pixelsHigh) {
        for px in x.clamped(to: 0..<rep.pixelsWide) {
            let p = rgb(rep, x: px, y: py)
            if p.r + p.g + p.b > 3 * threshold { count += 1 }
        }
    }
    return count
}

/// The x just past the right end of the unfilled (stroke-colored) part of a slider track: the last pixel of the
/// longest stroke-colored run along any row.
private func trackRightEnd(_ rep: NSBitmapImageRep) -> Int? {
    let stroke = (r: 0x6E, g: 0x65, b: 0x5B)
    var best: (length: Int, end: Int)?
    for y in 0..<rep.pixelsHigh {
        var run = 0
        for x in 0...rep.pixelsWide {
            let p = x < rep.pixelsWide ? rgb(rep, x: x, y: y) : (r: 0, g: 0, b: 0)
            if abs(p.r - stroke.r) <= 10 && abs(p.g - stroke.g) <= 10 && abs(p.b - stroke.b) <= 10 {
                run += 1
            } else {
                if run > (best?.length ?? 0) { best = (run, x) }
                run = 0
            }
        }
    }
    return best.map(\.end)
}

@MainActor
@Suite("Settings rows name their controls once")
struct SettingsRowLabelsTests {
    @Test func settingsRowHidesItsControlsLabels() {
        let inRow = VisibilityBox()
        _ = fittingHeight(STSettingsRow("Size") { LabelsVisibilityProbe(box: inRow) })
        #expect(inRow.seen == .hidden)

        let alone = VisibilityBox()
        _ = fittingHeight(LabelsVisibilityProbe(box: alone))
        #expect(alone.seen != nil)
        #expect(alone.seen != .hidden)
    }

    @Test func sliderShowsItsOwnLabelOnlyWhenLabelsAreVisible() {
        let visible = fittingHeight(STSlider(value: .constant(40), in: 0...100, label: "Size"))
        let hidden = fittingHeight(STSlider(value: .constant(40), in: 0...100, label: "Size").labelsHidden())
        // Hidden: one line, the track beside the − readout + steppers. Visible: a label line above the track.
        #expect(hidden <= 30)
        #expect(visible >= hidden + 16)
    }

    @Test func standaloneSliderDrawsItsLabelAboveTheTrack() {
        let rep = Hosted(STSlider(value: .constant(0), in: 0...100, label: "Thickness"), width: 320).capture()
        // The label's text sits at the top left, well above the track.
        #expect(lightPixels(rep, x: 0..<120, y: 0..<18, threshold: 140) > 40)
    }

    @Test func settingsRowWithASliderIsOneLineTall() {
        let row = fittingHeight(STSettingsRow("Size") { STSlider(value: .constant(40), in: 0...100, label: "Size") })
        let oneLine = fittingHeight(STSlider(value: .constant(40), in: 0...100, label: "Size").labelsHidden())
        let labeled = fittingHeight(STSlider(value: .constant(40), in: 0...100, label: "Size"))
        // The row adds 12 pt above and below its control.
        #expect(abs(row - (oneLine + 24)) <= 1)
        #expect(row + 16 <= labeled + 24)
    }

    @Test func hiddenLabelSliderTrackKeepsItsLengthAsTheReadoutWidens() throws {
        func slider(_ value: Double) -> some View {
            STSlider(value: .constant(value), in: -500...500, label: "Offset X", valueText: { "\(Int($0)) px" }).labelsHidden()
        }
        let short = try #require(trackRightEnd(Hosted(slider(0), width: 320).capture()))
        let wide = try #require(trackRightEnd(Hosted(slider(-500), width: 320).capture()))
        #expect(short > 160)
        #expect(short == wide)
    }

    @Test func otherControlsStillShowTheirContentInARow() {
        func rightHalfInk<V: View>(_ control: V) -> Int {
            let rep = Hosted(STSettingsRow("Name") { control }, width: 400).capture()
            return lightPixels(rep, x: 200..<400, y: 0..<rep.pixelsHigh)
        }
        // The text field's prompt, the segmented choice's words, the switch and the swatch all stay visible.
        #expect(rightHalfInk(STTextField("Search", text: .constant("")).frame(width: 160)) > 40)
        #expect(rightHalfInk(STSegmented(selection: .constant(1), options: [STSegmentedOption(1, "One"), STSegmentedOption(2, "Two")])) > 40)
        #expect(rightHalfInk(STSwitch(isOn: .constant(true), label: "On")) > 40)
        #expect(rightHalfInk(STColorWell(hex: .constant("#F4EFE6"), label: "Color")) > 40)
    }
}
