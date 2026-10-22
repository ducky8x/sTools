import Foundation
import os
import Testing
import STPlatform

/// Collects what a feed hands its listener, from any thread.
private final class Received: Sendable {
    private let buffers = OSAllocatedUnfairLock<[InProcessAudioBuffer]>(initialState: [])
    var all: [InProcessAudioBuffer] { buffers.withLock { $0 } }
    func add(_ buffer: InProcessAudioBuffer) { buffers.withLock { $0.append(buffer) } }
}

private func buffer(_ value: Float, hostTime: UInt64 = 1) -> InProcessAudioBuffer {
    InProcessAudioBuffer(samples: [value, value, value, value], sampleRate: 48_000, channelCount: 2, hostTime: hostTime)
}

@Suite("In-process audio")
struct InProcessAudioTests {
    @Test func aFeedIsMadeOnFirstUseAndKept() {
        let audio = InProcessAudio()
        #expect(audio.feeds.isEmpty)
        let alarm = audio.feed(named: "Timer alarm")
        let again = audio.feed(named: "Timer alarm")
        let other = audio.feed(named: "Other")
        #expect(alarm === again)
        #expect(audio.feeds.map(\.name) == ["Timer alarm", "Other"])
        #expect(audio.feeds.first === alarm)
        #expect(other !== alarm)
    }

    @Test func separateSetsShareNothing() {
        let one = InProcessAudio(), two = InProcessAudio()
        one.feed(named: "Timer alarm").wantsRecording = true
        #expect(!two.feed(named: "Timer alarm").wantsRecording)
        #expect(InProcessAudio.shared !== one)
    }

    @Test func aNewFeedIsSilentAndUnwanted() {
        let feed = InProcessAudio().feed(named: "Timer alarm")
        #expect(!feed.wantsRecording)
        #expect(!feed.hasListeners)
        feed.publish(buffer(0.5))
        feed.wantsRecording = true
        #expect(feed.wantsRecording)
        feed.wantsRecording = false
        #expect(!feed.wantsRecording)
    }

    @Test func publishingReachesEveryListenerUntilItIsRemoved() {
        let feed = InProcessAudio().feed(named: "Timer alarm")
        let first = Received(), second = Received()
        let one = feed.addListener { first.add($0) }
        let two = feed.addListener { second.add($0) }
        #expect(feed.hasListeners)

        feed.publish(buffer(0.25, hostTime: 10))
        feed.removeListener(one)
        feed.publish(buffer(0.5, hostTime: 20))
        feed.removeListener(two)
        feed.publish(buffer(0.75, hostTime: 30))

        #expect(first.all == [buffer(0.25, hostTime: 10)])
        #expect(second.all == [buffer(0.25, hostTime: 10), buffer(0.5, hostTime: 20)])
        #expect(!feed.hasListeners)
    }

    @Test func aBufferKeepsItsFormatAndHostTime() {
        let rendered = InProcessAudioBuffer(samples: [0.1, 0.2, 0.3], sampleRate: 44_100, channelCount: 1, hostTime: 123_456)
        #expect(rendered.frameCount == 3)
        #expect(rendered.sampleRate == 44_100)
        #expect(rendered.hostTime == 123_456)
        #expect(InProcessAudioBuffer(samples: [1], sampleRate: 48_000, channelCount: 0, hostTime: 0).frameCount == 0)
    }

    /// Audio threads publish while a recording adds and removes its listener.
    @Test func publishingFromManyThreadsLosesNothing() {
        let feed = InProcessAudio().feed(named: "Timer alarm")
        let received = Received()
        let token = feed.addListener { received.add($0) }
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            feed.publish(buffer(0, hostTime: UInt64(index)))
            if index % 10 == 0 {
                let extra = feed.addListener { _ in }
                feed.removeListener(extra)
            }
        }
        feed.removeListener(token)
        #expect(received.all.count == 200)
        #expect(Set(received.all.map(\.hostTime)) == Set((0..<200).map(UInt64.init)))
    }
}
