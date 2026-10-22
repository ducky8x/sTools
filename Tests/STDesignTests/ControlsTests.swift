import AppKit
import SwiftUI
import Testing
@testable import STDesign

// MARK: - STSliderMath

@Suite("Controls: STSliderMath")
struct ControlsSliderMathTests {
    @Test func snapsToTheNearestStep() {
        #expect(STSliderMath.snapped(7.4, in: 0...10, step: 1) == 7)
        #expect(STSliderMath.snapped(7.5, in: 0...10, step: 1) == 8)
        #expect(STSliderMath.snapped(33, in: 0...100, step: 10) == 30)
        #expect(STSliderMath.snapped(35, in: 0...100, step: 10) == 40)
    }

    @Test func clampsOutOfRangeValues() {
        #expect(STSliderMath.snapped(-5, in: 0...10, step: 1) == 0)
        #expect(STSliderMath.snapped(99, in: 0...10, step: 1) == 10)
        #expect(STSliderMath.snapped(.infinity, in: 0...10, step: 1) == 10)
        #expect(STSliderMath.snapped(-.infinity, in: 0...10, step: 1) == 0)
    }

    @Test func nonFiniteValueFallsBackToLowerBound() {
        #expect(STSliderMath.snapped(.nan, in: 2...10, step: 1) == 2)
    }

    @Test func nonIntegerStepsStayClean() {
        #expect(STSliderMath.snapped(0.1 + 0.2, in: 0...1, step: 0.1) == 0.3)
        #expect(STSliderMath.snapped(0.44, in: 0...1, step: 0.05) == 0.45)
        #expect(STSliderMath.snapped(1.1, in: 0.5...2.0, step: 0.25) == 1.0)
        #expect(STSliderMath.snapped(0.7, in: 0...1, step: 0.1) == 0.7)
    }

    @Test func stepsMeasureFromTheLowerBound() {
        #expect(STSliderMath.snapped(12, in: 5...25, step: 4) == 13)
        #expect(STSliderMath.snapped(10, in: 5...25, step: 4) == 9)
    }

    @Test func upperBoundStaysReachableWhenNotOnAStep() {
        #expect(STSliderMath.snapped(10, in: 0...10, step: 3) == 10)
        #expect(STSliderMath.snapped(9.8, in: 0...10, step: 3) == 10)
        #expect(STSliderMath.snapped(9.4, in: 0...10, step: 3) == 9)
        #expect(STSliderMath.snapped(4.4, in: 0...10, step: 3) == 3)
    }

    @Test func nonPositiveOrNonFiniteStepOnlyClamps() {
        #expect(STSliderMath.snapped(3.14, in: 0...10, step: 0) == 3.14)
        #expect(STSliderMath.snapped(3.14, in: 0...10, step: -1) == 3.14)
        #expect(STSliderMath.snapped(3.14, in: 0...10, step: .nan) == 3.14)
        #expect(STSliderMath.snapped(30, in: 0...10, step: 0) == 10)
    }

    @Test func zeroWidthRangeAlwaysYieldsItsOnlyValue() {
        #expect(STSliderMath.snapped(7, in: 4...4, step: 1) == 4)
        #expect(STSliderMath.fraction(of: 4, in: 4...4) == 0)
        #expect(STSliderMath.value(atFraction: 0.8, in: 4...4, step: 1) == 4)
    }

    @Test func fractionIsProportionalAndClamped() {
        #expect(STSliderMath.fraction(of: 50, in: 0...100) == 0.5)
        #expect(STSliderMath.fraction(of: 15, in: 10...20) == 0.5)
        #expect(STSliderMath.fraction(of: -10, in: 0...100) == 0)
        #expect(STSliderMath.fraction(of: 250, in: 0...100) == 1)
        #expect(STSliderMath.fraction(of: .nan, in: 0...100) == 0)
    }

    @Test func valueAtFractionSnapsAndClamps() {
        #expect(STSliderMath.value(atFraction: 0.5, in: 0...100, step: 10) == 50)
        #expect(STSliderMath.value(atFraction: 0.33, in: 0...100, step: 1) == 33)
        #expect(STSliderMath.value(atFraction: 0.5, in: 0...1, step: 0.1) == 0.5)
        #expect(STSliderMath.value(atFraction: -0.5, in: 10...20, step: 1) == 10)
        #expect(STSliderMath.value(atFraction: 1.5, in: 10...20, step: 1) == 20)
        #expect(STSliderMath.value(atFraction: .nan, in: 10...20, step: 1) == 10)
    }

    @Test func adjustedMovesByWholeStepsAndClamps() {
        #expect(STSliderMath.adjusted(5, by: 1, in: 0...10, step: 1) == 6)
        #expect(STSliderMath.adjusted(5, by: -1, in: 0...10, step: 1) == 4)
        #expect(STSliderMath.adjusted(0, by: -1, in: 0...10, step: 1) == 0)
        #expect(STSliderMath.adjusted(9, by: 10, in: 0...10, step: 1) == 10)
        #expect(STSliderMath.adjusted(0.2, by: 1, in: 0...1, step: 0.1) == 0.3)
        #expect(STSliderMath.adjusted(5.4, by: 1, in: 0...10, step: 1) == 6)
    }

    @Test func trackFractionAccountsForThumbInset() {
        #expect(STSliderMath.fraction(atX: 10, trackWidth: 110, inset: 10) == 0)
        #expect(STSliderMath.fraction(atX: 100, trackWidth: 110, inset: 10) == 1)
        #expect(STSliderMath.fraction(atX: 55, trackWidth: 110, inset: 10) == 0.5)
        #expect(STSliderMath.fraction(atX: 19, trackWidth: 110, inset: 10) == 0.1)
        #expect(STSliderMath.fraction(atX: -30, trackWidth: 110, inset: 10) == 0)
        #expect(STSliderMath.fraction(atX: 500, trackWidth: 110, inset: 10) == 1)
        #expect(STSliderMath.fraction(atX: 5, trackWidth: 20, inset: 10) == 0)
    }

    @Test func defaultReadoutTrimsNoise() {
        #expect(STSlider.defaultValueText(50) == "50")
        #expect(STSlider.defaultValueText(0.25) == "0.25")
        #expect(STSlider.defaultValueText(0.1 + 0.2) == "0.3")
        #expect(STSlider.defaultValueText(1234) == "1234")
        #expect(STSlider.defaultValueText(0.12345) == "0.123")
        #expect(STSlider.defaultValueText(-3) == "-3")
    }
}

// MARK: - STSlider typed entry

@Suite("Controls: STSlider.defaultParse")
struct ControlsSliderParseTests {
    @Test func acceptsPlainNumbersWithSurroundingWhitespace() {
        #expect(STSlider.defaultParse("85") == 85)
        #expect(STSlider.defaultParse("  85  ") == 85)
        #expect(STSlider.defaultParse("\t7\n") == 7)
        #expect(STSlider.defaultParse("0") == 0)
        #expect(STSlider.defaultParse("-3") == -3)
        #expect(STSlider.defaultParse("+3") == 3)
        #expect(STSlider.defaultParse("\u{2212}3") == -3)
        #expect(STSlider.defaultParse("007") == 7)
    }

    @Test func acceptsEitherDecimalSeparator() {
        #expect(STSlider.defaultParse("1.5") == 1.5)
        #expect(STSlider.defaultParse("1,5") == 1.5)
        #expect(STSlider.defaultParse(".5") == 0.5)
        #expect(STSlider.defaultParse(",5") == 0.5)
        #expect(STSlider.defaultParse("5.") == 5)
        #expect(STSlider.defaultParse("-0,25") == -0.25)
    }

    @Test func stripsATrailingUnit() {
        #expect(STSlider.defaultParse("85%") == 85)
        #expect(STSlider.defaultParse("85 %") == 85)
        #expect(STSlider.defaultParse(" 85 % ") == 85)
        #expect(STSlider.defaultParse("1.5x") == 1.5)
        #expect(STSlider.defaultParse("1,5\u{00D7}") == 1.5)
        #expect(STSlider.defaultParse("12 px") == 12)
        #expect(STSlider.defaultParse("12px") == 12)
        #expect(STSlider.defaultParse("40 ms") == 40)
        #expect(STSlider.defaultParse("90\u{00B0}") == 90)
    }

    @Test func rejectsEmptyAndNonNumericInput() {
        for bad in ["", "   ", "abc", "px", "%", "-", ".", ",", "+", "x1.5", "$5", "1 2", "1.2.3", "1,2,3", "1.2,3",
                    "1e5", "0x10", "inf", "nan", "Infinity", "--3", "3-", "1/2", "\u{0661}\u{0662}", "12abc3"] {
            #expect(STSlider.defaultParse(bad) == nil, "\(bad) should be rejected")
        }
    }

    @Test func roundTripsTheDefaultReadout() {
        for value in [0, 50, 0.25, -3, 1234, 0.123] {
            #expect(STSlider.defaultParse(STSlider.defaultValueText(value)) == value)
        }
    }
}

@Suite("Controls: STSliderMath.commit")
struct ControlsSliderCommitTests {
    private func commit(_ text: String, in range: ClosedRange<Double> = 0...100, step: Double = 5,
                        parse: (String) -> Double? = STSlider.defaultParse) -> STSliderMath.Commit {
        STSliderMath.commit(text, in: range, step: step, parse: parse)
    }

    @Test func validInputCommitsItsValue() {
        #expect(commit("45") == .value(45))
        #expect(commit(" 45 % ") == .value(45))
        #expect(commit("0") == .value(0))
        #expect(commit("100") == .value(100))
    }

    @Test func outOfRangeInputIsClamped() {
        #expect(commit("250") == .value(100))
        #expect(commit("-20") == .value(0))
        #expect(commit("9999999999999999999999") == .value(100))
    }

    @Test func offStepInputIsSnapped() {
        #expect(commit("47") == .value(45))
        #expect(commit("48") == .value(50))
        #expect(commit("0,3", in: 0...1, step: 0.1) == .value(0.3))
        #expect(commit("0.44", in: 0...1, step: 0.05) == .value(0.45))
        #expect(commit("12", in: 5...25, step: 4) == .value(13))
    }

    @Test func emptyInputReverts() {
        #expect(commit("") == .revert)
        #expect(commit("   \n") == .revert)
    }

    @Test func unparseableInputIsInvalid() {
        #expect(commit("abc") == .invalid)
        #expect(commit("1.2.3") == .invalid)
        #expect(commit("inf") == .invalid)
    }

    @Test func nonFiniteParseResultIsInvalid() {
        #expect(commit("1", parse: { _ in .infinity }) == .invalid)
        #expect(commit("1", parse: { _ in .nan }) == .invalid)
    }

    @Test func customParseOverridesTheDefault() {
        #expect(commit("85%", in: 0...1, step: 0.05, parse: { Double($0.dropLast()).map { $0 / 100 } }) == .value(0.85))
        #expect(commit("half", parse: { $0 == "half" ? 50 : nil }) == .value(50))
        #expect(commit("85%", parse: { _ in nil }) == .invalid)
    }

    @Test func customParseIsNotCalledForEmptyInput() {
        #expect(commit("  ", parse: { _ in 50 }) == .revert)
    }
}

// MARK: - STColorWellHex

@Suite("Controls: STColorWellHex")
struct ControlsColorHexTests {
    @Test func parsesHexWithAndWithoutHash() throws {
        let gold = try #require(STColorWellHex.components(from: "#C89A3A"))
        #expect(gold.red == 200.0 / 255)
        #expect(gold.green == 154.0 / 255)
        #expect(gold.blue == 58.0 / 255)
        #expect(STColorWellHex.components(from: "c89a3a")?.red == 200.0 / 255)
    }

    @Test func rejectsMalformedHex() {
        for bad in ["", "#", "#C89A3", "#C89A3A0", "#GGGGGG", "##C89A3A", "C89 A3A", "#+89A3A", "#C89A3A00"] {
            #expect(STColorWellHex.components(from: bad) == nil, "\(bad) should be rejected")
        }
    }

    @Test func formatsUppercaseOpaqueHex() {
        #expect(STColorWellHex.hex(red: 0, green: 0, blue: 0) == "#000000")
        #expect(STColorWellHex.hex(red: 1, green: 1, blue: 1) == "#FFFFFF")
        #expect(STColorWellHex.hex(red: 200.0 / 255, green: 154.0 / 255, blue: 58.0 / 255) == "#C89A3A")
    }

    @Test func clampsOutOfGamutComponents() {
        #expect(STColorWellHex.hex(red: -0.2, green: 1.4, blue: .nan) == "#00FF00")
    }

    @Test func normalizesHex() {
        #expect(STColorWellHex.normalized("c89a3a") == "#C89A3A")
        #expect(STColorWellHex.normalized("nonsense") == nil)
    }

    @Test func everyPaletteColorRoundTripsThroughColor() {
        let palette = [STPalette.background, STPalette.surface, STPalette.raised, STPalette.ink,
                       STPalette.inkSecondary, STPalette.inkTertiary, STPalette.gold, STPalette.goldStroke,
                       STPalette.stroke, STPalette.rule, STPalette.danger, STPalette.success]
        for hex in palette {
            #expect(STColorWellHex.hex(from: STColorWellHex.color(from: hex)) == hex.uppercased())
        }
    }

    @Test func extremesRoundTripThroughColor() {
        for hex in ["#000000", "#FFFFFF", "#FF0000", "#00FF00", "#0000FF", "#010203", "#FEFDFC"] {
            #expect(STColorWellHex.hex(from: STColorWellHex.color(from: hex)) == hex)
        }
    }

    @Test func invalidHexShowsBlack() {
        #expect(STColorWellHex.hex(from: STColorWellHex.color(from: "bogus")) == "#000000")
    }
}

// MARK: - STSegmentedNavigation

@Suite("Controls: STSegmentedNavigation")
struct ControlsSegmentedNavigationTests {
    @Test func movesToNeighborsWithoutWrapping() {
        #expect(STSegmentedNavigation.index(from: 1, offset: 1, count: 4) == 2)
        #expect(STSegmentedNavigation.index(from: 1, offset: -1, count: 4) == 0)
        #expect(STSegmentedNavigation.index(from: 0, offset: -1, count: 4) == 0)
        #expect(STSegmentedNavigation.index(from: 3, offset: 1, count: 4) == 3)
    }

    @Test func missingSelectionJumpsToTheNearEnd() {
        #expect(STSegmentedNavigation.index(from: nil, offset: 1, count: 4) == 0)
        #expect(STSegmentedNavigation.index(from: nil, offset: -1, count: 4) == 3)
    }

    @Test func emptyOptionListHasNoTarget() {
        #expect(STSegmentedNavigation.index(from: nil, offset: 1, count: 0) == nil)
        #expect(STSegmentedNavigation.index(from: 0, offset: 1, count: 0) == nil)
    }

    @Test func optionIdentityFollowsItsValue() {
        let option = STSegmentedOption("plus", "Plus")
        #expect(option.id == "plus")
        #expect(option.title == "Plus")
    }
}

// MARK: - Render smoke tests

@MainActor
private func renderControl<V: View>(_ view: V, size: CGSize, theme: STTheme = STTheme()) -> NSBitmapImageRep? {
    let root = view
        .environment(\.stTheme, theme)
        .environment(\.stSoundPlayer, STSoundPlayer.silent)
        .frame(width: size.width, height: size.height)
        .background(STColor.background)
    let host = hostingView(root)
    host.frame = CGRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: .darkAqua)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}

private func distinctColorCount(_ rep: NSBitmapImageRep) -> Int {
    guard let data = rep.bitmapData else { return 0 }
    let bytesPerPixel = rep.bitsPerPixel / 8
    var seen = Set<UInt32>()
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            let offset = y * rep.bytesPerRow + x * bytesPerPixel
            var key: UInt32 = 0
            for channel in 0..<min(bytesPerPixel, 4) { key = (key << 8) | UInt32(data[offset + channel]) }
            seen.insert(key)
        }
    }
    return seen.count
}

private func sameBitmap(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
    guard let da = a.representation(using: .png, properties: [:]), let db = b.representation(using: .png, properties: [:]) else { return false }
    return da == db
}

@Suite("Controls: render smoke")
@MainActor
struct ControlsRenderTests {
    private func expectNonEmpty(_ rep: NSBitmapImageRep?, size: CGSize, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let rep else {
            Issue.record("no bitmap produced", sourceLocation: sourceLocation)
            return
        }
        #expect(rep.size == size, sourceLocation: sourceLocation)
        #expect(rep.pixelsWide >= Int(size.width) && rep.pixelsHigh >= Int(size.height), sourceLocation: sourceLocation)
        #expect(distinctColorCount(rep) > 1, "bitmap should contain more than the background", sourceLocation: sourceLocation)
    }

    @Test func switchRendersOnAndOffDifferently() throws {
        let size = CGSize(width: 80, height: 40)
        let off = renderControl(STSwitch(isOn: .constant(false), label: "Crosshair"), size: size)
        let on = renderControl(STSwitch(isOn: .constant(true), label: "Crosshair"), size: size)
        expectNonEmpty(off, size: size)
        expectNonEmpty(on, size: size)
        #expect(!sameBitmap(try #require(off), try #require(on)))
    }

    @Test func buttonKindsRenderDistinctly() throws {
        let size = CGSize(width: 160, height: 60)
        var reps: [NSBitmapImageRep] = []
        for kind in [STButtonStyle.Kind.primary, .secondary, .quiet] {
            let rep = renderControl(Button("Continue") {}.buttonStyle(STButtonStyle(kind)), size: size)
            expectNonEmpty(rep, size: size)
            reps.append(try #require(rep))
        }
        #expect(!sameBitmap(reps[0], reps[1]))
        #expect(!sameBitmap(reps[1], reps[2]))
    }

    @Test func disabledButtonIsDimmed() throws {
        let size = CGSize(width: 160, height: 60)
        let enabled = renderControl(Button("Continue") {}.buttonStyle(STButtonStyle(.primary)), size: size)
        let disabled = renderControl(Button("Continue") {}.buttonStyle(STButtonStyle(.primary)).disabled(true), size: size)
        expectNonEmpty(disabled, size: size)
        #expect(!sameBitmap(try #require(enabled), try #require(disabled)))
    }

    @Test func sliderRendersAtTwoValues() throws {
        let size = CGSize(width: 320, height: 64)
        let low = renderControl(STSlider(value: .constant(10), in: 0...100, step: 1, label: "Size"), size: size)
        let high = renderControl(STSlider(value: .constant(90), in: 0...100, step: 1, label: "Size"), size: size)
        expectNonEmpty(low, size: size)
        expectNonEmpty(high, size: size)
        #expect(!sameBitmap(try #require(low), try #require(high)))
    }

    @Test func sliderAcceptsCustomReadout() {
        let size = CGSize(width: 320, height: 64)
        let rep = renderControl(
            STSlider(value: .constant(85), in: 60...100, step: 5, label: "Opacity") { "\(Int($0)) percent" },
            size: size)
        expectNonEmpty(rep, size: size)
    }

    @Test func sliderRendersInEditMode() throws {
        let size = CGSize(width: 320, height: 64)
        let idle = renderControl(STSlider(value: .constant(40), in: 0...100, step: 1, label: "Size"), size: size)
        let editing = renderControl(STSlider(value: .constant(40), in: 0...100, step: 1, label: "Size").startingInEditMode(), size: size)
        expectNonEmpty(editing, size: size)
        #expect(!sameBitmap(try #require(idle), try #require(editing)))
    }

    @Test func sliderEditModeRendersUnderReducedMotion() {
        let size = CGSize(width: 320, height: 64)
        let theme = STTheme(motionMode: .reduced, increaseContrast: true)
        let rep = renderControl(STSlider(value: .constant(40), in: 0...100, label: "Size").startingInEditMode(), size: size, theme: theme)
        expectNonEmpty(rep, size: size)
    }

    @Test func segmentedRendersWithEachSelection() throws {
        let size = CGSize(width: 360, height: 40)
        let options = [STSegmentedOption("plus", "Plus"), STSegmentedOption("dot", "Dot"), STSegmentedOption("x", "X")]
        let first = renderControl(STSegmented(selection: .constant("plus"), options: options), size: size)
        let last = renderControl(STSegmented(selection: .constant("x"), options: options), size: size)
        expectNonEmpty(first, size: size)
        expectNonEmpty(last, size: size)
        #expect(!sameBitmap(try #require(first), try #require(last)))
    }

    @Test func colorWellRenders() {
        let size = CGSize(width: 80, height: 40)
        expectNonEmpty(renderControl(STColorWell(hex: .constant("#C89A3A"), label: "Color"), size: size), size: size)
    }

    @Test func controlsRenderUnderReducedMotionAndIncreasedContrast() {
        let theme = STTheme(motionMode: .reduced, increaseContrast: true)
        let size = CGSize(width: 320, height: 64)
        expectNonEmpty(renderControl(STSlider(value: .constant(40), in: 0...100, label: "Size"), size: size, theme: theme), size: size)
        expectNonEmpty(renderControl(STSwitch(isOn: .constant(true), label: "On"), size: CGSize(width: 80, height: 40), theme: theme),
                       size: CGSize(width: 80, height: 40))
    }
}
