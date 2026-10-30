import CoreGraphics
import Foundation
import STPlatform
import Testing
@testable import sTools

@Suite("MinecraftStatusText")
struct MinecraftStatusTextTests {
    private func display(_ id: UInt32, _ name: String) -> DisplayInfo {
        DisplayInfo(id: id, name: name, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                    bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), backingScale: 2,
                    pixelSize: CGSize(width: 3840, height: 2160), isMain: id == 1)
    }

    private func instance(pid: Int32, version: String?, launched: TimeInterval, displayID: UInt32? = 1) -> MinecraftInstance {
        let title = version.map { "Minecraft* \($0)" } ?? "Minecraft"
        let window = MinecraftWindow(windowNumber: UInt32(pid), processID: pid, title: title,
                                     frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        return MinecraftInstance(window: window, launchDate: Date(timeIntervalSince1970: launched), displayID: displayID)
    }

    private func text(_ instances: [MinecraftInstance], accessibility: Bool = true,
                      displays: [DisplayInfo]? = nil) -> String {
        let selection = InstanceSelector.select(from: instances)
        return MinecraftStatusText.make(
            active: selection.active, others: selection.others, conflict: selection.conflict,
            displays: displays ?? [display(1, "Studio Display")], accessibilityGranted: accessibility)
    }

    @Test func nothingRunning() {
        #expect(text([]) == "Minecraft isn\u{2019}t running.")
    }

    @Test func oneInstanceNamesVersionAndDisplay() {
        #expect(text([instance(pid: 10, version: "1.16.1", launched: 1)]) == "Minecraft 1.16.1 is open on Studio Display.")
    }

    @Test func oneInstanceOnAnUnknownDisplayOmitsTheDisplay() {
        #expect(text([instance(pid: 10, version: "1.16.1", launched: 1, displayID: nil)]) == "Minecraft 1.16.1 is open.")
        #expect(text([instance(pid: 10, version: "1.16.1", launched: 1, displayID: 9)]) == "Minecraft 1.16.1 is open.")
    }

    @Test func oneInstanceWithoutAVersionStillReads() {
        #expect(text([instance(pid: 10, version: nil, launched: 1)]) == "Minecraft is open on Studio Display.")
    }

    @Test func conflictBetweenEqualVersionsFollowsTheOneOpenedFirst() {
        let message = text([instance(pid: 10, version: "1.16.1", launched: 5), instance(pid: 11, version: "1.16.1", launched: 9)])
        #expect(message == "2 Minecraft windows are open. Following 1.16.1 (opened first).")
    }

    @Test func conflictPreferringTheMajorVersionSaysSo() {
        let message = text([instance(pid: 10, version: "1.20.4", launched: 1), instance(pid: 11, version: "1.16.1", launched: 9)])
        #expect(message == "2 Minecraft windows are open. Following 1.16.1 (the preferred version).")
    }

    @Test func conflictWithoutAPreferredVersionFollowsTheOneOpenedFirst() {
        let message = text([
            instance(pid: 10, version: "1.20.4", launched: 1),
            instance(pid: 11, version: "1.19.2", launched: 4),
            instance(pid: 12, version: "1.21", launched: 9),
        ])
        #expect(message == "3 Minecraft windows are open. Following 1.20.4 (opened first).")
    }

    @Test func conflictWithAnUnknownVersionStillReads() {
        let message = text([instance(pid: 10, version: nil, launched: 1), instance(pid: 11, version: nil, launched: 2)])
        #expect(message == "2 Minecraft windows are open. Following the one opened first.")
    }

    @Test func withoutAccessibilityNothingCanBeFound() {
        #expect(text([], accessibility: false) == "sTools can\u{2019}t look for Minecraft until Accessibility is allowed.")
    }

    @Test func conflictFlagMatchesTheLocator() {
        let selection = InstanceSelector.select(from: [instance(pid: 10, version: "1.16.1", launched: 1)])
        #expect(selection.conflict == .none)
        #expect(!MinecraftStatusText.isConflict(selection.conflict))
        let two = InstanceSelector.select(from: [instance(pid: 10, version: "1.16.1", launched: 1), instance(pid: 11, version: "1.16.1", launched: 2)])
        #expect(MinecraftStatusText.isConflict(two.conflict))
    }
}
