import Foundation
import os
import Testing
@testable import STPlatform

/// `HandlerSlot` keeps the handler a capture source calls for every frame or sound buffer. A closure kept as a lock's
/// own state was wrapped in one more reabstraction thunk on each read, so each call cost more than the last and a
/// capture queue's thread died of a stack overflow after a few thousand frames.
@Suite struct HandlerSlotTests {
    @Test func callsTheHandlerItWasGiven() {
        let slot = HandlerSlot<Int>()
        let received = OSAllocatedUnfairLock(initialState: [Int]())
        slot.set { value in received.withLock { $0.append(value) } }
        slot(1)
        slot(2)
        #expect(received.withLock { $0 } == [1, 2])
    }

    @Test func callsNothingBeforeOneIsSetOrOnceItIsCleared() {
        let slot = HandlerSlot<Int>()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        slot(1)
        #expect(!slot.isSet)
        slot.set { _ in calls.withLock { $0 += 1 } }
        #expect(slot.isSet)
        #expect(slot.clear(), "clearing reports that a handler was set")
        #expect(!slot.clear(), "and that none was the second time")
        slot(2)
        #expect(!slot.isSet)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func aNewHandlerReplacesTheOldOne() {
        let slot = HandlerSlot<Int>()
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        slot.set { _ in calls.withLock { $0.append("old") } }
        slot.set { _ in calls.withLock { $0.append("new") } }
        slot(1)
        #expect(calls.withLock { $0 } == ["new"])
    }

    /// A camera at 60 fps calls its handler 3,600 times a minute, on its own dispatch queue. Fifty thousand calls on
    /// one such queue must neither crash nor slow down: the stack under the handler stays as deep as it was at the
    /// first call, and the last calls take about as long as the first.
    @Test func manyThousandsOfCallsOnADispatchQueueStayFlat() async {
        let slot = HandlerSlot<Int>()
        let depths = OSAllocatedUnfairLock(initialState: [Int: Int]())
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let total = 50_000
        slot.set { index in
            calls.withLock { $0 += 1 }
            if index == 1 || index == total {
                let depth = Thread.callStackSymbols.count
                depths.withLock { $0[index] = depth }
            }
        }
        let queue = DispatchQueue(label: "sTools.test.handler-slot", qos: .userInteractive)
        let (first, last) = await withCheckedContinuation { (continuation: CheckedContinuation<(Duration, Duration), Never>) in
            queue.async {
                let clock = ContinuousClock()
                /// The quickest of five runs of 200 calls, so a pause from the rest of the suite doesn't count.
                func quickestBatch() -> Duration {
                    (0..<5).map { _ in clock.measure { for _ in 0..<200 { slot(0) } } }.min()!
                }
                slot(1)
                let first = quickestBatch()
                for index in 2..<total { slot(index) }
                let last = quickestBatch()
                slot(total)
                slot.clear()
                continuation.resume(returning: (first, last))
            }
        }
        #expect(calls.withLock { $0 } == total + 2_000)
        let firstDepth = depths.withLock { $0[1] }
        let lastDepth = depths.withLock { $0[total] }
        #expect(firstDepth != nil && firstDepth == lastDepth, "the stack under the handler grew from \(String(describing: firstDepth)) to \(String(describing: lastDepth)) frames")
        #expect(last < first * 20 + .milliseconds(2), "200 calls took \(first) at first and \(last) after \(total)")
    }
}
