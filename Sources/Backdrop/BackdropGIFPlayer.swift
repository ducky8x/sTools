import CoreGraphics
import Foundation
import QuartzCore

/// Plays a GIF as a layer's contents, each frame for its own delay, looping forever and ignoring the loop count the
/// file asks for (spec 5.2.3).
///
/// Frames are decoded off the main actor, one at a time and a few ahead of the one on screen; the main actor only sets
/// the layer's contents. A loop that fits the cache is decoded once and then only shown; a longer one keeps its next
/// frames and decodes the rest again on every loop, which is why a big GIF costs more than a video. Between two frames
/// nothing runs but one timer, set when a frame goes up and cancelled when it pauses. Decoding that falls behind slows
/// the picture; it never makes the frames come in a burst afterward.
@MainActor
final class BackdropGIFPlayer: BackdropPlayer {
    typealias Opener = @Sendable () async -> (any BackdropFrameSource)?

    /// What the decoded frames may add up to: a 1080p frame is about 8 MB.
    static let defaultCacheBudget = 128 * 1_048_576
    /// The frame on screen and the one after it are never let go of.
    private static let protectedFrames = 2

    let mediaLayer: CALayer = {
        let layer = CALayer()
        layer.contentsGravity = .resize
        // A new frame, a new size or a new place happens at once, never as Core Animation's default 0.25 s fade.
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "hidden": NSNull()]
        return layer
    }()

    private(set) var naturalSize: CGSize?
    private(set) var failure: String?
    var onUpdate: (@MainActor () -> Void)?

    /// Which frame is on screen (nil before the first), and how many times a frame has gone up. For tests.
    private(set) var shownFrameIndex: Int?
    private(set) var framesShown = 0
    private(set) var isPlaying = false
    var cachedFrameIndices: Set<Int> { Set(cache.keys) }

    private let clock: any BackdropFrameClock
    private let cacheBudget: Int
    private var source: (any BackdropFrameSource)?
    private var wantsToPlay = false
    private var isStopped = false
    /// The frame that is up, or that is due next while it isn't decoded yet.
    private var index = 0
    /// When the frame at `index` was meant to go up. The next one is due one delay later, so the delays add up
    /// exactly however late a timer fires.
    private var plannedStart: TimeInterval = 0
    private var timer: (any BackdropFrameTimer)?
    /// A frame that was due before it was decoded; it goes up the moment it is.
    private var waitingFor: Int?
    private var cache: [Int: CGImage] = [:]
    private var cachedBytes = 0
    private var undecodable: Set<Int> = []
    private var decodeTask: Task<Void, Never>?
    private var frameBytes = 1

    /// - Parameter open: opens the file; it runs off the main actor.
    init(clock: any BackdropFrameClock, cacheBudget: Int = BackdropGIFPlayer.defaultCacheBudget, open: @escaping Opener) {
        self.clock = clock
        self.cacheBudget = cacheBudget
        Task { [weak self] in
            let source = await open()
            self?.opened(source)
        }
    }

    /// A player for the GIF at `url`.
    convenience init(url: URL, clock: any BackdropFrameClock) {
        self.init(clock: clock) { await Task.detached(priority: .utility) { ImageIOFrameSource.open(at: url) }.value }
    }

    // MARK: - Control

    func play() {
        guard !isStopped, failure == nil else { return }
        wantsToPlay = true
        guard source != nil, !isPlaying else { return }
        begin()
    }

    func pause() {
        wantsToPlay = false
        guard isPlaying else { return }
        isPlaying = false
        timer?.cancel()
        timer = nil
        waitingFor = nil
    }

    func stop() {
        isStopped = true
        wantsToPlay = false
        isPlaying = false
        timer?.cancel()
        timer = nil
        waitingFor = nil
        decodeTask?.cancel()
        decodeTask = nil
        cache.removeAll()
        cachedBytes = 0
        undecodable.removeAll()
        source = nil
        shownFrameIndex = nil
        setContents(nil)
        onUpdate = nil
    }

    // MARK: - Playing

    private func opened(_ source: (any BackdropFrameSource)?) {
        guard !isStopped else { return }
        guard let source, source.frameCount > 0 else {
            fail()
            return
        }
        self.source = source
        naturalSize = source.size
        frameBytes = max(1, Int(source.size.width) * Int(source.size.height) * 4)
        onUpdate?()
        if wantsToPlay { begin() }
    }

    private func fail() {
        failure = BackdropPlayerMessages.cantPlay
        wantsToPlay = false
        isPlaying = false
        timer?.cancel()
        timer = nil
        waitingFor = nil
        onUpdate?()
    }

    private func begin() {
        isPlaying = true
        plannedStart = clock.now
        present()
    }

    /// Puts the frame at `index` up if it's decoded, otherwise waits for it.
    private func present() {
        guard isPlaying, let source else { return }
        if let image = cache[index] {
            let now = clock.now
            // Late by more than the frame's own time (a stalled main thread, slow decoding): start counting from now.
            if shownFrameIndex == nil || now - plannedStart > source.delay(at: index) { plannedStart = now }
            show(image)
        } else if undecodable.contains(index) {
            // The picture before it stays up for this frame's time. With nothing up yet there's nothing to show.
            if shownFrameIndex == nil {
                fail()
                return
            }
        } else {
            waitingFor = index
            decodeAhead()
            return
        }
        scheduleNext()
        decodeAhead()
    }

    private func show(_ image: CGImage) {
        guard shownFrameIndex != index else { return }
        setContents(image)
        shownFrameIndex = index
        framesShown += 1
    }

    private func setContents(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mediaLayer.contents = image
        CATransaction.commit()
    }

    private func scheduleNext() {
        guard let source, source.frameCount > 1 else { return }
        let delay = max(0, plannedStart + source.delay(at: index) - clock.now)
        timer?.cancel()
        timer = clock.schedule(after: delay) { [weak self] in self?.tick() }
    }

    private func tick() {
        timer = nil
        guard isPlaying, let source else { return }
        plannedStart += source.delay(at: index)
        index = (index + 1) % source.frameCount
        present()
    }

    // MARK: - Decoding

    /// How many frames, counting the one on screen, are worth having decoded: the whole loop when it fits the cache,
    /// otherwise as many as the cache holds, from two to four.
    private func lookahead(of count: Int) -> Int {
        if count * frameBytes <= cacheBudget { return count }
        return max(Self.protectedFrames, min(4, cacheBudget / frameBytes))
    }

    private func nextIndexToDecode(_ source: any BackdropFrameSource) -> Int? {
        let count = source.frameCount
        for step in 0..<min(lookahead(of: count), count) {
            let candidate = (index + step) % count
            if cache[candidate] == nil, !undecodable.contains(candidate) { return candidate }
        }
        return nil
    }

    /// Decodes the next frame that's wanted, if none is being decoded; each one that lands starts the next.
    private func decodeAhead() {
        guard isPlaying, decodeTask == nil, let source, let target = nextIndexToDecode(source) else { return }
        decodeTask = Task.detached(priority: .utility) { [weak self] in
            let image = source.frame(at: target)
            await self?.decoded(target, image)
        }
    }

    private func decoded(_ target: Int, _ image: CGImage?) {
        decodeTask = nil
        guard !isStopped, source != nil else { return }
        if let image {
            cache[target] = image
            let bytes = image.bytesPerRow * image.height
            cachedBytes += bytes
            frameBytes = max(1, bytes)
            trim()
        } else {
            undecodable.insert(target)
        }
        if waitingFor == target {
            waitingFor = nil
            present()
        } else {
            decodeAhead()
        }
    }

    /// Over the budget, lets go of the frame that will be needed last, never one of the frames on screen and next.
    private func trim() {
        guard let source else { return }
        let count = source.frameCount
        func distance(_ frame: Int) -> Int { (frame - index + count) % count }
        while cachedBytes > cacheBudget {
            guard let victim = cache.keys.filter({ distance($0) >= Self.protectedFrames }).max(by: { distance($0) < distance($1) }),
                  let image = cache.removeValue(forKey: victim) else { break }
            cachedBytes -= image.bytesPerRow * image.height
        }
    }
}
