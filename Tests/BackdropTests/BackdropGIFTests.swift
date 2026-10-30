import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import Testing
@testable import Backdrop

/// Frames made up for the player: solid pictures that record where they were decoded, and can be held back.
final class FakeFrameSource: BackdropFrameSource, @unchecked Sendable {
    let images: [CGImage]
    let delays: [TimeInterval]
    let size: CGSize
    var frameCount: Int { images.count }

    private let lock = NSCondition()
    private var held: Set<Int> = []
    private var undecodable: Set<Int>
    private var decoded: [Int] = []
    private var anyOnMain = false

    init(colors: [RGB], delays: [TimeInterval], undecodable: Set<Int> = []) {
        images = colors.map { TestMedia.solidImage($0) }
        self.delays = delays
        self.undecodable = undecodable
        size = CGSize(width: 16, height: 12)
    }

    func delay(at index: Int) -> TimeInterval { delays[index] }

    func frame(at index: Int) -> CGImage? {
        lock.lock()
        decoded.append(index)
        if Thread.isMainThread { anyOnMain = true }
        while held.contains(index) { lock.wait() }
        let fails = undecodable.contains(index)
        lock.unlock()
        return fails ? nil : images[index]
    }

    /// Makes decoding frame `index` wait until `release(_:)`.
    func hold(_ index: Int) { lock.lock(); held.insert(index); lock.unlock() }

    func release(_ index: Int) { lock.lock(); held.remove(index); lock.broadcast(); lock.unlock() }

    var decodeCalls: [Int] { lock.lock(); defer { lock.unlock() }; return decoded }
    var wasEverDecodedOnTheMainThread: Bool { lock.lock(); defer { lock.unlock() }; return anyOnMain }
}

@MainActor
private func isShowing(_ image: CGImage, in player: BackdropGIFPlayer) -> Bool {
    guard let contents = player.mediaLayer.contents else { return false }
    return (contents as AnyObject) === (image as AnyObject)
}

@MainActor
@Suite("GIF player")
struct BackdropGIFPlayerTests {
    // Exact binary fractions, so the fake clock adds up without rounding.
    private let makeSource = { FakeFrameSource(colors: [.red, .green, .blue], delays: [0.25, 0.5, 0.25]) }

    @Test func showsTheFirstFrameWhenPlayedThenFollowsEachFramesOwnDelayAndLoops() async {
        let clock = FakeFrameClock()
        let source = makeSource()
        let player = BackdropGIFPlayer(clock: clock) { source }
        player.play()
        #expect(await waitUntil { player.shownFrameIndex == 0 && player.cachedFrameIndices.count == 3 })
        #expect(isShowing(source.images[0], in: player))

        clock.advance(by: 0.125)
        #expect(player.shownFrameIndex == 0, "frame 0 is up for its own 0.25 s")
        clock.advance(by: 0.125)
        #expect(player.shownFrameIndex == 1)
        #expect(isShowing(source.images[1], in: player))
        clock.advance(by: 0.375)
        #expect(player.shownFrameIndex == 1, "frame 1 is up for its own 0.5 s, not frame 0's")
        clock.advance(by: 0.125)
        #expect(player.shownFrameIndex == 2)
        clock.advance(by: 0.25)
        #expect(player.shownFrameIndex == 0, "after the last frame it loops")
        #expect(isShowing(source.images[0], in: player))
        clock.advance(by: 1)
        #expect(player.shownFrameIndex == 0, "a whole loop later, the same frame")
    }

    @Test func framesAreDecodedOffTheMainThread() async {
        let clock = FakeFrameClock()
        let source = makeSource()
        let player = BackdropGIFPlayer(clock: clock) { source }
        player.play()
        #expect(await waitUntil { player.cachedFrameIndices.count == 3 })
        clock.advance(by: 1)
        #expect(!source.decodeCalls.isEmpty)
        #expect(!source.wasEverDecodedOnTheMainThread)
        player.stop()
    }

    @Test func pausingStopsTheTimerAndDecodingAndResumingContinuesFromTheSameFrame() async {
        let clock = FakeFrameClock()
        let source = makeSource()
        let player = BackdropGIFPlayer(clock: clock) { source }
        player.play()
        #expect(await waitUntil { player.cachedFrameIndices.count == 3 })
        clock.advance(by: 0.25)
        #expect(player.shownFrameIndex == 1)
        #expect(clock.waiting.count == 1)

        player.pause()
        #expect(!player.isPlaying)
        #expect(clock.waiting.isEmpty, "nothing is scheduled while it's paused")
        clock.advance(by: 10)
        #expect(player.shownFrameIndex == 1, "time passing changes nothing while it's paused")
        let calls = source.decodeCalls.count
        try? await Task.sleep(for: .milliseconds(30))
        #expect(source.decodeCalls.count == calls, "and nothing is decoded")

        player.play()
        #expect(player.isPlaying)
        #expect(player.shownFrameIndex == 1, "it carries on from the frame it paused on")
        #expect(clock.waiting.count == 1)
        clock.advance(by: 0.5)
        #expect(player.shownFrameIndex == 2)
    }

    /// A decode that was already under way lands, and that is all: nothing new is started while it's paused.
    @Test func aPausedPlayerDecodesNothingMore() async {
        let clock = FakeFrameClock()
        let colors: [RGB] = [.red, .green, .blue, .yellow, .red, .green]
        let source = FakeFrameSource(colors: colors, delays: Array(repeating: 0.25, count: colors.count))
        source.hold(2)
        let player = BackdropGIFPlayer(clock: clock) { source }
        player.play()
        #expect(await waitUntil { player.shownFrameIndex == 0 && player.cachedFrameIndices == [0, 1] })
        player.pause()
        source.release(2)
        #expect(await waitUntil { player.cachedFrameIndices.contains(2) })
        try? await Task.sleep(for: .milliseconds(40))
        #expect(source.decodeCalls.sorted() == [0, 1, 2], "frames 3 to 5 wait for it to play again")

        player.play()
        #expect(await waitUntil { player.cachedFrameIndices.count == colors.count })
    }

    @Test func playingBeforeTheFileIsOpenStartsOnceItIs() async {
        let clock = FakeFrameClock()
        let source = makeSource()
        let gate = Gate()
        let player = BackdropGIFPlayer(clock: clock) { await gate.wait(); return source }
        player.play()
        #expect(player.naturalSize == nil)
        #expect(player.shownFrameIndex == nil)
        gate.open()
        #expect(await waitUntil { player.shownFrameIndex == 0 })
        #expect(player.naturalSize == CGSize(width: 16, height: 12))
        #expect(player.isPlaying)
    }

    @Test func aFileThatIsStillOpeningWhenItIsPausedStaysPaused() async {
        let clock = FakeFrameClock()
        let source = makeSource()
        let gate = Gate()
        let player = BackdropGIFPlayer(clock: clock) { await gate.wait(); return source }
        player.play()
        player.pause()
        gate.open()
        #expect(await waitUntil { player.naturalSize != nil })
        #expect(!player.isPlaying)
        #expect(player.shownFrameIndex == nil)
        #expect(clock.waiting.isEmpty)
    }

    @Test func aFileThatWontOpenFails() async {
        let player = BackdropGIFPlayer(clock: FakeFrameClock()) { nil }
        var updates = 0
        player.onUpdate = { updates += 1 }
        player.play()
        #expect(await waitUntil { player.failure != nil })
        #expect(updates == 1)
        #expect(player.naturalSize == nil)
        #expect(!player.isPlaying)
    }

    @Test func aSingleFrameShowsOnceAndSchedulesNothing() async {
        let clock = FakeFrameClock()
        let still = FakeFrameSource(colors: [.yellow], delays: [0.25])
        let player = BackdropGIFPlayer(clock: clock) { still }
        player.play()
        #expect(await waitUntil { player.shownFrameIndex == 0 })
        #expect(clock.waiting.isEmpty)
    }

    @Test func stoppingLetsEverythingGo() async {
        let clock = FakeFrameClock()
        let source = makeSource()
        let player = BackdropGIFPlayer(clock: clock) { source }
        player.play()
        #expect(await waitUntil { player.shownFrameIndex == 0 })
        player.stop()
        #expect(clock.waiting.isEmpty)
        #expect(player.cachedFrameIndices.isEmpty)
        #expect(player.mediaLayer.contents == nil)
        player.play()
        clock.advance(by: 5)
        #expect(player.shownFrameIndex == nil, "a stopped player stays stopped")
        #expect(!player.isPlaying)
    }

    /// Decoding that falls behind slows the picture down; it never makes the frames come in a burst afterward.
    @Test func aFrameThatIsLateIsShownWhenItArrivesAndTheNextOneGetsItsFullTime() async {
        let clock = FakeFrameClock()
        let source = makeSource()
        source.hold(1)
        let player = BackdropGIFPlayer(clock: clock) { source }
        player.play()
        #expect(await waitUntil { player.shownFrameIndex == 0 })
        clock.advance(by: 0.25)
        #expect(player.shownFrameIndex == 0, "frame 1 isn't decoded yet, so frame 0 stays up")
        clock.advance(by: 1.75)
        #expect(player.shownFrameIndex == 0)
        #expect(player.framesShown == 1)
        #expect(clock.waiting.isEmpty, "and no timer runs while it waits")

        source.release(1)
        #expect(await waitUntil { player.shownFrameIndex == 1 && player.cachedFrameIndices.contains(2) })
        #expect(player.framesShown == 2, "one frame went up, not the ones it fell behind by")
        clock.advance(by: 0.25)
        #expect(player.shownFrameIndex == 1 && player.framesShown == 2, "frame 1 still gets part of its 0.5 s")
        clock.advance(by: 0.25)
        #expect(player.shownFrameIndex == 2 && player.framesShown == 3)
    }

    @Test func aFrameThatCantBeDecodedKeepsThePreviousOneUp() async {
        let clock = FakeFrameClock()
        let source = FakeFrameSource(colors: [.red, .green, .blue], delays: [0.25, 0.25, 0.25], undecodable: [1])
        let player = BackdropGIFPlayer(clock: clock) { source }
        player.play()
        #expect(await waitUntil { player.shownFrameIndex == 0 && player.cachedFrameIndices.count == 2 })
        clock.advance(by: 0.25)
        #expect(isShowing(source.images[0], in: player), "the bad frame is skipped: the picture before it stays")
        clock.advance(by: 0.25)
        #expect(player.shownFrameIndex == 2)
    }

    @Test func theFirstFrameCantBeDecodedSoTheFileFails() async {
        let source = FakeFrameSource(colors: [.red, .green], delays: [0.25, 0.25], undecodable: [0])
        let player = BackdropGIFPlayer(clock: FakeFrameClock()) { source }
        player.play()
        #expect(await waitUntil { player.failure != nil })
        #expect(!player.isPlaying)
    }

    @Test func theCacheKeepsToItsBudgetByLettingGoOfTheFramesJustShown() async {
        let clock = FakeFrameClock()
        let colors: [RGB] = [.red, .green, .blue, .yellow, .red, .green]
        let source = FakeFrameSource(colors: colors, delays: Array(repeating: 0.25, count: colors.count))
        let frameBytes = source.images[0].bytesPerRow * source.images[0].height
        let player = BackdropGIFPlayer(clock: clock, cacheBudget: frameBytes * 5 / 2) { source }
        player.play()
        for expected in 0..<colors.count * 2 {
            let index = expected % colors.count
            #expect(await waitUntil { player.shownFrameIndex == index }, "frame \(index) in turn \(expected)")
            #expect(player.cachedFrameIndices.count <= 3, "at most the frame up and one or two ahead")
            #expect(await waitUntil { player.cachedFrameIndices.contains((index + 1) % colors.count) })
            clock.advance(by: 0.25)
        }
        #expect(source.decodeCalls.count > colors.count, "a loop that doesn't fit is decoded again on the next one")
    }

    @Test func aLoopThatFitsIsDecodedOnceAndThenOnlyShown() async {
        let clock = FakeFrameClock()
        let source = makeSource()
        let player = BackdropGIFPlayer(clock: clock) { source }
        player.play()
        #expect(await waitUntil { player.cachedFrameIndices.count == 3 })
        for _ in 0..<12 { clock.advance(by: 0.25) }
        #expect(source.decodeCalls.sorted() == [0, 1, 2], "each frame is decoded once however many loops play")
    }
}

/// Holds an async step until the test opens it.
@MainActor
final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

@Suite("GIF files")
struct BackdropGIFFileTests {
    @Test func aGeneratedGIFOpensWithItsFramesSizeAndDelays() throws {
        let folder = TempFolder()
        let url = TestMedia.writeGIF(to: folder.file("loop.gif"), colors: [.red, .green, .blue], delays: [0.1, 0.2, 0.05], width: 20, height: 10)
        let source = try #require(ImageIOFrameSource.open(at: url))
        #expect(source.frameCount == 3)
        #expect(source.size == CGSize(width: 20, height: 10))
        #expect(source.delay(at: 0) == 0.1 && source.delay(at: 1) == 0.2)
        #expect(abs(source.delay(at: 2) - 0.05) < 0.0001)
        let colors = (0..<3).compactMap { source.frame(at: $0) }.map { TestMedia.color(of: $0) }
        #expect(colors == [.red, .green, .blue])
    }

    /// What browsers do with the delay of a frame that asks for none.
    @Test func aDelayOfZeroOrOneHundredthPlaysAsATenthOfASecond() throws {
        let folder = TempFolder()
        let url = TestMedia.writeGIF(to: folder.file("fast.gif"), colors: [.red, .green, .blue], delays: [0, 0.01, 0.5])
        let source = try #require(ImageIOFrameSource.open(at: url))
        #expect(source.delay(at: 0) == 0.1)
        #expect(source.delay(at: 1) == 0.1)
        #expect(source.delay(at: 2) == 0.5)
    }

    @Test func aFileThatIsNotAGIFDoesNotOpen() throws {
        let folder = TempFolder()
        let text = folder.file("hello.gif")
        try "not a picture".write(to: text, atomically: true, encoding: .utf8)
        #expect(ImageIOFrameSource.open(at: text) == nil)
        #expect(ImageIOFrameSource.open(at: folder.file("missing.gif")) == nil)

        // A still picture is not an animation, whatever it is called.
        let png = folder.file("still.gif")
        try writePNG(TestMedia.solidImage(.red), to: png)
        #expect(ImageIOFrameSource.open(at: png) == nil)
    }

    @Test func aGIFWithOneFrameOpens() throws {
        let folder = TempFolder()
        let url = TestMedia.writeGIF(to: folder.file("one.gif"), colors: [.yellow], delays: [0.1])
        #expect(try #require(ImageIOFrameSource.open(at: url)).frameCount == 1)
    }
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}
