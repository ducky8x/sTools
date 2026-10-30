import AVFoundation
import Foundation
import QuartzCore

/// Plays a video file as a layer, looped and muted (spec 5.2.3). AVFoundation decodes it, on the hardware decoder when
/// the codec has one (H.264 and HEVC do on every Apple silicon Mac), and `AVPlayerLooper` loops it; Apple doesn't promise
/// the seam is gapless. This class only starts and stops it: no frames pass through the app, no timer runs, and nothing
/// polls.
///
/// The player is given the video track alone, in a composition, so the file's sound is never opened or decoded; it's
/// muted as well. A paused player holds the picture on screen and decodes nothing.
@MainActor
final class BackdropVideoPlayer: BackdropPlayer {
    private let playerLayer: AVPlayerLayer
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var statusObservation: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?
    private var wantsToPlay = false
    private var isStopped = false

    var mediaLayer: CALayer { playerLayer }
    private(set) var naturalSize: CGSize?
    private(set) var failure: String?
    private var observers = BackdropPlayerObservers()

    init(url: URL) {
        player.isMuted = true
        player.volume = 0
        // The default on macOS already; a backdrop must never keep the display awake.
        player.preventsDisplaySleepDuringVideoPlayback = false
        // A file on this Mac: start as soon as the first frames are there.
        player.automaticallyWaitsToMinimizeStalling = false
        playerLayer = AVPlayerLayer(player: player)
        // The host gives the layer the rect the fit mode works out, and the movie fills exactly that.
        playerLayer.videoGravity = .resize
        playerLayer.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "hidden": NSNull()]
        loadTask = Task { [weak self] in await self?.load(url) }
    }

    // MARK: - Control

    func observe(_ handler: @escaping @MainActor () -> Void) { observers.add(handler) }

    var isPlaying: Bool { wantsToPlay && !isStopped && failure == nil }

    func play() {
        guard !isStopped, failure == nil else { return }
        wantsToPlay = true
        if looper != nil { player.play() }
    }

    func pause() {
        wantsToPlay = false
        player.pause()
    }

    func showFirstFrame() {
        guard !isStopped, failure == nil else { return }
        wantsToPlay = false
        player.pause()
        // The first frame itself, not the nearest key frame. Before the movie is open there's nothing to rewind: it starts
        // paused at its start.
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        isStopped = true
        wantsToPlay = false
        loadTask?.cancel()
        loadTask = nil
        statusObservation = nil
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
        playerLayer.player = nil
        observers.removeAll()
    }

    // MARK: - Opening

    private func load(_ url: URL) async {
        do {
            guard let video = try await BackdropVideoDescription.load(from: AVURLAsset(url: url)) else { return fail() }
            let composition = AVMutableComposition()
            guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                return fail()
            }
            try videoTrack.insertTimeRange(video.timeRange, of: video.track, at: .zero)
            videoTrack.preferredTransform = video.transform
            guard !isStopped else { return }

            naturalSize = video.pictureSize
            // `AVPlayerLooper` raises an exception for an item without a duration; the composition has one.
            let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: composition))
            self.looper = looper
            statusObservation = looper.observe(\.status, options: [.new]) { [weak self] looper, _ in
                guard looper.status == .failed else { return }
                Task { @MainActor in self?.fail() }
            }
            observers.notify()
            if wantsToPlay { player.play() }
        } catch {
            fail()
        }
    }

    private func fail() {
        guard !isStopped, failure == nil else { return }
        failure = BackdropPlayerMessages.cantPlay
        wantsToPlay = false
        player.pause()
        observers.notify()
    }

    // MARK: - For tests

    var seconds: Double {
        let time = player.currentTime().seconds
        return time.isFinite ? time : 0
    }
    var rate: Float { player.rate }
    var isMuted: Bool { player.isMuted }
    var volume: Float { player.volume }
    var preventsDisplaySleep: Bool { player.preventsDisplaySleepDuringVideoPlayback }

    /// How many audio tracks the playing item holds.
    func audioTrackCount() async -> Int {
        guard let asset = player.currentItem?.asset else { return 0 }
        return (try? await asset.loadTracks(withMediaType: .audio).count) ?? 0
    }
}
