import AppKit
import STDesign
import STPlatform
import SwiftUI
import Testing
@testable import Prologue

// The introduction under Reduce animations (spec 3.4, 4.1): every step shows its final state at once, the Finale
// switches the tried tools off together, and nothing waits on an animation that doesn't play. Views are hosted with
// no window, so nothing reaches a screen; there SwiftUI never advances an animation, so a render shows where any
// animation would start. Each reduced case has a full-motion control that must look or behave differently.

// MARK: - Harness

@MainActor
private final class Still {
    let host: NSHostingView<AnyView>

    init<V: View>(_ view: V, size: CGSize = CGSize(width: 760, height: 560)) {
        _ = NSApplication.shared
        host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        settle()
    }

    /// Lets pending updates (onAppear changes, observation) through without letting time pass for motion.
    func settle() {
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        host.layoutSubtreeIfNeeded()
    }

    func capture() -> NSBitmapImageRep {
        settle()
        let size = host.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
}

private func sameImage(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow,
          let left = a.bitmapData, let right = b.bitmapData else { return false }
    return memcmp(left, right, a.bytesPerRow * a.pixelsHigh) == 0
}

private func rgb(_ rep: NSBitmapImageRep, x: Int, y: Int) -> [UInt8] {
    guard let data = rep.bitmapData else { return [] }
    let offset = y * rep.bytesPerRow + x * (rep.bitsPerPixel / 8)
    return [data[offset], data[offset + 1], data[offset + 2]]
}

/// The window's near-black, `#0B0A09`.
private let background: [UInt8] = [0x0B, 0x0A, 0x09]

/// Counts what a test watches for.
@MainActor
private final class Counter {
    var count = 0
}

/// A sound player that stays silent (macOS's interface sounds read as off) but counts every sound asked of it.
@MainActor
private func countingSound(_ counter: Counter) -> STSoundPlayer {
    STSoundPlayer(theme: STTheme(soundsEnabled: true, soundVolume: 0.5), systemSoundsEnabled: {
        counter.count += 1
        return false
    })
}

@MainActor
private func show(_ model: PrologueModel, theme: STTheme, sound: STSoundPlayer = .silent) -> Still {
    Still(PrologueView(model: model)
        .stMotionRoot(theme)
        .environment(\.stTheme, theme)
        .environment(\.stSoundPlayer, sound))
}

@MainActor @Observable
private final class TypingState {
    var isStarted = false
    var completionCount = 0
}

private struct TypingProbe: View {
    let state: TypingState
    let finished: Counter

    var body: some View {
        TypewriterText(text: "You\u{2019}re set.", isStarted: state.isStarted, completionCount: state.completionCount,
                       onFinished: { finished.count += 1 })
            .font(.system(size: 24))
            .foregroundStyle(.white)
            .frame(width: 200, height: 40)
            .background(Color.black)
    }
}

// MARK: - Tests

@MainActor
@Suite("Prologue under reduced motion", .serialized)
struct PrologueReducedMotionTests {
    private let reduced = STTheme(motionMode: .reduced)

    // MARK: Greeting

    @Test func theGreetingIsCompleteFromItsFirstFrame() {
        let box = StoreBox()
        let model = PrologueModel(store: box.store, host: FakeHost(), startingAt: .greeting)
        let hosted = show(model, theme: reduced)
        let first = hosted.capture()
        #expect(rgb(first, x: 4, y: 4) == background, "no black veil to fade up from")
        #expect(!model.animations.isRunning)
        // Nothing happens later on its own either.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        #expect(sameImage(hosted.capture(), first))
    }

    @Test func underFullMotionTheGreetingIsACeremony() {
        let box = StoreBox()
        let model = PrologueModel(store: box.store, host: FakeHost(), startingAt: .greeting)
        let hosted = show(model, theme: STTheme())
        #expect(rgb(hosted.capture(), x: 4, y: 4) == [0, 0, 0], "it starts from pure black")
        #expect(model.animations.isRunning)
        model.animations.completeAll()
    }

    @Test func theFirstKeyReachesBeginBecauseNothingIsLeftToComplete() {
        let box = StoreBox()
        let model = PrologueModel(store: box.store, host: FakeHost(), startingAt: .greeting)
        _ = show(model, theme: reduced).capture()
        #expect(!model.animations.completeAll(), "the completer lets the key through")
        #expect(model.animations.completionCount == 0)
    }

    @Test func theGreetingStillChimes() {
        let box = StoreBox()
        let plays = Counter()
        let model = PrologueModel(store: box.store, host: FakeHost(), startingAt: .greeting)
        _ = show(model, theme: reduced, sound: countingSound(plays)).capture()
        #expect(plays.count == 1, "sounds aren't animations")
    }

    @Test func goingBackToTheGreetingShowsItCompleteAgain() {
        let box = StoreBox()
        let plays = Counter()
        let model = PrologueModel(store: box.store, host: FakeHost(), startingAt: .accessibility)
        let hosted = show(model, theme: reduced, sound: countingSound(plays))
        _ = hosted.capture()
        model.back()
        let back = hosted.capture()
        #expect(model.step == .greeting)
        #expect(rgb(back, x: 4, y: 4) == background)
        #expect(!model.animations.isRunning)
        let fresh = show(PrologueModel(store: box.store, host: FakeHost(), startingAt: .greeting), theme: reduced).capture()
        #expect(sameImage(back, fresh))
        #expect(plays.count == 2, "the page turn's sound, then the chime again")
    }

    @Test func reducingMotionMidCeremonyCompletesIt() {
        let theme = STTheme()
        let box = StoreBox()
        let model = PrologueModel(store: box.store, host: FakeHost(), startingAt: .greeting)
        let hosted = show(model, theme: theme)
        _ = hosted.capture()
        #expect(model.animations.isRunning)

        theme.systemReduceMotion = true
        let completed = hosted.capture()
        #expect(!model.animations.isRunning)
        #expect(model.animations.completionCount == 1)
        #expect(rgb(completed, x: 4, y: 4) == background)

        // Motion back on: the greeting stays complete instead of starting over from black.
        theme.systemReduceMotion = false
        #expect(rgb(hosted.capture(), x: 4, y: 4) == background)
        #expect(!model.animations.isRunning)
    }

    // MARK: Steps

    @Test func stepTitlesNeverArmTheGate() {
        let box = StoreBox()
        let model = PrologueModel(store: box.store, host: FakeHost(), startingAt: .crosshairTrial)
        _ = show(model, theme: reduced).capture()
        #expect(!model.animations.isRunning)

        let full = PrologueModel(store: box.store, host: FakeHost(), startingAt: .crosshairTrial)
        _ = show(full, theme: STTheme()).capture()
        #expect(full.animations.isRunning, "the control: under full motion the title types")
    }

    @Test(arguments: [true, false])
    func pagesTurnInPlace(forward: Bool) {
        let box = StoreBox()
        let host = FakeHost()
        let model = PrologueModel(store: box.store, host: host, startingAt: .backdropTrial)
        let hosted = show(model, theme: reduced)
        _ = hosted.capture()
        if forward { model.next() } else { model.back() }
        let turned = hosted.capture()
        let fresh = show(PrologueModel(store: box.store, host: host, startingAt: model.step), theme: reduced).capture()
        #expect(sameImage(turned, fresh))
    }

    @Test func underFullMotionPagesSlide() {
        let box = StoreBox()
        let host = FakeHost()
        let model = PrologueModel(store: box.store, host: host, startingAt: .backdropTrial)
        let hosted = show(model, theme: STTheme())
        _ = hosted.capture()
        model.next()
        let turned = hosted.capture()
        let fresh = show(PrologueModel(store: box.store, host: host, startingAt: model.step), theme: reduced).capture()
        #expect(!sameImage(turned, fresh))
    }

    @Test func theSkipPromptAppearsAndLeavesAtOnce() {
        let box = StoreBox()
        let host = FakeHost()
        let model = PrologueModel(store: box.store, host: host, startingAt: .camera)
        let hosted = show(model, theme: reduced)
        let before = hosted.capture()
        model.requestSkipIntroduction()
        let asking = hosted.capture()
        #expect(!sameImage(asking, before))
        model.cancelSkipIntroduction()
        #expect(sameImage(hosted.capture(), before), "Keep going puts the step back exactly as it was")
    }

    // MARK: Finale

    @Test func theFinaleSwitchesEverythingOffTogether() {
        let box = StoreBox()
        let host = FakeHost()
        host.toolsOn = [.nbbOverlay, .crosshair, .screenRecording]
        let model = PrologueModel(store: box.store, host: host, startingAt: .youreSet,
                                  finaleDelay: .seconds(60), finaleInterval: .seconds(60))
        _ = show(model, theme: reduced).capture()
        #expect(host.switchedOff == [.nbbOverlay, .crosshair, .screenRecording])
        #expect(model.finaleSwitchedOff == host.switchedOff)
        #expect(!model.isFinaleRunning, "nothing left pending")
        #expect(!model.animations.isRunning)
    }

    @Test func underFullMotionTheFinaleWaitsForItsTitle() {
        let box = StoreBox()
        let host = FakeHost()
        host.toolsOn = [.crosshair]
        let model = PrologueModel(store: box.store, host: host, startingAt: .youreSet,
                                  finaleDelay: .seconds(60), finaleInterval: .seconds(60))
        let hosted = show(model, theme: STTheme())
        _ = hosted.capture()
        #expect(host.switchedOff.isEmpty)
        #expect(model.animations.isRunning)
        // A click completes the title and the Finale at once.
        model.animations.completeAll()
        _ = hosted.capture()
        #expect(host.switchedOff == [.crosshair])
        #expect(!model.isFinaleRunning)
    }

    /// Found in the bug hunt: the title's gate ends before a Finale of several tools does, so reducing motion after
    /// it left the rest still going off one by one, with nothing to complete.
    @Test func reducingMotionMidFinaleSwitchesTheRestOffAtOnce() async {
        final class Time { var now = ContinuousClock.now }
        let time = Time()
        let theme = STTheme()
        let box = StoreBox()
        let host = FakeHost()
        host.toolsOn = [.nbbOverlay, .crosshair, .screenRecording]
        let model = PrologueModel(store: box.store, host: host, startingAt: .youreSet,
                                  animations: PrologueAnimations(now: { time.now }),
                                  finaleDelay: .zero, finaleInterval: .seconds(60))
        let hosted = show(model, theme: theme)
        _ = hosted.capture()
        model.runFinale()
        #expect(await waitUntil { host.switchedOff.count == 1 }, "the first goes off; the next waits a minute")
        time.now = time.now.advanced(by: .seconds(30))
        #expect(!model.animations.isRunning, "the title's gate is long over")

        theme.systemReduceMotion = true
        _ = hosted.capture()
        #expect(host.switchedOff == [.nbbOverlay, .crosshair, .screenRecording])
        #expect(!model.isFinaleRunning)
    }

    @Test func runFinaleAllAtOnceLeavesNothingPending() {
        let box = StoreBox()
        let host = FakeHost()
        host.toolsOn = [.windowBackdrop, .crosshair]
        let model = PrologueModel(store: box.store, host: host, startingAt: .youreSet,
                                  finaleDelay: .seconds(60), finaleInterval: .seconds(60))
        model.runFinale(inTurn: false)
        #expect(host.switchedOff == [.windowBackdrop, .crosshair])
        #expect(!model.isFinaleRunning)
        model.runFinale(inTurn: false)
        model.runFinale()
        #expect(host.switchedOff == [.windowBackdrop, .crosshair], "running it again changes nothing")
        model.next()
        #expect(model.step == .openSTools)
    }

    @Test func leavingTheIntroductionFromTheFinaleEndsCleanly() {
        let box = StoreBox()
        let host = FakeHost()
        host.toolsOn = [.crosshair]
        let model = PrologueModel(store: box.store, host: host, startingAt: .youreSet)
        let hosted = show(model, theme: reduced)
        _ = hosted.capture()
        model.next()
        _ = hosted.capture()
        model.next()
        #expect(host.outcomes == [.finished])
        #expect(host.switchedOff == [.crosshair])
        #expect(!model.isFinaleRunning)
    }

    // MARK: Typewriter

    @Test func typingWaitsToStartThenFinishesAtOnceAndOnlyOnce() {
        let state = TypingState()
        let finished = Counter()
        let hosted = Still(TypingProbe(state: state, finished: finished).environment(\.stTheme, reduced),
                           size: CGSize(width: 200, height: 40))
        let blank = hosted.capture()
        #expect(finished.count == 0, "not started yet")

        state.isStarted = true
        #expect(!sameImage(hosted.capture(), blank), "the whole line is there")
        #expect(finished.count == 1)

        state.completionCount += 1
        _ = hosted.capture()
        #expect(finished.count == 1, "a later key doesn't finish it twice")
    }

    @Test func typingDoneWhileReducedStaysWhenMotionReturns() {
        let theme = STTheme(motionMode: .reduced)
        let state = TypingState()
        state.isStarted = true
        let finished = Counter()
        let hosted = Still(TypingProbe(state: state, finished: finished).environment(\.stTheme, theme),
                           size: CGSize(width: 200, height: 40))
        _ = hosted.capture()
        theme.motionMode = .full
        let after = hosted.capture()

        let blankState = TypingState()
        let blank = Still(TypingProbe(state: blankState, finished: Counter()).environment(\.stTheme, theme),
                          size: CGSize(width: 200, height: 40)).capture()
        #expect(!sameImage(after, blank), "the line is still there, typed in full")
        #expect(finished.count == 1, "and it doesn't type again")
    }

    @Test func typingStartedFromTheFirstFrameFinishesOnAppear() {
        let state = TypingState()
        state.isStarted = true
        let finished = Counter()
        _ = Still(TypingProbe(state: state, finished: finished).environment(\.stTheme, reduced),
                  size: CGSize(width: 200, height: 40)).capture()
        #expect(finished.count == 1)

        let fullFinished = Counter()
        _ = Still(TypingProbe(state: state, finished: fullFinished).environment(\.stTheme, STTheme()),
                  size: CGSize(width: 200, height: 40)).capture()
        #expect(fullFinished.count == 0, "the control: under full motion it waits for the typing")
    }
}
