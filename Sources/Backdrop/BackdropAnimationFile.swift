import AVFoundation
import CoreGraphics
import Foundation

/// Finds out what a GIF or video file is, copies a chosen one into sTools' own Images folder, and makes the player for
/// one (spec 5.2.3). The Animated fill refers to its copy the way the Image fill refers to its image.
enum BackdropAnimationFile {
    enum Kind: Equatable, Sendable {
        /// Frames read with ImageIO and drawn one by one.
        case gif
        /// Anything else: AVFoundation plays it or says it can't.
        case video
    }

    /// What a file turned out to be.
    struct Info: Sendable {
        let kind: Kind
        /// In pixels, the way up it plays.
        let size: CGSize
        /// The first frame, for the page's preview. Nil when it wasn't asked for or couldn't be made.
        let poster: CGImage?
    }

    /// The copy in Images/ stays within this, because Settings ▸ Export puts every file of Images/ into one settings
    /// file, as text a third larger than the file.
    static let maximumBytes = 200 * 1_048_576

    static let cantPlayMessage = "sTools can\u{2019}t play that file. Choose a GIF or a video such as MP4 or MOV."
    static let noFolderMessage = "sTools couldn\u{2019}t create its Images folder. Check that your disk isn\u{2019}t full, then try again."
    static let copyMessage = "sTools couldn\u{2019}t copy that file."

    static func tooBigMessage(maximumBytes: Int) -> String {
        "That file is larger than \(maximumBytes / 1_048_576) MB. Choose a smaller or shorter one."
    }

    // MARK: - Kinds

    /// A GIF by its header, whatever the file is called; anything else readable is left to AVFoundation. Nil when the
    /// file can't be opened at all.
    static func kind(of url: URL) -> Kind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 6)) ?? Data()
        return header == Data("GIF87a".utf8) || header == Data("GIF89a".utf8) ? .gif : .video
    }

    // MARK: - Probing

    /// Opens the file far enough to know it can be played, off the main actor. A failure carries the line to show.
    static func probe(_ url: URL, wantsPoster: Bool = true) async -> Result<Info, BackdropImageImport.ImportError> {
        let problem = BackdropImageImport.ImportError(message: cantPlayMessage)
        switch kind(of: url) {
        case nil:
            return .failure(problem)
        case .gif:
            return await Task.detached(priority: .utility) {
                guard let source = ImageIOFrameSource.open(at: url) else { return .failure(problem) }
                return .success(Info(kind: .gif, size: source.size, poster: wantsPoster ? source.frame(at: 0) : nil))
            }.value
        case .video:
            do {
                let asset = AVURLAsset(url: url)
                guard let video = try await BackdropVideoDescription.load(from: asset) else { return .failure(problem) }
                var poster: CGImage?
                if wantsPoster {
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    // A 4K frame is 33 MB; anything larger is brought down to it for the preview.
                    generator.maximumSize = CGSize(width: 3840, height: 3840)
                    poster = try? await generator.image(at: .zero).image
                }
                return .success(Info(kind: .video, size: video.pictureSize, poster: poster))
            } catch {
                return .failure(problem)
            }
        }
    }

    // MARK: - Importing

    /// Copies the GIF or video at `url` into `directory` under a fresh name and returns the stored relative name
    /// (`Images/<uuid>.<ext>`), or a line to show when it can't be played, is larger than `maximumBytes` or can't be
    /// copied. Nothing is copied unless the whole file checks out, and the work is done off the main actor.
    static func importAnimation(
        from url: URL, into directory: URL, maximumBytes: Int = BackdropAnimationFile.maximumBytes
    ) async -> Result<String, BackdropImageImport.ImportError> {
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maximumBytes {
            return .failure(.init(message: tooBigMessage(maximumBytes: maximumBytes)))
        }
        let kind: Kind
        switch await probe(url, wantsPoster: false) {
        case .failure(let problem): return .failure(problem)
        case .success(let info): kind = info.kind
        }
        return await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return .failure(.init(message: noFolderMessage))
            }
            let name = "\(UUID().uuidString).\(storedExtension(of: url, kind: kind))"
            do {
                try FileManager.default.copyItem(at: url, to: directory.appending(path: name))
            } catch {
                return .failure(.init(message: copyMessage))
            }
            return .success("Images/\(name)")
        }.value
    }

    /// The file's own extension in lowercase letters and digits, which AVFoundation reads the format from; a file
    /// without one gets the usual one for what it is.
    private static func storedExtension(of url: URL, kind: Kind) -> String {
        let own = url.pathExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if !own.isEmpty { return String(own.prefix(8)) }
        return kind == .gif ? "gif" : "mp4"
    }

    // MARK: - Playing

    /// The player for the file at `url`: a GIF's frames, a video, or one that has failed already for a file that isn't
    /// there.
    @MainActor
    static func makePlayer(for url: URL, clock: any BackdropFrameClock) -> any BackdropPlayer {
        switch kind(of: url) {
        case .gif: BackdropGIFPlayer(url: url, clock: clock)
        case .video: BackdropVideoPlayer(url: url)
        case nil: BackdropFailedPlayer()
        }
    }
}
