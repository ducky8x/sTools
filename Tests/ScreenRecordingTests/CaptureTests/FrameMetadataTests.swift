import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing
@testable import ScreenRecording

/// Frame metadata as ScreenCaptureKit attaches it, built by hand: these tests never start a stream, so nothing is
/// captured and no permission is asked for.
@Suite struct FrameMetadataTests {
    @Test func theMetadataIsReadFromTheFrameInfo() {
        let info: [SCStreamFrameInfo: Any] = [
            .contentRect: CGRect(x: 0, y: 60, width: 800, height: 480).dictionaryRepresentation,
            .scaleFactor: NSNumber(value: 2.0),
            .contentScale: NSNumber(value: 0.8),
        ]
        #expect(FrameMetadata(info) == FrameMetadata(contentRect: CGRect(x: 0, y: 60, width: 800, height: 480), scaleFactor: 2, contentScale: 0.8))
        #expect(FrameMetadata([:]) == FrameMetadata())
        #expect(FrameMetadata([.contentRect: "not a rect", .scaleFactor: "two"]) == FrameMetadata())
    }

    /// An 800 x 600 pt window on a 2x display, captured at its own 1600 x 1200 pixels: the content fills the frame.
    @Test func aWindowAtItsOwnSizeFillsTheFrame() {
        let metadata = FrameMetadata(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), scaleFactor: 2, contentScale: 1)
        let buffer = PixelSize(width: 1600, height: 1200)
        #expect(metadata.contentRect(in: buffer) == PixelRect(x: 0, y: 0, width: 1600, height: 1200))
        #expect(metadata.streamSize(for: buffer) == nil)
    }

    /// The window is widened to 1000 x 600 pt (2000 x 1200 pixels) past its 1600 x 1200 stream: ScreenCaptureKit
    /// fits it at 0.8, letterboxed. The crop is the fitted content; the stream is asked to run at the window's size.
    @Test func aWindowResizedPastItsStreamCropsToItsContentAndTheStreamFollows() {
        let metadata = FrameMetadata(contentRect: CGRect(x: 0, y: 60, width: 800, height: 480), scaleFactor: 2, contentScale: 0.8)
        let buffer = PixelSize(width: 1600, height: 1200)
        #expect(metadata.contentRect(in: buffer) == PixelRect(x: 0, y: 120, width: 1600, height: 960))
        #expect(metadata.streamSize(for: buffer) == PixelSize(width: 2000, height: 1200))
        // Once the stream runs at that size, the content fills it and nothing more is asked.
        let after = FrameMetadata(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600), scaleFactor: 2, contentScale: 1)
        #expect(after.contentRect(in: PixelSize(width: 2000, height: 1200)) == PixelRect(x: 0, y: 0, width: 2000, height: 1200))
        #expect(after.streamSize(for: PixelSize(width: 2000, height: 1200)) == nil)
    }

    /// The window's display goes from 1x to 2x mid-recording: the stream still runs at the old 800 x 600 pixels, and
    /// the window, now 1600 x 1200 pixels, is fitted at 0.5. It still fills the frame; the stream doubles.
    @Test func aDisplayGoingFrom1xTo2xKeepsTheWholeWindow() {
        let metadata = FrameMetadata(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), scaleFactor: 2, contentScale: 0.5)
        let buffer = PixelSize(width: 800, height: 600)
        #expect(metadata.contentRect(in: buffer) == PixelRect(x: 0, y: 0, width: 800, height: 600))
        #expect(metadata.streamSize(for: buffer) == PixelSize(width: 1600, height: 1200))
    }

    /// From 2x to 1x: the window is 800 x 600 pixels in a 1600 x 1200 stream, unscaled, in its top-left corner.
    /// Only that corner is shown (not the empty rest), and the stream shrinks to fit it.
    @Test func aDisplayGoingFrom2xTo1xShowsOnlyTheWindow() {
        let metadata = FrameMetadata(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), scaleFactor: 1, contentScale: 1)
        let buffer = PixelSize(width: 1600, height: 1200)
        #expect(metadata.contentRect(in: buffer) == PixelRect(x: 0, y: 0, width: 800, height: 600))
        #expect(metadata.streamSize(for: buffer) == PixelSize(width: 800, height: 600))
        // Had it been scaled up to fill instead (content scale 2), it fills the frame and the stream still shrinks.
        let scaledUp = FrameMetadata(contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1200), scaleFactor: 1, contentScale: 2)
        #expect(scaledUp.contentRect(in: buffer) == PixelRect(x: 0, y: 0, width: 1600, height: 1200))
        #expect(scaledUp.streamSize(for: buffer) == PixelSize(width: 800, height: 600))
    }

    /// Without a scale factor (reported on mixed Retina and non-Retina setups) the old code assumed 1 and showed only
    /// the top-left quarter of a 2x window; the scale now comes from the frame it fills.
    @Test func aMissingScaleFactorComesFromTheFrame() {
        let buffer = PixelSize(width: 1600, height: 1200)
        let filling = FrameMetadata(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(filling.contentRect(in: buffer) == PixelRect(x: 0, y: 0, width: 1600, height: 1200))
        let letterboxed = FrameMetadata(contentRect: CGRect(x: 0, y: 60, width: 800, height: 480), contentScale: 0.8)
        #expect(letterboxed.contentRect(in: buffer) == PixelRect(x: 0, y: 120, width: 1600, height: 960))
        #expect(FrameMetadata(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), scaleFactor: .nan).contentRect(in: buffer)
                == PixelRect(x: 0, y: 0, width: 1600, height: 1200))
    }

    @Test func theContentRectStaysInsideTheFrame() {
        let buffer = PixelSize(width: 1600, height: 1200)
        let past = FrameMetadata(contentRect: CGRect(x: -10, y: 0, width: 900, height: 700), scaleFactor: 2, contentScale: 1)
        #expect(past.contentRect(in: buffer) == PixelRect(x: 0, y: 0, width: 1600, height: 1200))
        #expect(FrameMetadata().contentRect(in: buffer) == nil)
        #expect(FrameMetadata(contentRect: .zero, scaleFactor: 2).contentRect(in: buffer) == nil)
        #expect(FrameMetadata(contentRect: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10), scaleFactor: 2).contentRect(in: buffer) == nil)
        #expect(FrameMetadata(contentRect: CGRect(x: 900, y: 0, width: 100, height: 100), scaleFactor: 2).contentRect(in: buffer) == nil)
        // A stream is never asked to grow past the largest canvas side, and keeps its shape.
        let huge = FrameMetadata(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), scaleFactor: 2, contentScale: 0.05)
        #expect(huge.streamSize(for: buffer) == PixelSize(width: 16384, height: 12288))
    }
}
