import Foundation
import NBBOverlay
import Testing
@testable import sTools

// The app tests build the real NBB Overlay in `Harness(usesRealControllers: true)`. Left to its default, the overlay
// connects to port 52533, where a Ninjabrain Bot of whoever runs the tests may be open with its API on, and reads its
// result. Tests must never touch a real Ninjabrain Bot (or behave differently because one is open).

@MainActor
@Suite("The app tests' Ninjabrain Bot", .serialized)
struct HarnessIsolationTests {
    @Test func theHarnessNBBOverlayNeverReachesARealNinjabrainBot() async throws {
        let harness = Harness(usesRealControllers: true)
        let nbb = try #require(harness.model.controller(for: .nbbOverlay, as: NBBOverlayController.self))
        harness.model.setTool(.nbbOverlay, on: true)
        // It asks the harness's own Ninjabrain Bot, which is never there...
        #expect(await waitUntil(timeout: .seconds(10)) { harness.nbbSource.attempts >= 1 })
        // ...and so reads nothing, however long a connection to a Ninjabrain Bot on this Mac would have taken.
        let reached = await waitUntil(timeout: .seconds(1)) { nbb.isReachable || nbb.stronghold != nil }
        #expect(!reached, "the harness's NBB Overlay is reading a real Ninjabrain Bot")
        harness.model.setTool(.nbbOverlay, on: false)
    }
}
