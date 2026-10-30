import AVFoundation
import CoreGraphics

/// What a video file is, read once and shared by importing it and by playing it: the picture track, how long it runs
/// and how big the picture is the way up it plays.
struct BackdropVideoDescription {
    /// Kept so the track, which only refers to its asset, never outlives it.
    let asset: AVURLAsset
    let track: AVAssetTrack
    let timeRange: CMTimeRange
    let transform: CGAffineTransform
    /// In pixels, with the track's rotation applied (a phone's portrait video is stored sideways).
    let pictureSize: CGSize

    /// Nil when AVFoundation can't play the file, it has no picture, or it has no length (a looper can't loop that).
    /// Throws when the file can't be read.
    static func load(from asset: AVURLAsset) async throws -> BackdropVideoDescription? {
        guard try await asset.load(.isPlayable), let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let (size, transform, range) = try await track.load(.naturalSize, .preferredTransform, .timeRange)
        guard range.duration.isNumeric, range.duration.seconds > 0 else { return nil }
        let oriented = size.applying(transform)
        let pictureSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        guard pictureSize.width > 0, pictureSize.height > 0 else { return nil }
        return BackdropVideoDescription(asset: asset, track: track, timeRange: range, transform: transform, pictureSize: pictureSize)
    }
}
