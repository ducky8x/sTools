import AVFoundation
import CoreMedia
import Foundation

/// What a finished movie contains, read back through AVFoundation. Used to verify rewraps and in tests.
public struct MovieInfo: Sendable, Equatable {
    public struct AudioTrackInfo: Sendable, Equatable {
        public var title: String?
        public var sampleCount: Int
    }

    public var duration: Double
    public var nominalFrameRate: Double
    /// Four-character codec code of the video track, such as `avc1` or `hvc1`.
    public var videoCodec: String
    public var videoSampleCount: Int
    public var audioTracks: [AudioTrackInfo]

    public static func load(_ url: URL) async throws -> MovieInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw MovieInfoError.noVideoTrack
        }
        let formats = try await video.load(.formatDescriptions)
        let codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "????"
        var audioTracks: [AudioTrackInfo] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let items = try await track.load(.commonMetadata)
            let titleItem = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierTitle).first
            let title = try await titleItem?.load(.stringValue)
            audioTracks.append(AudioTrackInfo(title: title, sampleCount: try await sampleCount(of: track, in: asset)))
        }
        return MovieInfo(
            duration: duration,
            nominalFrameRate: Double(try await video.load(.nominalFrameRate)),
            videoCodec: codec,
            videoSampleCount: try await sampleCount(of: video, in: asset),
            audioTracks: audioTracks)
    }

    /// Reads of a movie's samples run on this queue, one at a time, and never on a Swift concurrency thread. A read
    /// waits for CoreMedia's own queues. The concurrency pool has as many threads as the Mac has cores, and when every
    /// one of them sits in a read, as a test run that reads a dozen movies at once on a busy Mac can bring about, those
    /// queues get no thread to run on and no read ever ends (seen: a Screen Recording test run stuck for twenty
    /// minutes with all twelve threads in `copyNextSampleBuffer`).
    private static let readQueue = DispatchQueue(label: "sTools.movie-reads", qos: .userInitiated)

    /// Runs `work`, which may block on AVFoundation, on the read queue and returns its result without holding a
    /// Swift concurrency thread meanwhile.
    static func offThePool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            readQueue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private static func sampleCount(of track: AVAssetTrack, in asset: AVAsset) async throws -> Int {
        nonisolated(unsafe) let track = track
        nonisolated(unsafe) let asset = asset
        return try await offThePool {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { throw MovieInfoError.cannotRead(reader.error?.localizedDescription ?? "") }
            var count = 0
            while let sample = output.copyNextSampleBuffer() {
                count += CMSampleBufferGetNumSamples(sample)
            }
            return count
        }
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public enum MovieInfoError: Error, Equatable {
    case noVideoTrack
    case cannotRead(String)
}
