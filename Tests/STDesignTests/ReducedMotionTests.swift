import AppKit
import SwiftUI
import Testing
@testable import STDesign

// Reduce animations (spec 3.4): while the theme reduces motion nothing moves. These tests host views with no window,
// so nothing can reach a screen. Without a window SwiftUI never advances an animation: a render right after a
// change shows where any animation would start, so a change that animates and one that lands at once look different.
// Every test of the reduced case is paired with the same change under full motion, which must look different, so a
// pass never comes from an animation that simply wasn't drawn.

// MARK: - Harness

/// A view in an `NSHostingView` with no window, rendered at 1x.
@MainActor
final class StillHost<Content: View> {
    let host: NSHostingView<Content>

    init(_ view: Content, size: CGSize) {
        _ = NSApplication.shared
        host = hostingView(view)
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        settle()
    }

    /// Lets SwiftUI apply pending updates (onAppear changes, observation) without letting any time pass for motion.
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

/// Whether two renders are the same, pixel for pixel.
func sameImage(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow,
          let left = a.bitmapData, let right = b.bitmapData else { return false }
    return memcmp(left, right, a.bytesPerRow * a.pixelsHigh) == 0
}

/// The state a test changes from outside the view.
@MainActor @Observable
final class MotionBox {
    var isOn = false
    var number = 70.0
    var text = "a"
    var choice = 0
}

/// A white bar that sits at the left and moves to the right edge when `box.isOn`; with `implicit`, through
/// `.animation(_:value:)`. (Without one there's no `.animation` at all: `.animation(nil, value:)` would itself cancel
/// an explicit animation.)
private struct Bar: View {
    let box: MotionBox
    var implicit: Animation?

    var body: some View {
        ZStack(alignment: .leading) {
            Color.black
            if let implicit {
                bar.animation(implicit, value: box.isOn)
            } else {
                bar
            }
        }
        .frame(width: 100, height: 10)
    }

    private var bar: some View {
        Color.white.frame(width: 10).offset(x: box.isOn ? 90 : 0)
    }
}

/// A white bar that's inserted when `box.isOn`, sliding in from the right.
private struct Arrival: View {
    let box: MotionBox

    var body: some View {
        ZStack(alignment: .leading) {
            Color.black
            if box.isOn {
                Color.white.frame(width: 10).transition(.offset(x: 90))
            }
        }
        .frame(width: 100, height: 10)
    }
}

private let barSize = CGSize(width: 100, height: 10)
private let slow: Animation = .linear(duration: 10)

/// The bar's render with `isOn` already true: where every change must end.
@MainActor
private func settledBar() -> NSBitmapImageRep {
    let box = MotionBox()
    box.isOn = true
    return StillHost(Bar(box: box), size: barSize).capture()
}

@MainActor
private func settledArrival() -> NSBitmapImageRep {
    let box = MotionBox()
    box.isOn = true
    return StillHost(Arrival(box: box), size: barSize).capture()
}

// MARK: - The combined state

@MainActor
@Suite("Reduced motion: the combined state")
struct ReducedMotionStateTests {
    @Test(arguments: [(STMotionMode.full, false, false), (.full, true, true), (.reduced, false, true), (.reduced, true, true)])
    func motionIsReducedByTheSettingOrBySystem(mode: STMotionMode, system: Bool, reduced: Bool) {
        let theme = STTheme(motionMode: mode, systemReduceMotion: system)
        #expect(theme.reduceMotion == reduced)
    }

    @Test func theSwitchWorksWhateverTheSystemSays() {
        let theme = STTheme(systemReduceMotion: false)
        theme.motionMode = .reduced
        #expect(theme.reduceMotion)
        theme.systemReduceMotion = true
        theme.motionMode = .full
        #expect(theme.reduceMotion, "macOS's Reduce motion still reduces with the switch off")
        theme.systemReduceMotion = false
        #expect(!theme.reduceMotion)
    }

    @Test func theFallbackThemeMovesFully() {
        #expect(!STTheme.fallback.reduceMotion)
    }
}

// MARK: - The motion root

@MainActor
@Suite("Reduced motion: the motion root", .serialized)
struct MotionRootTests {
    @Test func underFullMotionTheChangeAnimates() {
        let box = MotionBox()
        let hosted = StillHost(Bar(box: box, implicit: slow).stMotionRoot(STTheme()), size: barSize)
        box.isOn = true
        #expect(!sameImage(hosted.capture(), settledBar()), "the control: an implicit animation is visible")
    }

    @Test func itStopsImplicitAnimations() {
        let box = MotionBox()
        let hosted = StillHost(Bar(box: box, implicit: slow).stMotionRoot(STTheme(motionMode: .reduced)), size: barSize)
        box.isOn = true
        #expect(sameImage(hosted.capture(), settledBar()))
    }

    @Test func itStopsExplicitAnimations() {
        let box = MotionBox()
        let full = StillHost(Bar(box: box).stMotionRoot(STTheme()), size: barSize)
        let reducedBox = MotionBox()
        let reduced = StillHost(Bar(box: reducedBox).stMotionRoot(STTheme(motionMode: .reduced)), size: barSize)
        withAnimation(slow) {
            box.isOn = true
            reducedBox.isOn = true
        }
        #expect(!sameImage(full.capture(), settledBar()))
        #expect(sameImage(reduced.capture(), settledBar()))
    }

    @Test func itStopsTransitions() {
        let box = MotionBox()
        let full = StillHost(Arrival(box: box).stMotionRoot(STTheme()), size: barSize)
        let reducedBox = MotionBox()
        let reduced = StillHost(Arrival(box: reducedBox).stMotionRoot(STTheme(motionMode: .reduced)), size: barSize)
        withAnimation(slow) {
            box.isOn = true
            reducedBox.isOn = true
        }
        #expect(!sameImage(full.capture(), settledArrival()))
        #expect(sameImage(reduced.capture(), settledArrival()))
    }

    @Test func aRemovalIsInstantToo() {
        let box = MotionBox()
        box.isOn = true
        let hosted = StillHost(Arrival(box: box).stMotionRoot(STTheme(motionMode: .reduced)), size: barSize)
        withAnimation(slow) { box.isOn = false }
        let empty = StillHost(Arrival(box: MotionBox()), size: barSize).capture()
        #expect(sameImage(hosted.capture(), empty))
    }

    @Test func macOSReduceMotionAloneIsEnough() {
        let box = MotionBox()
        let hosted = StillHost(Bar(box: box, implicit: slow).stMotionRoot(STTheme(systemReduceMotion: true)), size: barSize)
        box.isOn = true
        #expect(sameImage(hosted.capture(), settledBar()))
    }

    @Test func itFollowsTheThemeLive() {
        let theme = STTheme()
        let box = MotionBox()
        let hosted = StillHost(Bar(box: box, implicit: slow).stMotionRoot(theme), size: barSize)
        let atStart = hosted.capture()

        theme.motionMode = .reduced
        box.isOn = true
        #expect(sameImage(hosted.capture(), settledBar()), "turned on: the change lands at once")

        theme.motionMode = .full
        box.isOn = false
        #expect(!sameImage(hosted.capture(), atStart), "turned off again: the change animates")

        // Back on: the next change lands at once, wherever the last animation had got to.
        theme.motionMode = .reduced
        box.isOn = true
        #expect(sameImage(hosted.capture(), settledBar()))
    }

    @Test func animateMakesItsChangesAtOnceWhileReduced() {
        let box = MotionBox()
        let reduced = StillHost(Arrival(box: box), size: barSize)
        STMotion.animate(slow, reduce: true) { box.isOn = true }
        #expect(sameImage(reduced.capture(), settledArrival()), "no root needed: animate itself turns animations off")

        let fullBox = MotionBox()
        let full = StillHost(Arrival(box: fullBox), size: barSize)
        STMotion.animate(slow, reduce: false) { fullBox.isOn = true }
        #expect(!sameImage(full.capture(), settledArrival()))
    }

    @Test func animateRunsItsCompletionUnderAReducedRoot() {
        let box = MotionBox()
        let hosted = StillHost(Bar(box: box).stMotionRoot(STTheme(motionMode: .reduced)), size: barSize)
        var completions = 0
        STMotion.animate(slow, reduce: true) { box.isOn = true } completion: { completions += 1 }
        #expect(completions == 1)
        hosted.settle()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        #expect(completions == 1, "and only once")
        #expect(sameImage(hosted.capture(), settledBar()))
    }

    @Test func stAnimationAloneGivesNoAnimationWhileReduced() {
        struct Themed: View {
            let box: MotionBox
            var body: some View {
                ZStack(alignment: .leading) {
                    Color.black
                    Color.white.frame(width: 10).offset(x: box.isOn ? 90 : 0).stAnimation(.linear(duration: 10), value: box.isOn)
                }
                .frame(width: 100, height: 10)
            }
        }
        let reducedBox = MotionBox()
        let reduced = StillHost(Themed(box: reducedBox).environment(\.stTheme, STTheme(motionMode: .reduced)), size: barSize)
        let fullBox = MotionBox()
        let full = StillHost(Themed(box: fullBox).environment(\.stTheme, STTheme()), size: barSize)
        reducedBox.isOn = true
        fullBox.isOn = true
        #expect(sameImage(reduced.capture(), settledBar()))
        #expect(!sameImage(full.capture(), settledBar()))
    }
}

// MARK: - Components

/// A component in a fixed frame on the app's background, under `theme`.
@MainActor
private func component<V: View>(_ view: V, theme: STTheme, size: CGSize) -> StillHost<AnyView> {
    StillHost(AnyView(view.frame(width: size.width, height: size.height).background(STColor.background)
                          .stMotionRoot(theme).environment(\.stTheme, theme)), size: size)
}

/// Builds its content in its body, so what `make` reads from the box is observed and a change redraws it.
private struct Observing<Content: View>: View {
    let box: MotionBox
    let make: (MotionBox) -> Content

    var body: some View { make(box) }
}

@MainActor
@Suite("Reduced motion: components", .serialized)
struct ReducedMotionComponentTests {
    private let reduced = STTheme(motionMode: .reduced)

    /// Changes `change` on a hosted view under full motion and while reduced, and compares each with a view built
    /// in the changed state: reduced must match it at once, full motion must not.
    private func check<V: View>(size: CGSize, setUp: (MotionBox) -> Void = { _ in }, change: (MotionBox) -> Void,
                                _ make: @escaping (MotionBox) -> V, sourceLocation: SourceLocation = #_sourceLocation) {
        let settledBox = MotionBox()
        setUp(settledBox)
        change(settledBox)
        let settled = component(Observing(box: settledBox, make: make), theme: STTheme(motionMode: .reduced), size: size).capture()

        let reducedBox = MotionBox()
        setUp(reducedBox)
        let reducedHost = component(Observing(box: reducedBox, make: make), theme: STTheme(motionMode: .reduced), size: size)
        let fullBox = MotionBox()
        setUp(fullBox)
        let fullHost = component(Observing(box: fullBox, make: make), theme: STTheme(), size: size)

        change(reducedBox)
        change(fullBox)
        #expect(sameImage(reducedHost.capture(), settled), "reduced: in its final state at once", sourceLocation: sourceLocation)
        #expect(!sameImage(fullHost.capture(), settled), "full motion: still moving", sourceLocation: sourceLocation)
    }

    @Test func theSwitchKnobJumps() {
        check(size: CGSize(width: 60, height: 34), change: { $0.isOn = true }) { box in
            STSwitch(isOn: Binding(get: { box.isOn }, set: { box.isOn = $0 }), label: "Crosshair")
        }
    }

    @Test func theSealIsSimplyThere() {
        check(size: CGSize(width: 40, height: 40), change: { $0.isOn = true }) { box in
            STSeal(isStamped: box.isOn)
        }
    }

    @Test func theSegmentedUnderlineJumps() {
        check(size: CGSize(width: 260, height: 34), change: { $0.choice = 2 }) { box in
            STSegmented(selection: Binding(get: { box.choice }, set: { box.choice = $0 }),
                        options: [STSegmentedOption(0, "Plus"), STSegmentedOption(1, "Dot"), STSegmentedOption(2, "Circle")])
        }
    }

    @Test func theSliderReadoutAndThumbMoveAtOnce() {
        check(size: CGSize(width: 320, height: 40), change: { $0.number = 95 }) { box in
            STSlider(value: Binding(get: { box.number }, set: { box.number = $0 }), in: 0...100, step: 5, label: "Volume")
                .labelsHidden()
        }
    }

    @Test func aTypedCharacterIsThereAtOnce() {
        check(size: CGSize(width: 200, height: 32), change: { $0.text = "ab" }) { box in
            STTextField("Name", text: Binding(get: { box.text }, set: { box.text = $0 }))
        }
    }

    @Test func theTypingOverlayStartsSettledWhileReduced() {
        let edit = TypingAnimationModel.diff(from: "a", to: "ab")
        let size = CGSize(width: 60, height: 24)
        let font = STFont.text(14)
        func render(_ edit: TypingEdit?, reduce: Bool) -> NSBitmapImageRep {
            component(STTypingText(text: "ab", edit: edit, font: font, color: STColor.ink, reduceMotion: reduce),
                      theme: reduce ? reduced : STTheme(), size: size).capture()
        }
        let settled = render(nil, reduce: true)
        #expect(sameImage(render(edit, reduce: true), settled))
        #expect(!sameImage(render(edit, reduce: false), settled), "full motion: the new glyph settles in")
    }

    @Test func theGiltRuleIsDrawnAtOnceUnderMacOSReduceMotion() {
        let size = CGSize(width: 120, height: 1)
        let drawn = component(STGiltRule(animatesIn: false), theme: STTheme(), size: size).capture()
        #expect(sameImage(component(STGiltRule(), theme: STTheme(systemReduceMotion: true), size: size).capture(), drawn))
        #expect(!sameImage(component(STGiltRule(), theme: STTheme(), size: size).capture(), drawn))
    }

    /// Found in the bug hunt: a rule that appeared while reduced was only drawn because of the theme, so turning
    /// Reduce animations off (on the Settings page, under its own gilt rule) made it vanish.
    @Test func aGiltRuleStaysDrawnWhenMotionComesBack() {
        let size = CGSize(width: 120, height: 1)
        let drawn = component(STGiltRule(animatesIn: false), theme: STTheme(), size: size).capture()
        let theme = STTheme(motionMode: .reduced)
        let hosted = component(STGiltRule(), theme: theme, size: size)
        #expect(sameImage(hosted.capture(), drawn))
        theme.motionMode = .full
        #expect(sameImage(hosted.capture(), drawn), "still drawn, not gone")
        theme.systemReduceMotion = true
        theme.systemReduceMotion = false
        #expect(sameImage(hosted.capture(), drawn))
    }

    @Test func theDisclosureOpensAtOnce() {
        let size = CGSize(width: 240, height: 90)
        func make(_ box: MotionBox) -> some View {
            STAdvancedDisclosure(isExpanded: Binding(get: { box.isOn }, set: { box.isOn = $0 })) {
                Color.white.frame(height: 40)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        let open = MotionBox()
        open.isOn = true
        let settled = component(make(open), theme: reduced, size: size).capture()

        let reducedBox = MotionBox()
        let reducedHost = component(make(reducedBox), theme: reduced, size: size)
        STMotion.animate(STMotion.standard, reduce: reduced.reduceMotion) { reducedBox.isOn = true }
        #expect(sameImage(reducedHost.capture(), settled))

        let fullBox = MotionBox()
        let fullHost = component(make(fullBox), theme: STTheme(), size: size)
        STMotion.animate(STMotion.standard, reduce: false) { fullBox.isOn = true }
        #expect(!sameImage(fullHost.capture(), settled))
    }
}
