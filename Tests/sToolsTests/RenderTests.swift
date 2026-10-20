import AppKit
import SwiftUI
import STDesign
import Testing
@testable import sTools

@MainActor
@Suite("Render smoke")
struct RenderTests {
    private let windowSize = CGSize(width: 760, height: 560)

    private func window(_ harness: Harness) -> some View {
        RootView(model: harness.model)
    }

    private func check(_ rep: NSBitmapImageRep, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(distinctColors(in: rep) > 20, sourceLocation: sourceLocation)
        #expect(pixel(in: rep, x: 700, y: 10) == [0x0B, 0x0A, 0x09], sourceLocation: sourceLocation)
    }

    @Test func homeRenders() {
        let harness = Harness(usesRealControllers: true)
        check(renderBitmap(window(harness), size: windowSize))
    }

    @Test func settingsRenders() {
        let harness = Harness(usesRealControllers: true)
        harness.model.navigate(to: .settings)
        check(renderBitmap(window(harness), size: windowSize))
    }

    @Test(arguments: ToolID.allCases)
    func everyToolPageRenders(tool: ToolID) {
        let harness = Harness(usesRealControllers: true)
        harness.model.navigate(to: .tool(tool))
        check(renderBitmap(window(harness), size: windowSize))
    }

    @Test func toolPageWithoutAccessibilityRenders() {
        let harness = Harness(accessibility: .denied, usesRealControllers: true)
        harness.model.navigate(to: .tool(.crosshair))
        check(renderBitmap(window(harness), size: windowSize))
    }

    @Test func sidebarRenders() {
        let harness = Harness(usesRealControllers: true)
        let rep = renderBitmap(
            SidebarView(model: harness.model).environment(\.stTheme, harness.model.theme),
            size: CGSize(width: 236, height: 560))
        #expect(distinctColors(in: rep) > 20)
    }

    @Test func pageAreaRendersEveryRoute() {
        let harness = Harness(usesRealControllers: true)
        for route in [Route.home, .settings] + ToolID.allCases.map(Route.tool) {
            harness.model.navigate(to: route)
            let rep = renderBitmap(PageArea(model: harness.model).environment(\.stTheme, harness.model.theme),
                                   size: CGSize(width: 520, height: 560))
            #expect(distinctColors(in: rep) > 5)
        }
    }
}
