import AppKit
import Foundation
import STDesign
import STPlatform
import SwiftUI
import Testing
@testable import Prologue

// Continue moves on only once the step is done (owner's report: "the skip step and continue do the same thing.
// continue should be grayed out if all the steps are not done or skipped"); Skip step always moves on. A trial's
// "All done" line and its Continue follow one condition: every item, optional ones included, is done or skipped.

@MainActor
@Suite("Prologue Continue")
struct PrologueContinueTests {
    private let crosshairItems = [
        ChecklistItem(id: "on", title: "Switch it on"),
        ChecklistItem(id: "shape", title: "Try another shape"),
        ChecklistItem(id: "image", title: "Use your own image", isOptional: true),
    ]

    /// The model holds its host weakly, so each test keeps its host in a local.
    private func makeModel(_ box: StoreBox = StoreBox(), host: FakeHost, at step: PrologueStep) -> PrologueModel {
        PrologueModel(store: box.store, host: host, startingAt: step, finaleDelay: .zero, finaleInterval: .milliseconds(1))
    }

    private func crosshairHost() -> FakeHost {
        let host = FakeHost()
        host.trialItems[.crosshair] = crosshairItems
        return host
    }

    // MARK: Checklist

    /// The owner's "one undone checkbox and it still says it's done": an optional item still to do kept the list
    /// from being complete only in name.
    @Test func anOptionalItemStillToDoKeepsTheListIncomplete() {
        var list = Checklist(items: crosshairItems)
        list.markDone(["on", "shape"])
        #expect(!list.isComplete, "the optional item is still to do")
        list.skip("image")
        #expect(list.isComplete)
    }

    @Test func anOptionalItemDoneCompletesTheList() {
        var list = Checklist(items: crosshairItems)
        list.markDone(["on", "shape", "image"])
        #expect(list.isComplete)
    }

    /// An item that can't be done right now has nothing to do or skip, so it never holds the list back.
    @Test func anUnavailableItemNeverHoldsTheListBack() {
        var list = Checklist(items: crosshairItems + [ChecklistItem(id: "rebind", title: "Make a rebind", isOptional: true,
                                                                   unavailableReason: "Needs Karabiner-Elements")])
        list.markDone(["on", "shape"])
        list.skip("image")
        list.skip("rebind")
        #expect(list.state(of: "rebind") == .unavailable)
        #expect(list.isComplete)
    }

    @Test func anEmptyListIsComplete() {
        #expect(Checklist().isComplete)
    }

    // MARK: Trials

    @Test func continueWaitsUntilEveryTrialItemIsDoneOrSkipped() {
        let host = crosshairHost()
        let model = makeModel(host: host, at: .crosshairTrial)
        #expect(!model.canContinue)
        model.record(done: ["on"], items: crosshairItems, for: .crosshair)
        #expect(!model.canContinue)
        model.skipItem("shape", items: crosshairItems, in: .crosshair)
        #expect(!model.canContinue, "the optional item is still to do")
        model.skipItem("image", items: crosshairItems, in: .crosshair)
        #expect(model.canContinue)
        model.next()
        #expect(model.step == .timerTrial)
    }

    /// Return presses Continue, so while Continue is grayed out it moves nothing either.
    @Test func continueDoesNothingWhileTheTrialIsUnfinished() {
        let box = StoreBox()
        let host = crosshairHost()
        let model = makeModel(box, host: host, at: .crosshairTrial)
        model.record(done: ["on", "shape"], items: crosshairItems, for: .crosshair)
        model.next()
        #expect(model.step == .crosshairTrial)
        #expect(box.store.load(AppState.self).prologueStep == PrologueStep.crosshairTrial.rawValue)
    }

    @Test func skipStepAlwaysMovesOn() {
        let host = crosshairHost()
        let model = makeModel(host: host, at: .crosshairTrial)
        #expect(!model.canContinue)
        model.skipStep()
        #expect(model.step == .timerTrial)
        #expect(model.flow.skippedSteps == [.crosshairTrial])
    }

    /// The "All done" line and Continue read the same condition, and it turns true with the last item, not before.
    @Test(arguments: [false, true])
    func allDoneComesWithTheLastItem(lastIsSkipped: Bool) {
        let host = crosshairHost()
        let model = makeModel(host: host, at: .crosshairTrial)
        model.record(done: ["on"], items: crosshairItems, for: .crosshair)
        model.skipItem("shape", items: crosshairItems, in: .crosshair)
        #expect(!model.isTrialComplete(.crosshair))
        #expect(!model.checklist(for: .crosshair, items: crosshairItems).isComplete)
        if lastIsSkipped {
            model.skipItem("image", items: crosshairItems, in: .crosshair)
        } else {
            model.record(done: ["image"], items: crosshairItems, for: .crosshair)
        }
        #expect(model.isTrialComplete(.crosshair))
        #expect(model.checklist(for: .crosshair, items: crosshairItems).isComplete)
        #expect(model.canContinue)
    }

    /// A trial with nothing on its list (no tool to try) has nothing to finish.
    @Test func aTrialWithNoItemsCanContinue() {
        let host = FakeHost()
        let model = makeModel(host: host, at: .backdropTrial)
        #expect(model.canContinue)
    }

    // MARK: Preparations

    @Test func aPermissionStepContinuesOnceReady() {
        let host = FakeHost()
        let model = makeModel(host: host, at: .accessibility)
        #expect(!model.canContinue)
        model.next()
        #expect(model.step == .accessibility)
        host.prober.set(.accessibility, .granted)
        host.permissions.refresh()
        #expect(model.canContinue)
        model.next()
        #expect(model.step == .screenRecording)
    }

    @Test(arguments: [PrologueStep.accessibility, .screenRecording, .appAudio, .microphone, .camera])
    func everyPermissionStepWaitsForItsOwnPermission(step: PrologueStep) throws {
        let host = FakeHost()
        let permission = try #require(step.permission)
        for other in Permission.allCases where other != permission { host.prober.set(other, .granted) }
        host.permissions.refresh()
        let model = makeModel(host: host, at: step)
        #expect(!model.canContinue)
        host.prober.set(permission, .granted)
        host.permissions.refresh()
        #expect(model.canContinue)
    }

    @Test(arguments: [PrologueCompanion.ninjabrainBot, .karabiner])
    func aCompanionStepContinuesOnceReady(companion: PrologueCompanion) async {
        let host = FakeHost()
        let step: PrologueStep = companion == .ninjabrainBot ? .ninjabrainBot : .karabiner
        let model = makeModel(host: host, at: step)
        await model.refresh(companion)
        #expect(!model.canContinue)
        model.next()
        #expect(model.step == step)
        host.companionStatuses[companion] = .ready
        await model.refresh(companion)
        #expect(model.canContinue)
        model.next()
        #expect(model.step == step.following)
    }

    @Test(arguments: PrologueStep.allCases.filter { $0.part == .preparations })
    func skipStepMovesOnFromEveryPreparation(step: PrologueStep) {
        let host = FakeHost()
        let model = makeModel(host: host, at: step)
        #expect(!model.canContinue)
        model.skipStep()
        #expect(model.step == step.following)
    }

    /// The greeting's Begin, the Finale's Continue and Open sTools have nothing to finish first.
    @Test(arguments: [PrologueStep.greeting, .youreSet, .openSTools])
    func stepsWithNothingToDoContinue(step: PrologueStep) {
        let host = FakeHost()
        #expect(makeModel(host: host, at: step).canContinue)
    }

    @Test func nothingContinuesWhileTheSkipQuestionShows() {
        let host = FakeHost()
        let model = makeModel(host: host, at: .youreSet)
        model.requestSkipIntroduction()
        #expect(!model.canContinue)
    }

    // MARK: Saved progress

    /// A trial resumed from `appState.json` starts with Continue grayed out again, and Skip step saves the next step.
    @Test func aResumedTrialWaitsAndSkipsAsBefore() async {
        let box = StoreBox()
        let host = crosshairHost()
        let first = makeModel(box, host: host, at: .crosshairTrial)
        #expect(!first.canContinue)
        await box.store.flush()

        let reopened = box.reopened()
        let relaunchedHost = crosshairHost()
        let relaunched = PrologueModel(store: reopened, host: relaunchedHost)
        #expect(relaunched.step == .crosshairTrial)
        #expect(!relaunched.canContinue)
        relaunched.next()
        #expect(relaunched.step == .crosshairTrial)
        relaunched.skipStep()
        #expect(relaunched.step == .timerTrial)
        await reopened.flush()
        #expect(box.reopened().load(AppState.self).prologueStep == PrologueStep.timerTrial.rawValue)
    }

    @Test func aStepContinuedFromIsSavedAndResumed() async {
        let box = StoreBox()
        let host = FakeHost()
        host.prober.set(.camera, .granted)
        host.permissions.refresh()
        let model = makeModel(box, host: host, at: .camera)
        model.next()
        #expect(model.step == .ninjabrainBot)
        await box.store.flush()
        #expect(PrologueModel(store: box.reopened(), host: FakeHost()).step == .ninjabrainBot)
    }

    // MARK: The footer

    /// In the real view, Return presses Continue only once the trial is done: while an item is left it moves nothing.
    @Test func returnMovesOnOnlyOnceTheTrialIsDone() {
        let host = crosshairHost()
        let model = makeModel(host: host, at: .crosshairTrial)
        let window = KeyWindow(PrologueView(model: model))
        model.record(done: ["on", "shape"], items: crosshairItems, for: .crosshair)
        window.settle()
        window.pressReturn()
        #expect(model.step == .crosshairTrial, "one item is still to do")
        model.skipItem("image", items: crosshairItems, in: .crosshair)
        window.settle()
        window.pressReturn()
        #expect(model.step == .timerTrial)
    }

    /// The control: on a step with nothing to do, the same Return moves on, so the check above isn't vacuous.
    @Test func returnMovesOnFromAStepWithNothingToDo() {
        let host = FakeHost()
        let model = makeModel(host: host, at: .backdropTrial)
        let window = KeyWindow(PrologueView(model: model))
        window.pressReturn()
        #expect(model.step == .keyRebinderTrial)
    }
}

/// A window that's never ordered in, with the view under Reduce animations so no key goes to completing one.
@MainActor
private final class KeyWindow {
    let window: NSWindow
    let host: NSHostingView<AnyView>

    init<V: View>(_ view: V) {
        _ = NSApplication.shared
        let theme = STTheme(motionMode: .reduced)
        host = NSHostingView(rootView: AnyView(view.stMotionRoot(theme).environment(\.stTheme, theme)))
        host.frame = CGRect(x: 0, y: 0, width: 760, height: 560)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        settle()
    }

    isolated deinit {
        window.contentView = nil
    }

    func settle() {
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        host.layoutSubtreeIfNeeded()
    }

    func pressReturn() {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36)!
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
        settle()
    }
}
