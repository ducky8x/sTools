import AppKit
import SwiftUI
import Testing
@testable import STDesign

// A menu's label is as wide as its title. `widest` caps it for a menu on a crowded row, as the Key Rebinder's profile menu
// is on the page's title row: a longer title is cut off in the button, on one line.

/// The text sizes Settings offers, 90% to 130% in steps of 5.
private let textSizes = [0.9, 0.95, 1.0, 1.05, 1.1, 1.15, 1.2, 1.25, 1.3]

@MainActor
@Suite("Menu label")
struct MenuLabelTests {
    private static let cap: CGFloat = 120

    private func size(_ label: STMenuLabel, textScale: Double) -> CGSize {
        hostingView(AnyView(label.environment(\.stTheme, STTheme(textScale: textScale)).fixedSize())).fittingSize
    }

    @Test(arguments: textSizes)
    func aCapLeavesATitleThatFitsWhole(textScale: Double) {
        let limit = (Self.cap * textScale).rounded(.up)
        let free = size(STMenuLabel("Default profile"), textScale: textScale)
        let capped = size(STMenuLabel("Default profile", widest: Self.cap), textScale: textScale)
        #expect(free.width <= limit, "Default profile is \(free.width) pt wide at \(textScale)x, and the cap is \(limit) pt")
        #expect(capped == free, "capped \(capped), free \(free)")
    }

    @Test(arguments: textSizes)
    func aCapCutsALongerTitleShortOnOneLine(textScale: Double) {
        let limit = (Self.cap * textScale).rounded(.up)
        let title = "Minecraft speedrun practice"
        let free = size(STMenuLabel(title), textScale: textScale)
        let capped = size(STMenuLabel(title, widest: Self.cap), textScale: textScale)
        #expect(free.width > limit + 20, "the title is not long enough to test the cap")
        #expect(abs(capped.width - limit) <= 1, "capped \(capped.width) pt wide at \(textScale)x, and the cap is \(limit) pt")
        // Given the width of the cap, the title is cut off on its one line and doesn't run onto a second.
        let squeezed = hostingView(AnyView(
            STMenuLabel(title, widest: Self.cap).environment(\.stTheme, STTheme(textScale: textScale)).frame(width: limit))).fittingSize
        #expect(squeezed.height == free.height, "squeezed to \(limit) pt it is \(squeezed.height) pt tall, and on one line \(free.height) pt")
    }
}
