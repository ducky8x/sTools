import Foundation
import os
import STDesign
import STPlatform
import Testing
@testable import TimerOverlay

/// Collects what a feed hands its listener, from any thread.
private final class FeedBuffers: Sendable {
    private let buffers = OSAllocatedUnfairLock<[InProcessAudioBuffer]>(initialState: [])
    var all: [InProcessAudioBuffer] { buffers.withLock { $0 } }
    func add(_ buffer: InProcessAudioBuffer) { buffers.withLock { $0.append(buffer) } }
}

private let rendered = AlarmRenderedBuffer(samples: [0.25, -0.25, 0.5, -0.5], sampleRate: 44_100, channelCount: 2,
                                           hostTime: 987_654_321)

/// A controller with every seam faked and its own in-process feeds, so nothing reaches the app's (`TimerRig` uses the
/// shared ones and keeps the setting off).
@MainActor
private struct BridgeRig {
    let rig: TimerRig
    let alarm: TestAlarm
    let audio = InProcessAudio()
    let controller: TimerOverlayController

    init(alarmInRecordings: Bool) {
        rig = TimerRig()
        alarm = TestAlarm(scheduler: rig.scheduler)
        var settings = rig.services.settings.load(TimerOverlaySettings.self)
        settings.alarmInRecordings = alarmInRecordings
        rig.services.settings.save(settings)
        controller = TimerOverlayController(
            services: rig.services, theme: rig.theme, clock: rig.clock, scheduler: rig.scheduler,
            activity: rig.activity, wakeWatcher: rig.wakeWatcher, presenter: rig.presenter, guides: rig.guides,
            alarm: alarm, announcer: rig.announcer, inProcessAudio: audio)
    }

    var feed: InProcessAudioFeed { audio.feed(named: "Timer alarm") }
}

/// An engine that plays nothing and only holds the tap the player installs.
@MainActor
private final class TapEngine: AlarmAudioEngine {
    let soundFrameCount = 72_000
    let sampleRate = 48_000.0
    var onInterruption: (@MainActor () -> Void)?
    private(set) var tap: (@Sendable (AlarmRenderedBuffer) -> Void)?

    func play(_ items: [AlarmPlaybackItem], volume: Float, onItemPlayed: @escaping @MainActor (Int) -> Void) throws {}
    func installTap(_ handler: @escaping @Sendable (AlarmRenderedBuffer) -> Void) { tap = handler }
    func removeTap() { tap = nil }
    func stop() {}
}

@MainActor
private final class TapEngines: AlarmEngineMaking {
    private(set) var engines: [TapEngine] = []
    func makeEngine(for sound: URL) throws -> any AlarmAudioEngine {
        let engine = TapEngine()
        engines.append(engine)
        return engine
    }
}

@Suite("Alarm recording bridge") @MainActor
struct AlarmRecordingBridgeTests {
    /// With the live player: the tap exists only while the setting is on and the alarm plays, and what it renders
    /// reaches the feed.
    @Test func theLivePlayersTapExistsOnlyWhileOnAndPlaying() throws {
        let clock = TestClock()
        let engines = TapEngines()
        let player = AlarmPlayer(engines: engines, clock: clock, scheduler: TestScheduler(clock: clock))
        let feed = InProcessAudio().feed(named: AlarmRecordingBridge.feedName)
        let received = FeedBuffers()
        let token = feed.addListener { received.add($0) }
        defer { feed.removeListener(token); player.stop() }
        let bridge = AlarmRecordingBridge(alarm: player, feed: feed, isOn: true)
        #expect(engines.engines.isEmpty)

        let schedule = AlarmSchedule(soundLength: 1.5, settings: TimerOverlaySettings())
        player.ring(URL(fileURLWithPath: "/nonexistent/alarm.wav"), volume: 0.8, schedule: schedule,
                    onRing: { _ in }, onEnd: {})
        let engine = try #require(engines.engines.last)
        let tap = try #require(engine.tap)
        tap(rendered)
        #expect(received.all.map(\.hostTime) == [987_654_321])

        bridge.isOn = false
        #expect(engine.tap == nil)
        bridge.isOn = true
        #expect(engine.tap != nil)
        player.stop()
        #expect(engine.tap == nil)
    }

    @Test func offItLeavesTheAlarmOutOfRecordings() {
        let alarm = TestAlarm(scheduler: TestScheduler(clock: TestClock()))
        let feed = InProcessAudio().feed(named: AlarmRecordingBridge.feedName)
        let bridge = AlarmRecordingBridge(alarm: alarm, feed: feed, isOn: false)
        #expect(!bridge.isOn)
        #expect(!feed.wantsRecording)
        #expect(alarm.onRenderedBuffer == nil)
    }

    @Test func onItForwardsWhatTheAlarmRendersToTheFeed() throws {
        let alarm = TestAlarm(scheduler: TestScheduler(clock: TestClock()))
        let feed = InProcessAudio().feed(named: AlarmRecordingBridge.feedName)
        let received = FeedBuffers()
        let token = feed.addListener { received.add($0) }
        defer { feed.removeListener(token) }

        _ = AlarmRecordingBridge(alarm: alarm, feed: feed, isOn: true)
        #expect(feed.wantsRecording)
        let handler = try #require(alarm.onRenderedBuffer)
        handler(rendered)

        #expect(received.all == [InProcessAudioBuffer(samples: [0.25, -0.25, 0.5, -0.5], sampleRate: 44_100,
                                                      channelCount: 2, hostTime: 987_654_321)])
    }

    /// The tap's thread calls the handler, never the main actor.
    @Test func theHandlerRunsOffTheMainThread() async throws {
        let alarm = TestAlarm(scheduler: TestScheduler(clock: TestClock()))
        let feed = InProcessAudio().feed(named: AlarmRecordingBridge.feedName)
        let received = FeedBuffers()
        let token = feed.addListener { received.add($0) }
        defer { feed.removeListener(token) }
        _ = AlarmRecordingBridge(alarm: alarm, feed: feed, isOn: true)
        let handler = try #require(alarm.onRenderedBuffer)
        await Task.detached { handler(rendered) }.value
        #expect(received.all.count == 1)
    }

    @Test func turningItOffAndOnFollowsTheSetting() {
        let alarm = TestAlarm(scheduler: TestScheduler(clock: TestClock()))
        let feed = InProcessAudio().feed(named: AlarmRecordingBridge.feedName)
        let bridge = AlarmRecordingBridge(alarm: alarm, feed: feed, isOn: true)
        bridge.isOn = false
        #expect(!feed.wantsRecording)
        #expect(alarm.onRenderedBuffer == nil)
        bridge.isOn = true
        #expect(feed.wantsRecording)
        #expect(alarm.onRenderedBuffer != nil)
    }

    // MARK: The controller

    /// The feed is there from launch, with the tool off, so a recording that starts before the alarm gets its track.
    @Test func theControllerTakesTheTimerAlarmFeedAtLaunch() {
        let off = BridgeRig(alarmInRecordings: false)
        #expect(!off.controller.isEnabled)
        #expect(off.audio.feeds.map(\.name) == ["Timer alarm"])
        #expect(!off.feed.wantsRecording)
        #expect(off.alarm.onRenderedBuffer == nil)

        let on = BridgeRig(alarmInRecordings: true)
        #expect(!on.controller.isEnabled)
        #expect(on.audio.feeds.map(\.name) == ["Timer alarm"])
        #expect(on.feed.wantsRecording)
        #expect(on.alarm.onRenderedBuffer != nil)
    }

    /// The key can switch the tool on in the middle of a recording, so the flag follows the setting either way.
    @Test func theFeedsFlagFollowsTheSettingWhetherTheToolIsOnOrOff() {
        let bridge = BridgeRig(alarmInRecordings: false)
        bridge.controller.settings.alarmInRecordings = true
        #expect(bridge.feed.wantsRecording)
        #expect(bridge.alarm.onRenderedBuffer != nil)

        bridge.controller.setEnabled(true)
        #expect(bridge.feed.wantsRecording)
        bridge.controller.settings.alarmInRecordings = false
        #expect(!bridge.feed.wantsRecording)
        #expect(bridge.alarm.onRenderedBuffer == nil)

        bridge.controller.setEnabled(false)
        #expect(!bridge.feed.wantsRecording)
        bridge.controller.settings.alarmInRecordings = true
        #expect(bridge.feed.wantsRecording)

        bridge.controller.resetToDefault()
        #expect(!bridge.feed.wantsRecording)
        #expect(bridge.alarm.onRenderedBuffer == nil)
    }

    /// What the alarm renders while it rings reaches a recording's listener, with the setting on.
    @Test func aRingingAlarmReachesTheFeedWithTheSettingOn() throws {
        let bridge = BridgeRig(alarmInRecordings: true)
        let received = FeedBuffers()
        let token = bridge.feed.addListener { received.add($0) }
        defer { bridge.feed.removeListener(token) }
        bridge.controller.setEnabled(true)
        #expect(bridge.controller.start())
        for _ in 0..<10_000 where !bridge.alarm.isPlaying {
            guard bridge.rig.scheduler.fireNext() else { break }
        }
        #expect(bridge.alarm.isPlaying)
        let handler = try #require(bridge.alarm.onRenderedBuffer)
        handler(rendered)
        #expect(received.all.map(\.hostTime) == [987_654_321])
    }
}
