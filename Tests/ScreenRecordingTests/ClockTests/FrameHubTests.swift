import CoreMedia
import Foundation
import Testing
@testable import ScreenRecording

@Suite struct FrameHubTests {
    private func stamp(_ frame: SnapshotFrame?) -> Double? {
        frame.map { CMTimeGetSeconds($0.frame.hostTime) }
    }

    @Test func anIdleSourceKeepsItsLatestFrame() {
        let hub = FrameHub()
        let key = SourceKey.source(UUID())
        hub.submit(ClockTestFrames.frame(at: 10), for: key)
        let first = hub.snapshot().frames[key]
        let second = hub.snapshot().frames[key]
        let third = hub.snapshot().frames[key]
        #expect(first?.isNew == true)
        #expect(second?.isNew == false)
        #expect(third?.isNew == false)
        #expect(stamp(third) == 10)
        #expect(hub.stats(for: key).reused == 2)
    }

    @Test func aBurstCoalescesToTheNewestFrame() {
        let hub = FrameHub()
        let key = SourceKey.base
        for i in 0..<5 { hub.submit(ClockTestFrames.frame(at: Double(i)), for: key) }
        let snap = hub.snapshot().frames[key]
        #expect(stamp(snap) == 4)
        #expect(snap?.isNew == true)
        let stats = hub.stats(for: key)
        #expect(stats.received == 5 && stats.coalesced == 4)
    }

    @Test func aFrameArrivingAfterATickIsNewAgain() {
        let hub = FrameHub()
        let key = SourceKey.base
        hub.submit(ClockTestFrames.frame(at: 1), for: key)
        _ = hub.snapshot()
        hub.submit(ClockTestFrames.frame(at: 2), for: key)
        let snap = hub.snapshot().frames[key]
        #expect(snap?.isNew == true)
        #expect(stamp(snap) == 2)
        #expect(hub.stats(for: key).coalesced == 0)
    }

    @Test func slotsAreIndependent() {
        let hub = FrameHub()
        let a = SourceKey.source(UUID()), b = SourceKey.source(UUID())
        hub.submit(ClockTestFrames.frame(at: 1), for: a)
        _ = hub.snapshot()
        hub.submit(ClockTestFrames.frame(at: 2), for: b)
        let snap = hub.snapshot()
        #expect(snap.frames[a]?.isNew == false)
        #expect(snap.frames[b]?.isNew == true)
    }

    @Test func clearEmptiesTheSlot() {
        let hub = FrameHub()
        let key = SourceKey.source(UUID())
        hub.submit(ClockTestFrames.frame(at: 1), for: key)
        hub.clear(key)
        #expect(hub.snapshot().frames[key] == nil)
        hub.submit(ClockTestFrames.frame(at: 2), for: key)
        #expect(hub.snapshot().frames[key] != nil)
    }

    @Test func hiddenSlotsKeepTheirFrameButAreOmitted() {
        let hub = FrameHub()
        let key = SourceKey.source(UUID())
        hub.submit(ClockTestFrames.frame(at: 1), for: key)
        hub.setHidden(true, for: key)
        #expect(hub.snapshot().frames[key] == nil)
        hub.setHidden(false, for: key)
        let snap = hub.snapshot().frames[key]
        #expect(snap != nil)
        #expect(snap?.isNew == true)
    }

    @Test func removeAllForgetsEverySlot() {
        let hub = FrameHub()
        hub.submit(ClockTestFrames.frame(at: 1), for: .base)
        hub.removeAll()
        #expect(hub.snapshot().frames.isEmpty)
        #expect(hub.stats(for: .base) == HubStats())
    }

    @Test func concurrentSubmitsAreSafe() async {
        let hub = FrameHub()
        let key = SourceKey.base
        let frame = ClockTestFrames.frame(at: 0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<250 { hub.submit(frame, for: key) }
                }
            }
            group.addTask { for _ in 0..<200 { _ = hub.snapshot() } }
        }
        #expect(hub.stats(for: key).received == 1000)
    }
}

@Suite struct FrameHubPeekTests {
    @Test func peekingLeavesFramesNew() {
        let hub = FrameHub()
        hub.submit(ClockTestFrames.frame(at: 1), for: .base)
        #expect(hub.peek()[.base] != nil)
        #expect(hub.snapshot().frames[.base]?.isNew == true)
        hub.setHidden(true, for: .base)
        #expect(hub.peek().isEmpty)
    }
}

/// A start waits for Minecraft's first frame, so the recording's first frame shows the game (spec 5.4.4), but never
/// for long.
///
/// The waits that must end early are given a timeout of a minute and checked against half of it: what ends them is a
/// frame, or the frames being let go of, which takes a moment however busy the Mac is, while a wait that ran to its
/// timeout would take the whole minute. Nothing here depends on how fast a moment is.
@Suite struct FrameHubFirstFrameTests {
    private static let timeout = Duration.seconds(60)
    private static let wayBeforeTheTimeout = Duration.seconds(30)

    @Test func aFrameAlreadyThereNeedsNoWait() async {
        let hub = FrameHub()
        hub.submit(ClockTestFrames.frame(at: 1), for: .base)
        let began = SuspendingClock.now
        #expect(await hub.waitForFrame(of: .base, timeout: Self.timeout))
        #expect(SuspendingClock.now - began < Self.wayBeforeTheTimeout)
    }

    @Test func theWaitEndsAsTheFirstFrameArrives() async {
        let hub = FrameHub()
        let began = SuspendingClock.now
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            hub.submit(ClockTestFrames.frame(at: 1), for: .source(UUID()))
            hub.submit(ClockTestFrames.frame(at: 2), for: .base)
        }
        #expect(await hub.waitForFrame(of: .base, timeout: Self.timeout))
        let waited = SuspendingClock.now - began
        #expect(waited >= .milliseconds(100))
        #expect(waited < Self.wayBeforeTheTimeout)
    }

    @Test func theWaitGivesUpAfterItsTimeout() async {
        let hub = FrameHub()
        let began = SuspendingClock.now
        #expect(!(await hub.waitForFrame(of: .base, timeout: .milliseconds(150))))
        #expect(SuspendingClock.now - began >= .milliseconds(150))
        // A frame after the wait is kept as any other.
        hub.submit(ClockTestFrames.frame(at: 1), for: .base)
        #expect(hub.peek()[.base] != nil)
    }

    @Test func lettingGoOfTheFramesEndsTheWait() async {
        let hub = FrameHub()
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            hub.removeAll()
        }
        let began = SuspendingClock.now
        #expect(!(await hub.waitForFrame(of: .base, timeout: Self.timeout)))
        #expect(SuspendingClock.now - began < Self.wayBeforeTheTimeout)
    }
}
