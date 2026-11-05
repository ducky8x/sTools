import CoreGraphics
import Testing
@testable import sTools

/// After a real display change the window server moves windows that are on no display onto the main one; the guard then
/// orders out the test's windows that landed on a real display, and leaves those still parked far off alone.
@Suite("Test windows after a display change")
struct OffScreenGuardTests {
    @Test func onlyWindowsOnARealDisplayAreOrderedOut() {
        let displays = [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: -1147, y: 819, width: 1147, height: 745)]
        let windows: [(number: Int, bounds: CGRect)] = [
            (1, CGRect(x: -31_058, y: 32_522, width: 34, height: 34)),
            (2, CGRect(x: 0, y: 0, width: 320, height: 200)),
            (3, CGRect(x: -9000, y: 9000, width: 176, height: 118)),
            (4, CGRect(x: -1200, y: 900, width: 100, height: 100)),
        ]
        #expect(OffScreenGuard.windowsOnDisplays(windows, displays: displays) == [2, 4])
    }
}
