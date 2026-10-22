import AVFoundation
import CoreMedia
import Foundation

public enum RewrapError: Error, Equatable {
    case cannotRead(String)
    case cannotWrite(String)
    /// The new file differs from the source in codec, sample counts or track names; it has been deleted.
    case verificationFailed(String)
}

extension RewrapError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cannotRead(let reason): "the recording couldn\u{2019}t be read (\(reason))"
        case .cannotWrite(let reason): "the .mp4 couldn\u{2019}t be written (\(reason))"
        case .verificationFailed(let reason): "the .mp4 didn\u{2019}t match the recording: \(reason)"
        }
    }
}

/// Copies a recorded .mov into an .mp4 without re-encoding (spec 5.4.2, "On Save with .mp4 selected").
public enum Rewrapper {
    /// Rewraps `source` into `destination`, then verifies codec, sample counts, audio tracks and track names.
    /// The source is left untouched. A file already at `destination` is never replaced or removed: the rewrap fails
    /// first. On any other failure the destination it wrote is removed.
    @discardableResult
    public static func rewrap(from source: URL, to destination: URL) async throws -> MovieInfo {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw RewrapError.cannotWrite("\(destination.lastPathComponent) is already there")
        }
        var wrote = false
        do {
            try await copySamples(from: source, to: destination, wrote: &wrote)
            let original = try await MovieInfo.load(source)
            let rewrapped = try await MovieInfo.load(destination)
            try verify(original, rewrapped)
            return rewrapped
        } catch {
            if wrote { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
    }

    static func verify(_ original: MovieInfo, _ rewrapped: MovieInfo) throws {
        var problems: [String] = []
        if original.videoCodec != rewrapped.videoCodec {
            problems.append("codec \(original.videoCodec) -> \(rewrapped.videoCodec)")
        }
        if original.videoSampleCount != rewrapped.videoSampleCount {
            problems.append("video samples \(original.videoSampleCount) -> \(rewrapped.videoSampleCount)")
        }
        // AAC is counted in 1024-frame packets; the .mp4's edit list can round away the last one (≈21 ms of
        // encoder padding at the very end), so one packet's difference per track is not a lost sound.
        let sameAudio = original.audioTracks.count == rewrapped.audioTracks.count
            && zip(original.audioTracks, rewrapped.audioTracks).allSatisfy { $0.title == $1.title && abs($0.sampleCount - $1.sampleCount) <= 1 }
        if !sameAudio {
            problems.append("audio tracks \(original.audioTracks) -> \(rewrapped.audioTracks)")
        }
        if abs(original.duration - rewrapped.duration) > 0.1 {
            problems.append("duration \(original.duration) -> \(rewrapped.duration)")
        }
        if !problems.isEmpty { throw RewrapError.verificationFailed(problems.joined(separator: "; ")) }
    }

    /// `wrote` turns true once the writer has made `destination`: before that, a file there isn't this rewrap's.
    private static func copySamples(from source: URL, to destination: URL, wrote: inout Bool) async throws {
        let asset = AVURLAsset(url: source)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .video) + asset.loadTracks(withMediaType: .audio)
        } catch {
            throw RewrapError.cannotRead(error.localizedDescription)
        }
        guard !tracks.isEmpty else { throw RewrapError.cannotRead("no tracks") }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        var pumps: [CopyPump] = []
        for track in tracks {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            if track.mediaType == .video { input.transform = try await track.load(.preferredTransform) }
            input.metadata = try await titleMetadata(of: track)
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw RewrapError.cannotWrite("cannot pass through \(track.mediaType.rawValue) track")
            }
            reader.add(output)
            writer.add(input)
            pumps.append(CopyPump(output: output, input: input))
        }

        guard reader.startReading() else { throw RewrapError.cannotRead(reader.error?.localizedDescription ?? "") }
        guard writer.startWriting() else { throw RewrapError.cannotWrite(writer.error?.localizedDescription ?? "") }
        wrote = true
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            for pump in pumps { group.addTask { await pump.run() } }
        }
        let readFailure = reader.status == .failed ? reader.error?.localizedDescription : nil
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        if let readFailure { throw RewrapError.cannotRead(readFailure) }
        guard writer.status == .completed else { throw RewrapError.cannotWrite(writer.error?.localizedDescription ?? "") }
    }

    private static func titleMetadata(of track: AVAssetTrack) async throws -> [AVMetadataItem] {
        let items = try await track.load(.commonMetadata)
        var result: [AVMetadataItem] = []
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierTitle) {
            guard let title = try await item.load(.stringValue) else { continue }
            let copy = AVMutableMetadataItem()
            copy.identifier = .commonIdentifierTitle
            copy.value = title as NSString
            copy.dataType = kCMMetadataBaseDataType_UTF8 as String
            copy.extendedLanguageTag = "und"
            result.append(copy)
        }
        return result
    }
}

/// Moves samples from one reader output to one writer input on its own queue.
private final class CopyPump: @unchecked Sendable {
    private let output: AVAssetReaderTrackOutput
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "sTools.rewrap.pump")

    init(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput) {
        self.output = output
        self.input = input
    }

    func run() async {
        await withCheckedContinuation { continuation in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}
