import Foundation
import Testing
@testable import ScreenRecording

/// What a recording's first frame would otherwise wait for is readied ahead (spec 5.4.4): the movie writer with its
/// encoder, and Core Image on Metal. Nothing shows and nothing is left behind.
@Suite("Recording warm-up")
struct RecordingWarmUpTests {
    /// The throwaway writer runs in a folder of its own and leaves nothing there.
    @Test(arguments: [VideoCodec.h264, .hevc])
    func warmingTheEncoderLeavesNoFile(codec: VideoCodec) throws {
        let folder = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(RecordingWarmUp.startAndCancelWriter(codec: codec, in: folder))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    /// The encoder is warmed once per codec in a launch; later armings skip it.
    @Test func theEncoderIsWarmedOncePerCodec() {
        let warmed = RecordingWarmUp.Warmed()
        #expect(warmed.claim(.h264))
        #expect(!warmed.claim(.h264))
        #expect(warmed.claim(.hevc))
    }

    @Test func aWarmedCompositorDrawsAtTheOutputSize() throws {
        let compositor = try #require(RecordingWarmUp.compositor(outputSize: PixelSize(width: 1281, height: 721)))
        #expect(compositor.outputSize == PixelSize(width: 1280, height: 720))
        #expect(compositor.isPreparedForPassThrough)
    }

    /// A recording uses the warmed compositor when it's for its output size, and makes its own otherwise.
    @Test func aSessionTakesTheWarmedCompositorWhenItFits() throws {
        let canvas = PixelSize(width: 320, height: 180)
        var options = RecordingOptions()
        options.frameRate = .fps30
        let configuration = RecordingSession.Configuration(
            layout: RecordingLayout(), options: options, canvas: canvas, baseName: "warm",
            directory: FileManager.default.temporaryDirectory)
        let rig = CaptureRig(video: [:], audio: [:], minimizedShowsNothing: false)
        let fits = try #require(RecordingWarmUp.compositor(outputSize: configuration.outputSize))
        let other = try #require(RecordingWarmUp.compositor(outputSize: PixelSize(width: 640, height: 360)))
        #expect(try RecordingSession(configuration: configuration, rig: rig, compositor: fits).compositor === fits)
        #expect(try RecordingSession(configuration: configuration, rig: rig, compositor: other).compositor !== other)
        #expect(try RecordingSession(configuration: configuration, rig: rig).compositor.outputSize == configuration.outputSize)
    }
}
