import CoreMedia
import CoreVideo
import Foundation
@testable import ScreenRecording

enum WriterFixture {
    static let size = PixelSize(width: 320, height: 180)

    static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sTools-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A BGRA frame whose content changes with `index`, so the encoder produces real data.
    static func makeFrame(index: Int, size: PixelSize = WriterFixture.size) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, size.width, size.height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let frame = buffer!
        CVPixelBufferLockBaseAddress(frame, [])
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        let base = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(frame)
        for y in 0..<size.height {
            for x in 0..<size.width {
                let offset = y * stride + x * 4
                base[offset] = UInt8(truncatingIfNeeded: x &+ index &* 3)
                base[offset + 1] = UInt8(truncatingIfNeeded: y &* 2 &+ index)
                base[offset + 2] = UInt8(truncatingIfNeeded: (x ^ y) &+ index &* 5)
                base[offset + 3] = 255
            }
        }
        return frame
    }

    static func makeAudio(track: Int, start: CMTime, frames: Int = 1600) -> TrackAudio {
        let first = Int(start.seconds * Double(TrackAudio.sampleRate))
        var samples = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let value = Float(sin(Double(first + i) * 2 * .pi * (220 * Double(track + 1)) / 48_000)) * 0.3
            samples[i * 2] = value
            samples[i * 2 + 1] = value
        }
        return TrackAudio(track: track, time: start, samples: samples)
    }

    static func configuration(
        _ directory: URL,
        base: String = "take",
        fps: Int = 30,
        audio: [String] = ["Mix", "Game"],
        split: TimeInterval? = nil,
        codec: VideoCodec = .h264,
        quality: VideoQuality = .automatic
    ) -> WriterConfiguration {
        WriterConfiguration(
            directory: directory, baseName: base, canvas: size, frameRate: fps, codec: codec,
            quality: quality, splitIntervalSeconds: split, lowDiskWarningBytes: 10 * 1_073_741_824,
            audioTrackNames: audio)
    }

    /// Waits until the encoder can take another frame, or the writer has no file open (it stopped, or hasn't begun the
    /// next part), so a test feeds frames without dropping any. Bounded on awake time, not by a count of pauses: an
    /// encoder that a busy Mac slows down is waited for, not given up on.
    static func waitForEncoder(_ writer: RecordingWriter) async {
        _ = await waitUntil { writer.canAcceptFrame || writer.currentFileURL == nil }
    }

    /// Feeds `frameCount` frames (and matching audio) at the nominal rate, waiting for the encoder instead
    /// of dropping, so the counts are exact. Time starts at `origin`.
    static func feed(
        _ writer: RecordingWriter,
        frames frameCount: Int,
        fps: Int = 30,
        from firstIndex: Int = 0,
        origin: CMTime = .zero,
        audioTracks: Int = 2
    ) async {
        for index in firstIndex..<(firstIndex + frameCount) {
            let time = origin + CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
            await waitForEncoder(writer)
            if writer.append(frame: makeFrame(index: index), at: time) == .stopped { return }
            for track in 0..<audioTracks {
                writer.append(audio: makeAudio(track: track, start: time, frames: 48_000 / fps))
            }
        }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool
    init(_ value: Bool) { storage = value }
    var value: Bool {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

final class FakeFreeSpace: FreeSpaceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64
    init(_ bytes: Int64) { self.bytes = bytes }
    var free: Int64 {
        get { lock.withLock { bytes } }
        set { lock.withLock { bytes = newValue } }
    }
    func freeBytes(at url: URL) -> Int64 { free }
}

func collect(_ events: AsyncStream<WriterEvent>) async -> [WriterEvent] {
    var all: [WriterEvent] = []
    for await event in events { all.append(event) }
    return all
}
