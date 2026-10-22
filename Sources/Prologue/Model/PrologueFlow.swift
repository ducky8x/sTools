/// The Prologue's navigation as a pure value (spec 4.1, 9.1): Continue, Back, Skip step, Skip introduction with
/// its confirmation, and Replay. Nothing here touches the system, so "back never undoes" is simply true: the flow
/// only moves between pages.
public struct PrologueFlow: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Open sTools was pressed on the last step.
        case finished
        /// Skip introduction was confirmed.
        case skipped
    }

    public private(set) var step: PrologueStep
    public private(set) var direction: PageDirection = .forward
    /// The "Skip the introduction?" question is showing; every other control waits for its answer.
    public private(set) var isConfirmingSkip = false
    public private(set) var outcome: Outcome?
    /// Steps left with Skip step and not done since.
    public private(set) var skippedSteps: Set<PrologueStep> = []
    /// Bumped on every page turn, so a step shown again (Back, then Continue) is a fresh page.
    public private(set) var visit = 0

    /// Starts at a saved step index (spec D14: resume at the same step); out-of-range indices start at the greeting.
    public init(resumingAt index: Int = 0) {
        step = PrologueStep(savedIndex: index)
    }

    public var isEnded: Bool { outcome != nil }
    public var isLastStep: Bool { step == PrologueStep.allCases.last }

    /// Back works from every step but the greeting.
    public var canGoBack: Bool { !isEnded && !isConfirmingSkip && step != .greeting }
    public var canMoveOn: Bool { !isEnded && !isConfirmingSkip }

    /// How much of the gold progress rule is filled: a sixteenth per step, full on the last.
    public var progress: Double { Double(step.number) / Double(PrologueStep.count) }

    /// Continue: the next step, or the end after the last one.
    @discardableResult
    public mutating func next() -> Bool {
        guard canMoveOn else { return false }
        skippedSteps.remove(step)
        return advance()
    }

    /// Skip step: moves on without doing the step.
    @discardableResult
    public mutating func skipStep() -> Bool {
        guard canMoveOn else { return false }
        skippedSteps.insert(step)
        return advance()
    }

    /// Back: the previous step, any number of times, back to the greeting.
    @discardableResult
    public mutating func back() -> Bool {
        guard canGoBack, let previous = PrologueStep(rawValue: step.rawValue - 1) else { return false }
        turn(to: previous, direction: .backward)
        return true
    }

    /// Esc: asks first (spec D11).
    public mutating func requestSkipIntroduction() {
        guard !isEnded else { return }
        isConfirmingSkip = true
    }

    public mutating func confirmSkipIntroduction() {
        guard isConfirmingSkip else { return }
        isConfirmingSkip = false
        outcome = .skipped
    }

    public mutating func cancelSkipIntroduction() {
        isConfirmingSkip = false
    }

    /// Replay Introduction: from the greeting (spec D13), with nothing carried over.
    public mutating func restart() {
        self = PrologueFlow()
    }

    private mutating func advance() -> Bool {
        guard let following = PrologueStep(rawValue: step.rawValue + 1) else {
            outcome = .finished
            return true
        }
        turn(to: following, direction: .forward)
        return true
    }

    private mutating func turn(to newStep: PrologueStep, direction newDirection: PageDirection) {
        step = newStep
        direction = newDirection
        visit += 1
    }
}
