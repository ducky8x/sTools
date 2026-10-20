import CoreGraphics
import Testing
@testable import KeyRebinder

@Suite struct BoardGeometryTests {
    let full = KeyboardLayout(shape: .ansi, formFactor: .fullSize)
    let laptop = KeyboardLayout(shape: .ansi, formFactor: .laptop)

    @Test func aWideWindowPutsTheMouseBesideAtAComfortableSize() {
        let geometry = BoardGeometry(layout: full, width: 1200)
        #expect(geometry.mouseBesideKeyboard)
        #expect(geometry.unit >= BoardGeometry.minimumUnit)
        #expect(abs(geometry.size.width - 1200) < 0.5)
    }

    @Test func keysNeverShrinkBelowTheMinimum() {
        let geometry = BoardGeometry(layout: full, width: 600)
        #expect(geometry.unit == BoardGeometry.minimumUnit)
        #expect(geometry.size.width > 600)
        #expect(geometry.mouseBesideKeyboard)
    }

    @Test func theMouseGoesUnderneathWhenOnlyTheKeyboardFits() {
        let geometry = BoardGeometry(layout: laptop, width: 620)
        #expect(!geometry.mouseBesideKeyboard)
        #expect(geometry.unit >= BoardGeometry.minimumUnit)
        #expect(geometry.size.width <= 620.5)
    }

    @Test func keysStopGrowingAtTheMaximum() {
        #expect(BoardGeometry(layout: laptop, width: 4000).unit == BoardGeometry.maximumUnit)
    }

    @Test func thePreviewAlwaysFitsItsWidth() {
        let preview = BoardGeometry.preview(layout: full, width: 300)
        #expect(abs(preview.size.width - 300) < 0.5)
    }
}
