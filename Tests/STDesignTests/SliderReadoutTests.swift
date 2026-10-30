import AppKit
import SwiftUI
import Testing
@testable import STDesign

// A slider's value stays on one line. Screen Recording's Low-disk warning ("under 100 GB") wrapped onto two at the 680 pt
// window, where a settings row has a 371 pt column, and Crosshair's Offset X and Y ("-500 px", the wider end of their range)
// wrapped in the text that sizes the readout, which made those rows 16 pt taller than the others. The steppers around the
// readout are offered only a share of the slider's width; fixed at their own width, they leave the track to give way.

/// A readout the app puts on a slider, with the label of its row: the two that wrapped, and a short one.
enum SliderReadout: CaseIterable, Sendable, CustomTestStringConvertible {
    case lowDisk, offset, quality

    var testDescription: String { label }

    var label: String {
        switch self {
        case .lowDisk: "Low-disk warning"
        case .offset: "Offset X"
        case .quality: "Quality"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .lowDisk: 1...100
        case .offset: -500...500
        case .quality: 10...100
        }
    }

    var value: Double {
        switch self {
        case .lowDisk: 20
        case .offset: -250
        case .quality: 70
        }
    }

    func text(_ value: Double) -> String {
        switch self {
        case .lowDisk: "under \(Int(value)) GB"
        case .offset: "\(Int(value)) px"
        case .quality: "\(Int(value))%"
        }
    }

    @MainActor
    var slider: STSlider {
        STSlider(value: .constant(value), in: range, label: label, valueText: { text($0) })
    }
}

/// Where a slider ended up in a row laid out in a window that is never shown.
@MainActor
private final class Placement {
    var frame = CGRect.zero
}

@MainActor
@Suite("Slider readout")
struct SliderReadoutTests {
    /// The window's 680 pt minimum, less its 237 pt sidebar and the page's 36 pt margins.
    private static let narrowestColumn: CGFloat = 371

    /// What a slider in a settings row measures once the row is laid out `width` wide, at `textScale`.
    private func placed<V: View>(_ slider: V, label: String, width: CGFloat, textScale: Double = 1) -> CGRect {
        _ = NSApplication.shared
        let placement = Placement()
        let row = STSettingsRow(label) {
            slider.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { placement.frame = $0 })
        }
        let host = hostingView(AnyView(
            row.environment(\.stSoundPlayer, STSoundPlayer.silent).environment(\.stTheme, STTheme(textScale: textScale))
                .frame(width: width)))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: CGSize(width: width, height: ceil(host.fittingSize.height)))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // Until the slider reports where it is (bounded by awake time, so a busy Mac gets all it needs), then a few more
        // passes in case the layout moves it.
        let deadline = SuspendingClock.now.advanced(by: .seconds(10))
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while placement.frame.isEmpty && SuspendingClock.now < deadline
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        window.contentView = nil
        return placement.frame
    }

    private static var oneLineHeights: [Double: CGFloat] = [:]

    /// A slider's height when its readout is one line: a short one, in a row with room to spare.
    private func oneLine(textScale: Double = 1) -> CGFloat {
        if let known = Self.oneLineHeights[textScale] { return known }
        let short = STSlider(value: .constant(5), in: 0...9, label: "Short", valueText: { "\(Int($0))%" })
        let height = placed(short, label: "Short", width: 600, textScale: textScale).height
        Self.oneLineHeights[textScale] = height
        return height
    }

    @Test(arguments: SliderReadout.allCases)
    func theValueKeepsOneLineInTheNarrowestWindow(readout: SliderReadout) {
        let frame = placed(readout.slider, label: readout.label, width: Self.narrowestColumn)
        #expect(frame.height > 0, "the slider was laid out")
        #expect(frame.height == oneLine(), "\(frame.height) pt tall: the value wrapped onto a second line")
    }

    /// The label gives way before the slider spills out of the column, at the largest text size too.
    @Test(arguments: SliderReadout.allCases, [1.0, 1.1, 1.3])
    func theSliderStaysInsideTheNarrowestColumn(readout: SliderReadout, textScale: Double) {
        let frame = placed(readout.slider, label: readout.label, width: Self.narrowestColumn, textScale: textScale)
        #expect(frame.maxX <= Self.narrowestColumn + 0.5, "ends at \(frame.maxX) pt of \(Self.narrowestColumn)")
        #expect(frame.height == oneLine(textScale: textScale), "\(frame.height) pt tall at \(textScale)x: the value wrapped")
    }

    /// Whatever room the slider is given, its value stays on one line: the track takes the squeeze.
    @Test(arguments: SliderReadout.allCases, [168.0, 200, 230, 260])
    func theValueNeverWrapsWhateverRoomTheSliderGets(readout: SliderReadout, width: CGFloat) {
        let height = hostingView(AnyView(
            readout.slider.labelsHidden().environment(\.stSoundPlayer, STSoundPlayer.silent).frame(width: width))).fittingSize.height
        #expect(height == oneLine(), "\(height) pt tall in \(width) pt: the value wrapped")
    }

    /// A slider asks for no more than it needs: its ideal width is its least, so a `ViewThatFits` that offers it beside
    /// something (the Quality row, beside its choice) keeps it there for as long as its track has its 80 pt, and not only
    /// while the track has the room it would like.
    @Test(arguments: SliderReadout.allCases)
    func aSliderAsksForNoMoreThanItNeeds(readout: SliderReadout) {
        let slider = AnyView(readout.slider.labelsHidden().environment(\.stSoundPlayer, STSoundPlayer.silent))
        let ideal = hostingView(slider).fittingSize.width
        let least = NSHostingController(rootView: slider).sizeThatFits(in: CGSize(width: 0, height: 1_000)).width
        #expect(abs(ideal - least) < 0.5, "wants \(ideal) pt and needs \(least) pt")
    }

    /// The control: a slider with a short readout is as wide as it ever was, so keeping the long ones on one line took
    /// nothing from it. (Fixed steppers beside a track held to 96 pt made the row share its room out another way and left
    /// these 41 pt short of 260 in the default window.)
    @Test(arguments: [("Opacity", 371.0, 260.0), ("Opacity", 487, 260), ("Edge width", 371, 240), ("Edge width", 487, 260)])
    func aShortReadoutKeepsTheSliderItsFullWidth(label: String, column: CGFloat, atLeast: CGFloat) {
        let slider = STSlider(value: .constant(50), in: 10...100, label: label, valueText: { "\(Int($0))%" })
        let frame = placed(slider, label: label, width: column)
        #expect(frame.width >= atLeast, "\(frame.width) pt wide in a \(column) pt column")
        #expect(frame.width <= STSlider.rowWidth)
    }
}
