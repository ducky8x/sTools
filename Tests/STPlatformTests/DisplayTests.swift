import AppKit
import CoreGraphics
import Observation
import Synchronization
import Testing

@testable import STPlatform

/// False in sessions without an attached display (for example a bare CI runner), where
/// window-server tests cannot run. Counts sleeping displays, which the active list leaves out:
/// the window server still takes windows while they sleep.
let hasWindowServerDisplay: Bool = {
    var count: UInt32 = 0
    return CGGetOnlineDisplayList(0, nil, &count) == .success && count > 0
}()

/// Builds a display from Core Graphics bounds, deriving the AppKit frame from the primary height.
private func makeDisplay(
    _ id: UInt32,
    cg bounds: CGRect,
    primaryHeight: CGFloat,
    scale: CGFloat = 2,
    isMain: Bool = false
) -> DisplayInfo {
    DisplayInfo(
        id: id,
        name: "Display \(id)",
        frame: DisplayGeometry.convertToAppKit(cgRect: bounds, primaryScreenHeight: primaryHeight),
        bounds: bounds,
        backingScale: scale,
        pixelSize: CGSize(width: bounds.width * scale, height: bounds.height * scale),
        isMain: isMain
    )
}

@Suite("DisplayGeometry")
struct DisplayGeometryTests {
    @Test func convertsTheMainDisplayFlippingTheYAxis() {
        let cg = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let appKit = DisplayGeometry.convertToAppKit(cgRect: cg, primaryScreenHeight: 982)
        #expect(appKit == CGRect(x: 0, y: 0, width: 1512, height: 982))
    }

    @Test func convertsAWindowNearTheTopOfTheMainDisplay() {
        let cg = CGRect(x: 100, y: 50, width: 400, height: 300)
        let appKit = DisplayGeometry.convertToAppKit(cgRect: cg, primaryScreenHeight: 1000)
        #expect(appKit == CGRect(x: 100, y: 650, width: 400, height: 300))
    }

    @Test func convertsRectsAboveAndBelowThePrimaryDisplay() {
        let above = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        #expect(
            DisplayGeometry.convertToAppKit(cgRect: above, primaryScreenHeight: 982)
                == CGRect(x: 0, y: 982, width: 1920, height: 1080))
        let below = CGRect(x: 0, y: 982, width: 1920, height: 1080)
        #expect(
            DisplayGeometry.convertToAppKit(cgRect: below, primaryScreenHeight: 982)
                == CGRect(x: 0, y: -1080, width: 1920, height: 1080))
    }

    @Test func sideBySideDisplaysPickTheOneContainingTheWindow() {
        let main = makeDisplay(1, cg: CGRect(x: 0, y: 0, width: 1920, height: 1080), primaryHeight: 1080, isMain: true)
        let right = makeDisplay(2, cg: CGRect(x: 1920, y: 0, width: 2560, height: 1440), primaryHeight: 1080)
        let displays = [main, right]
        #expect(DisplayGeometry.display(forCGFrame: CGRect(x: 100, y: 100, width: 800, height: 600), in: displays)?.id == 1)
        #expect(DisplayGeometry.display(forCGFrame: CGRect(x: 2000, y: 100, width: 800, height: 600), in: displays)?.id == 2)
    }

    @Test func stackedDisplaysPickTheOneContainingTheWindow() {
        let main = makeDisplay(1, cg: CGRect(x: 0, y: 0, width: 1920, height: 1080), primaryHeight: 1080, isMain: true)
        let above = makeDisplay(2, cg: CGRect(x: 0, y: -1080, width: 1920, height: 1080), primaryHeight: 1080)
        let displays = [main, above]
        #expect(DisplayGeometry.display(forCGFrame: CGRect(x: 10, y: -500, width: 400, height: 300), in: displays)?.id == 2)
        #expect(DisplayGeometry.display(forCGFrame: CGRect(x: 10, y: 500, width: 400, height: 300), in: displays)?.id == 1)
    }

    @Test func aDisplayLeftOfMainHasNegativeOrigins() {
        let main = makeDisplay(1, cg: CGRect(x: 0, y: 0, width: 1512, height: 982), primaryHeight: 982, isMain: true)
        let left = makeDisplay(2, cg: CGRect(x: -1920, y: -98, width: 1920, height: 1080), primaryHeight: 982, scale: 1)
        let displays = [main, left]
        #expect(left.frame.origin.x == -1920)
        #expect(DisplayGeometry.display(forCGFrame: CGRect(x: -1500, y: 0, width: 640, height: 480), in: displays)?.id == 2)
        #expect(DisplayGeometry.display(forCGFrame: CGRect(x: 200, y: 0, width: 640, height: 480), in: displays)?.id == 1)
    }

    @Test func aRetinaAndNonRetinaMixIsKeptApartByBounds() {
        let retina = makeDisplay(1, cg: CGRect(x: 0, y: 0, width: 1512, height: 982), primaryHeight: 982, scale: 2, isMain: true)
        let plain = makeDisplay(2, cg: CGRect(x: 1512, y: 0, width: 1920, height: 1080), primaryHeight: 982, scale: 1)
        let found = DisplayGeometry.display(forCGFrame: CGRect(x: 1600, y: 10, width: 300, height: 200), in: [retina, plain])
        #expect(found?.backingScale == 1)
        #expect(found?.pixelSize == CGSize(width: 1920, height: 1080))
    }

    @Test func aWindowStraddlingTwoDisplaysGoesToTheLargerShare() {
        let main = makeDisplay(1, cg: CGRect(x: 0, y: 0, width: 1920, height: 1080), primaryHeight: 1080, isMain: true)
        let right = makeDisplay(2, cg: CGRect(x: 1920, y: 0, width: 1920, height: 1080), primaryHeight: 1080)
        let mostlyRight = CGRect(x: 1800, y: 100, width: 800, height: 600)
        #expect(DisplayGeometry.display(forCGFrame: mostlyRight, in: [main, right])?.id == 2)
        let mostlyMain = CGRect(x: 1500, y: 100, width: 800, height: 600)
        #expect(DisplayGeometry.display(forCGFrame: mostlyMain, in: [main, right])?.id == 1)
    }

    @Test func anExactTieGoesToTheEarlierDisplay() {
        let main = makeDisplay(1, cg: CGRect(x: 0, y: 0, width: 1920, height: 1080), primaryHeight: 1080, isMain: true)
        let right = makeDisplay(2, cg: CGRect(x: 1920, y: 0, width: 1920, height: 1080), primaryHeight: 1080)
        let evenSplit = CGRect(x: 1720, y: 100, width: 400, height: 300)
        #expect(DisplayGeometry.display(forCGFrame: evenSplit, in: [main, right])?.id == 1)
        #expect(DisplayGeometry.display(forCGFrame: evenSplit, in: [right, main])?.id == 2)
    }

    @Test func aWindowOffAllDisplaysFindsNone() {
        let main = makeDisplay(1, cg: CGRect(x: 0, y: 0, width: 1920, height: 1080), primaryHeight: 1080, isMain: true)
        #expect(DisplayGeometry.display(forCGFrame: CGRect(x: 5000, y: 5000, width: 200, height: 200), in: [main]) == nil)
    }

    @Test func aWindowOnlyTouchingAnEdgeFindsNone() {
        let main = makeDisplay(1, cg: CGRect(x: 0, y: 0, width: 1920, height: 1080), primaryHeight: 1080, isMain: true)
        #expect(DisplayGeometry.display(forCGFrame: CGRect(x: 1920, y: 0, width: 200, height: 200), in: [main]) == nil)
    }

    @Test func noDisplaysFindsNone() {
        #expect(DisplayGeometry.display(forCGFrame: CGRect(x: 0, y: 0, width: 10, height: 10), in: []) == nil)
    }
}

/// A mutable display layout the directory under test reads from.
@MainActor
private final class Layout {
    var displays: [DisplayInfo]
    init(_ displays: [DisplayInfo]) { self.displays = displays }
}

@Suite("DisplayInfo and DisplayDirectory", .serialized)
@MainActor
struct DisplayDirectoryTests {
    private func synthetic(_ id: UInt32, isMain: Bool) -> DisplayInfo {
        makeDisplay(id, cg: CGRect(x: 0, y: 0, width: 100, height: 100), primaryHeight: 100, isMain: isMain)
    }

    @Test(.enabled(if: hasWindowServerDisplay))
    func infoFromEveryRealScreenMatchesCoreGraphics() throws {
        _ = NSApplication.shared
        let screens = NSScreen.screens
        #expect(!screens.isEmpty)
        for screen in screens {
            let info = try #require(DisplayInfo(screen: screen))
            #expect(info.id == (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value)
            #expect(info.frame == screen.frame)
            #expect(info.bounds == CGDisplayBounds(info.id))
            #expect(info.backingScale == screen.backingScaleFactor)
            #expect(info.pixelSize.width > 0 && info.pixelSize.height > 0)
            #expect(!info.name.isEmpty)
            #expect(info.isMain == (info.id == CGMainDisplayID()))
        }
    }

    @Test(.enabled(if: hasWindowServerDisplay))
    func convertingRealBoundsReproducesTheAppKitFrame() throws {
        _ = NSApplication.shared
        let directory = DisplayDirectory()
        let primary = try #require(directory.main)
        for display in directory.displays {
            let converted = DisplayGeometry.convertToAppKit(
                cgRect: display.bounds, primaryScreenHeight: primary.frame.height)
            #expect(converted == display.frame)
        }
    }

    @Test(.enabled(if: hasWindowServerDisplay))
    func realDirectoryHasExactlyOneMainDisplay() {
        _ = NSApplication.shared
        let directory = DisplayDirectory()
        #expect(directory.displays.filter(\.isMain).count == 1)
        #expect(directory.main?.id == CGMainDisplayID())
    }

    @Test func loadsDisplaysAtInit() {
        let directory = DisplayDirectory(screenProvider: { [synthetic(7, isMain: true)] })
        #expect(directory.displays.map(\.id) == [7])
        #expect(directory.main?.id == 7)
    }

    @Test func mainIsNilWithoutDisplays() {
        let directory = DisplayDirectory(screenProvider: { [] })
        #expect(directory.main == nil)
    }

    @Test func refreshReloadsFromTheProvider() {
        let layout = Layout([synthetic(1, isMain: true)])
        let directory = DisplayDirectory(screenProvider: { layout.displays })
        layout.displays.append(synthetic(2, isMain: false))
        directory.refresh()
        #expect(directory.displays.map(\.id) == [1, 2])
    }

    @Test func refreshesWhenScreenParametersChange() async {
        let layout = Layout([synthetic(1, isMain: true)])
        let directory = DisplayDirectory(screenProvider: { layout.displays })
        layout.displays = [synthetic(3, isMain: true), synthetic(4, isMain: false)]
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for _ in 0..<100 where directory.displays.map(\.id) != [3, 4] {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(directory.displays.map(\.id) == [3, 4])
    }

    @Test func observationReportsChangesToDisplays() {
        let layout = Layout([synthetic(1, isMain: true)])
        let directory = DisplayDirectory(screenProvider: { layout.displays })
        let changed = Mutex(false)
        withObservationTracking {
            _ = directory.displays
        } onChange: {
            changed.withLock { $0 = true }
        }
        layout.displays = []
        directory.refresh()
        #expect(changed.withLock { $0 })
    }
}
