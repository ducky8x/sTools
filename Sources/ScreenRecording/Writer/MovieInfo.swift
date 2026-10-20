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
            audioTracks.append(AudioTrackInfo(title: title, sampleCount: try sampleCount(of: track, in: asset)))
        }
        return MovieInfo(
            duration: duration,
            nominalFrameRate: Double(try await video.load(.nominalFrameRate)),
            videoCodec: codec,
            videoSampleCount: try sampleCount(of: video, in: asset),
            audioTracks: audioTracks)
    }

    private static func sampleCount(of track: AVAssetTrack, in asset: AVAsset) throws -> Int {
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

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public enum MovieInfoError: Error, Equatable {
    case noVideoTrack
    case cannotRead(String)
}
