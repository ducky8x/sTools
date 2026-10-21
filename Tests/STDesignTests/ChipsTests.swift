import AppKit
import SwiftUI
import Testing
@testable import STDesign

// MARK: - Logic

@Suite("STChipsLogic")
struct ChipsLogicTests {
    @Test func toggledAddsAMissingValueAndKeepsTheOthers() {
        #expect(STChipsLogic.toggled("b", in: ["a", "c"]) == ["a", "b", "c"])
        #expect(STChipsLogic.toggled("a", in: []) == ["a"])
    }

    @Test func toggledRemovesAPresentValueAndKeepsTheOthers() {
        #expect(STChipsLogic.toggled("b", in: ["a", "b", "c"]) == ["a", "c"])
        #expect(STChipsLogic.toggled("a", in: ["a"]) == [])
    }
}

@Suite("STFlowLayoutMath")
struct FlowLayoutMathTests {
    @Test func placesItemsLeftToRightAndWrapsBeforeOneThatWouldOverflow() {
        let sizes = [CGSize(width: 40, height: 20), CGSize(width: 50, height: 24), CGSize(width: 30, height: 20)]
        let arrangement = STFlowLayoutMath.arrange(sizes, width: 100, spacing: 8)
        #expect(arrangement.origins == [CGPoint(x: 0, y: 0), CGPoint(x: 48, y: 0), CGPoint(x: 0, y: 32)])
        // The widest row (40 + 8 + 50) by two rows: the first as tall as its tallest chip, then the spacing.
        #expect(arrangement.size == CGSize(width: 98, height: 52))
    }

    @Test func anItemThatFitsExactlyStaysOnTheRow() {
        let sizes = [CGSize(width: 46, height: 20), CGSize(width: 46, height: 20)]
        let arrangement = STFlowLayoutMath.arrange(sizes, width: 100, spacing: 8)
        #expect(arrangement.origins == [CGPoint(x: 0, y: 0), CGPoint(x: 54, y: 0)])
        #expect(arrangement.size == CGSize(width: 100, height: 20))
    }

    @Test func anOverWideItemSitsAloneOnItsRow() {
        let sizes = [CGSize(width: 30, height: 20), CGSize(width: 150, height: 20), CGSize(width: 30, height: 20)]
        let arrangement = STFlowLayoutMath.arrange(sizes, width: 100, spacing: 8)
        #expect(arrangement.origins == [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 28), CGPoint(x: 0, y: 56)])
        #expect(arrangement.size == CGSize(width: 150, height: 76))

        let first = STFlowLayoutMath.arrange([CGSize(width: 150, height: 20), CGSize(width: 30, height: 20)], width: 100, spacing: 8)
        #expect(first.origins == [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 28)])
    }

    @Test func noItemsTakeNoSpace() {
        let arrangement = STFlowLayoutMath.arrange([], width: 100, spacing: 8)
        #expect(arrangement.origins.isEmpty)
        #expect(arrangement.size == .zero)
    }

    @Test func anUnboundedWidthKeepsOneRow() {
        let sizes = Array(repeating: CGSize(width: 60, height: 20), count: 5)
        let arrangement = STFlowLayoutMath.arrange(sizes, width: .infinity, spacing: 8)
        #expect(arrangement.origins.map(\.y) == [0, 0, 0, 0, 0])
        #expect(arrangement.size == CGSize(width: 5 * 60 + 4 * 8, height: 20))
    }
}

// MARK: - Render smoke (offscreen, no window, nothing scale-dependent)

@MainActor
private func render<V: View>(_ view: V, size: CGSize) -> Data? {
    let root = view
        .environment(\.stTheme, STTheme())
        .environment(\.stSoundPlayer, STSoundPlayer.silent)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(STColor.background)
    let host = NSHostingView(rootView: root)
    host.frame = CGRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: .darkAqua)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep.representation(using: .png, properties: [:])
}

private var actions: [STSegmentedOption<String>] {
    [STSegmentedOption("nbb", "NBB Overlay"), STSegmentedOption("backdrop", "Window Backdrop"),
     STSegmentedOption("crosshair", "Crosshair"), STSegmentedOption("recording", "Start/stop recording")]
}

@Suite("STChips rendering")
@MainActor
struct ChipsRenderTests {
    private let size = CGSize(width: 260, height: 90)

    @Test func aSelectedChipRendersDifferentlyFromNone() throws {
        let none = try #require(render(STChips(selection: .constant([]), options: actions, label: "Does"), size: size))
        let one = try #require(render(STChips(selection: .constant(["crosshair"]), options: actions, label: "Does"), size: size))
        let blank = try #require(render(Color.clear, size: size))
        #expect(none != blank)
        #expect(none != one)
    }

    @Test func disabledChipsAreDimmed() throws {
        let enabled = try #require(render(STChips(selection: .constant(["nbb"]), options: actions, label: "Does"), size: size))
        let disabled = try #require(render(STChips(selection: .constant(["nbb"]), options: actions, label: "Does").disabled(true), size: size))
        #expect(enabled != disabled)
    }
}

@Suite("STNoteLine rendering")
@MainActor
struct NoteLineRenderTests {
    private let size = CGSize(width: 320, height: 40)

    @Test func aCautionRendersDifferentlyFromANote() throws {
        let text = "Minecraft uses F3 for Debug screen."
        let note = try #require(render(STNoteLine(text, tone: .note), size: size))
        let caution = try #require(render(STNoteLine(text, tone: .caution), size: size))
        let blank = try #require(render(Color.clear, size: size))
        #expect(note != blank)
        #expect(note != caution)
    }
}
