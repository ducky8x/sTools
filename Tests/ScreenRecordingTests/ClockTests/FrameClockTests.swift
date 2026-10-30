import CoreMedia
import Foundation
import Testing
import os
@testable import ScreenRecording

@Suite struct FrameClockTests {
    private func make(fps: Int = 60, clock: ManualClock = ManualClock(), recorder: TickRecorder = TickRecorder())
        -> (FrameClock, ManualClock, ManualTickDriver, TickRecorder)
    {
        let driver = ManualTickDriver()
        let fc = FrameClock(framesPerSecond: fps, clock: clock, driver: driver, onTick: { recorder.record($0) })
        return (fc, clock, driver, recorder)
    }

    @Test func ticksLandOnExactSlots() {
        let (fc, clock, driver, rec) = make(fps: 60, clock: ManualClock(100))
        fc.start()
        for i in 0..<5 {
            clock.set(100 + Double(i) / 60 + 0.001)
            driver.fire()
        }
        #expect(rec.all.map(\.index) == [0, 1, 2, 3, 4])
        #expect(rec.all.map(\.time) == (0..<5).map { CMTime(value: Int64($0), timescale: 60) })
        #expect(rec.all.allSatisfy { $0.skippedSlots == 0 })
        #expect(CMTimeGetSeconds(rec.all[3].hostTime) == 100 + 3.0 / 60)
        #expect(driver.intervals == [1.0 / 60])
    }

    @Test func aSecondWakeInTheSameSlotDoesNothing() {
        let (fc, clock, driver, rec) = make(clock: ManualClock(0))
        fc.start()
        driver.fire()
        clock.set(0.004)
        driver.fire()
        driver.fire()
        #expect(rec.all.count == 1)
    }

    @Test func aLateWakeSkipsSlotsInsteadOfBursting() {
        let (fc, clock, driver, rec) = make(clock: ManualClock(0))
        fc.start()
        driver.fire()
        clock.set(5.5 / 60)
        driver.fire()
        clock.set(6.1 / 60)
        driver.fire()
        #expect(rec.all.map(\.index) == [0, 5, 6])
        #expect(rec.all.map(\.skippedSlots) == [0, 4, 0])
    }

    @Test func timestampsDoNotDriftUnderJitter() {
        let (fc, clock, driver, rec) = make(fps: 60, clock: ManualClock(0))
        fc.start()
        var seed: UInt64 = 42
        for n in 0..<20000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let jitter = Double(seed >> 40) / 16777216.0 * 0.8 / 60
            clock.set(Double(n) / 60 + jitter)
            driver.fire()
        }
        let ticks = rec.all
        let consecutive = zip(ticks, ticks.dropFirst()).allSatisfy { $1.index == $0.index + 1 }
        let noSkips = ticks.allSatisfy { $0.skippedSlots == 0 }
        let lastTime = ticks.last?.time
        let count = ticks.count
        #expect(count == 20_000)
        #expect(consecutive)
        #expect(lastTime == CMTime(value: 19_999, timescale: 60))
        #expect(noSkips)
    }

    @Test func thirtyFramesPerSecond() {
        let (fc, clock, driver, rec) = make(fps: 30, clock: ManualClock(0))
        fc.start()
        driver.fire()
        clock.set(1.0 / 30)
        driver.fire()
        #expect(rec.all.map(\.time) == [CMTime(value: 0, timescale: 30), CMTime(value: 1, timescale: 30)])
        #expect(driver.intervals == [1.0 / 30])
    }

    @Test func explicitOriginIsHonored() {
        let (fc, clock, driver, rec) = make(clock: ManualClock(50))
        fc.start(origin: .seconds(49.5))
        driver.fire()
        #expect(rec.all.first?.index == 30)
        #expect(rec.all.first?.skippedSlots == 30)
        clock.set(50 + 1.0 / 60)
        driver.fire()
        #expect(rec.all.last?.index == 31)
    }

    @Test func stopHaltsTicksAndReportsTheLastIndex() {
        let (fc, clock, driver, rec) = make(clock: ManualClock(0))
        fc.start()
        driver.fire()
        clock.set(2.0 / 60)
        driver.fire()
        #expect(fc.stop() == 2)
        #expect(!driver.isRunning)
        clock.set(1)
        driver.fire()
        #expect(rec.all.count == 2)
        #expect(fc.stop() == 2)
        #expect(driver.stopCount == 1)
    }

    @Test func startTwiceKeepsTheFirstRun() {
        let (fc, _, driver, _) = make(clock: ManualClock(0))
        fc.start()
        fc.start()
        #expect(driver.intervals.count == 1)
    }

    @Test func stopWithoutTicksReturnsNil() {
        let (fc, _, _, _) = make()
        fc.start()
        #expect(fc.stop() == nil)
    }

    @Test func aClockThatStepsBackwardNeverProducesAnEarlierTick() {
        let (fc, clock, driver, rec) = make(clock: ManualClock(10))
        fc.start()
        driver.fire()
        clock.set(10 + 3.0 / 60)
        driver.fire()
        clock.set(10 + 1.0 / 60)
        driver.fire()
        clock.set(10 + 4.0 / 60)
        driver.fire()
        #expect(rec.all.map(\.index) == [0, 3, 4])
        #expect(rec.all.map(\.skippedSlots) == [0, 2, 0])
        #expect(zip(rec.all, rec.all.dropFirst()).allSatisfy { CMTimeCompare($0.time, $1.time) < 0 })
    }

    @Test func restartingBeginsANewRunAtIndexZero() {
        let (fc, clock, driver, rec) = make(clock: ManualClock(0))
        fc.start()
        driver.fire()
        clock.set(1.0 / 60)
        driver.fire()
        #expect(fc.stop() == 1)
        clock.set(20)
        fc.start()
        driver.fire()
        clock.set(20 + 1.0 / 60)
        driver.fire()
        #expect(rec.all.map(\.index) == [0, 1, 0, 1])
        #expect(CMTimeGetSeconds(rec.all[2].hostTime) == 20)
        #expect(driver.intervals.count == 2)
        #expect(driver.isRunning)
    }

    @Test func aWakeJustBeforeASlotBoundaryStillFiresThatSlot() {
        let (fc, clock, driver, rec) = make(clock: ManualClock(0))
        fc.start()
        driver.fire()
        clock.set(1.0 / 60 - 0.0001)
        driver.fire()
        #expect(rec.all.map(\.index) == [0, 1])
    }

    @Test func ticksFeedTheHubSoIdleSourcesAreReusedAndBurstsCoalesce() {
        let hub = FrameHub()
        let key = SourceKey.base
        let clock = ManualClock(0)
        let driver = ManualTickDriver()
        let seen = TickRecorder()
        let usedStamps = OSAllocatedUnfairLock(initialState: [(Double, Bool)]())
        let fc = FrameClock(framesPerSecond: 30, clock: clock, driver: driver) { tick in
            seen.record(tick)
            if let snap = hub.snapshot().frames[key] {
                usedStamps.withLock { $0.append((CMTimeGetSeconds(snap.frame.hostTime), snap.isNew)) }
            }
        }
        fc.start()
        hub.submit(ClockTestFrames.frame(at: 1), for: key)
        hub.submit(ClockTestFrames.frame(at: 2), for: key)
        hub.submit(ClockTestFrames.frame(at: 3), for: key)
        driver.fire()
        clock.set(1.0 / 30)
        driver.fire()
        clock.set(2.0 / 30)
        driver.fire()
        let used = usedStamps.withLock { $0 }
        #expect(used.map(\.0) == [3, 3, 3])
        #expect(used.map(\.1) == [true, false, false])
        #expect(seen.all.count == 3)
        #expect(hub.stats(for: key).coalesced == 2)
    }

    /// A real timer drives the clock: it keeps ticking, in order, never faster than its rate, and stops when told to.
    /// How many ticks a busy Mac lets a timer deliver in half a second is not the clock's to promise, so the test runs
    /// until fifteen ticks are in, however long that takes, and bounds the count from above by the slots that went by
    /// on the host clock, which no load can change.
    @Test func realTimerProducesIncreasingTicksNeverFasterThanTheRate() async throws {
        let queue = DispatchQueue(label: "test.frameclock")
        let rec = TickRecorder()
        let fc = FrameClock(framesPerSecond: 60, driver: DispatchTickDriver(queue: queue), onTick: { rec.record($0) })
        let began = HostMediaClock().now()
        fc.start()
        let kept = await waitUntil { rec.all.count >= 15 }
        fc.stop()
        let ended = HostMediaClock().now()
        queue.sync {}
        #expect(kept, "the timer kept ticking")
        let ticks = rec.all
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(ended, began))
        // Tick n is due n/60 s after the start, so none comes before its slot: the last index is within the elapsed time.
        #expect(Double(ticks.count) <= elapsed * 60 + 2, "\(ticks.count) ticks in \(elapsed) s")
        #expect(zip(ticks, ticks.dropFirst()).allSatisfy { $1.index > $0.index })
        let count = ticks.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(rec.all.count == count, "no tick after the stop")
    }
}
