import Foundation
import STPlatform

/// Carries Timer Overlay's alarm into sTools' own recordings as the *Timer alarm* track while "Alarm in sTools
/// recordings" is on (spec 5.4.1, 5.6.6; plan decision 3).
///
/// The alarm plays through its own audio engine, so its output can be tapped without catching sTools' UI sounds, as
/// a process tap on sTools would. While the setting is on, the bridge hands the alarm player a handler for what it
/// renders, which publishes each buffer to the *Timer alarm* feed, and the feed wants recording. The player installs
/// its tap only while that handler is set and something plays, so the tap exists only while the alarm sounds with
/// the setting on. Off, the handler is gone and recordings that start from then on have no *Timer alarm* track.
///
/// The controller makes the bridge, and so the feed, at launch, whether the tool is on or off: the key can switch the
/// tool on in the middle of a recording, and a recording that starts before the alarm still gets its track. The feed
/// is only a name and a flag, so it costs nothing while the alarm is silent.
@MainActor
public final class AlarmRecordingBridge {
    /// The feed's name, which is also the track's title.
    public static let feedName = "Timer alarm"

    public let feed: InProcessAudioFeed
    private let alarm: any AlarmPlaying

    /// "Alarm in sTools recordings".
    public var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            apply()
        }
    }

    public init(alarm: any AlarmPlaying, feed: InProcessAudioFeed, isOn: Bool) {
        self.alarm = alarm
        self.feed = feed
        self.isOn = isOn
        apply()
    }

    private func apply() {
        feed.wantsRecording = isOn
        alarm.onRenderedBuffer = isOn ? Self.forwarder(to: feed) : nil
    }

    /// The player's handler. It runs on the audio tap's thread.
    private nonisolated static func forwarder(to feed: InProcessAudioFeed) -> @Sendable (AlarmRenderedBuffer) -> Void {
        { buffer in
            feed.publish(InProcessAudioBuffer(
                samples: buffer.samples, sampleRate: buffer.sampleRate, channelCount: buffer.channelCount,
                hostTime: buffer.hostTime))
        }
    }
}
