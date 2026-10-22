import CoreMedia
import Foundation
import ScreenCaptureKit
import Testing
@testable import ScreenRecording

/// A minimized window's stream, as ScreenCaptureKit reports it: suspended while the window is in the Dock, and frames
/// again once it's restored, which has no status of its own. These tests hand the capture frame statuses by hand and
/// never start a stream, so nothing is captured and no permission is asked for.
@Suite("Screen capture's minimized windows")
struct MinimizedWindowTests {
    private func frame() -> VideoFrame {
        VideoFrame(pixelBuffer: WriterFixture.makeFrame(index: 0, size: PixelSize(width: 8, height: 8)), hostTime: .zero)
    }

    /// What the capture sends on, in words.
    private func sent(_ events: [VideoCaptureEvent]) -> [String] {
        events.map { event in
            switch event {
            case .frame: "frame"
            case .minimized(let minimized): "minimized(\(minimized))"
            case .ended(let reason): "ended(\(reason))"
            }
        }
    }

    /// Minimized once, the window comes back with its next frame: the capture says it was restored before that frame,
    /// so "Show nothing" doesn't leave its place blank for the rest of the recording.
    @Test func aRestoredWindowSaysSoWithItsNextFrame() {
        let capture = ScreenCapture(target: .window(1), showsCursor: false)
        #expect(sent(capture.events(for: .complete, frame: frame())) == ["frame"])
        #expect(sent(capture.events(for: .suspended, frame: nil)) == ["minimized(true)"])
        #expect(sent(capture.events(for: .complete, frame: frame())) == ["minimized(false)", "frame"])
        #expect(sent(capture.events(for: .complete, frame: frame())) == ["frame"])
    }

    /// Each change is sent once: a stream that stays suspended, or a window that was never minimized, sends nothing
    /// more.
    @Test func eachChangeIsSentOnce() {
        let capture = ScreenCapture(target: .window(1), showsCursor: false)
        #expect(sent(capture.events(for: .suspended, frame: nil)) == ["minimized(true)"])
        #expect(sent(capture.events(for: .suspended, frame: nil)).isEmpty)
        #expect(sent(capture.events(for: .idle, frame: nil)).isEmpty)
        #expect(sent(capture.events(for: .blank, frame: nil)).isEmpty)
        #expect(sent(capture.events(for: .stopped, frame: nil)).isEmpty)
        #expect(sent(capture.events(for: .complete, frame: frame())) == ["minimized(false)", "frame"])
    }

    /// A stream that starts its frames again (`started`) is running the window's picture again too.
    @Test func aStreamThatStartsAgainIsRestored() {
        let capture = ScreenCapture(target: .window(1), showsCursor: false)
        #expect(sent(capture.events(for: .suspended, frame: nil)) == ["minimized(true)"])
        #expect(sent(capture.events(for: .started, frame: nil)) == ["minimized(false)"])
        #expect(sent(capture.events(for: .suspended, frame: nil)) == ["minimized(true)"])
    }

    /// End to end with "Show nothing": minimized, the window's place empties; restored, its new frame shows again.
    @Test func showNothingShowsTheWindowAgainOnceRestored() async throws {
        let id = UUID()
        let capture = ScreenCapture(target: .window(1), showsCursor: false)
        let window = FakeVideoCapture()
        let rig = CaptureRig(video: [.source(id): window], audio: [:], minimizedShowsNothing: true)
        await rig.start()
        let deliver: ([VideoCaptureEvent]) -> Void = { events in events.forEach(window.push) }
        deliver(capture.events(for: .complete, frame: frame()))
        #expect(rig.hub.snapshot().frames[.source(id)] != nil)
        deliver(capture.events(for: .suspended, frame: nil))
        #expect(rig.hub.snapshot().frames[.source(id)] == nil)
        deliver(capture.events(for: .complete, frame: frame()))
        #expect(rig.hub.snapshot().frames[.source(id)] != nil)
        await rig.stop()
    }
}
