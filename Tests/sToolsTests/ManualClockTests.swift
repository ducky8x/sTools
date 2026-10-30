import Testing

/// The clock the HUD tests move by hand has to be right for them to mean anything.
@MainActor
@Suite("Manual clock")
struct ManualClockTests {
    @Test func aSleeperWakesWhenTheClockReachesItsDeadlineAndNotBefore() async throws {
        let clock = ManualClock()
        let sleeper = Task { try await clock.sleep(for: .seconds(5)) }
        #expect(await clock.waitForWakes(.seconds(5)))

        clock.advance(by: .seconds(4))
        #expect(clock.pendingWakes == [.seconds(5)], "a second short, still asleep")
        clock.advance(by: .seconds(1))
        #expect(clock.pendingWakes.isEmpty)
        try await sleeper.value
        #expect(clock.now.offset == .seconds(5))
    }

    @Test func oneAdvanceWakesEverySleeperThatIsDueAndLeavesTheRest() async throws {
        let clock = ManualClock()
        let first = Task { try await clock.sleep(for: .seconds(1)) }
        let second = Task { try await clock.sleep(for: .seconds(2)) }
        let third = Task { try await clock.sleep(for: .seconds(9)) }
        #expect(await clock.waitForWakes(.seconds(1), .seconds(2), .seconds(9)))

        clock.advance(by: .seconds(3))
        try await first.value
        try await second.value
        #expect(clock.pendingWakes == [.seconds(9)])
        third.cancel()
        _ = await third.result
    }

    @Test func cancellingASleeperEndsItAndLeavesNothingAsleep() async {
        let clock = ManualClock()
        let sleeper = Task { try await clock.sleep(for: .seconds(5)) }
        #expect(await clock.waitForWakes(.seconds(5)))

        sleeper.cancel()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(clock.pendingWakes.isEmpty)
    }

    @Test func aTaskCancelledBeforeItSleepsNeverParks() async {
        let clock = ManualClock()
        let sleeper = Task { try await clock.sleep(for: .seconds(5)) }
        sleeper.cancel()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(clock.pendingWakes.isEmpty)
    }

    @Test func aDeadlineThatHasPassedReturnsAtOnce() async throws {
        let clock = ManualClock()
        clock.advance(by: .seconds(3))
        try await clock.sleep(until: ManualClock.Instant(offset: .seconds(2)), tolerance: nil)
        try await clock.sleep(for: .zero)
        #expect(clock.pendingWakes.isEmpty)
    }
}
