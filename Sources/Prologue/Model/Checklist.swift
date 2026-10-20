/// One thing to try in a trial ("Try another shape").
public struct ChecklistItem: Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    /// A short hint under the title, when the title alone isn't enough.
    public var detail: String?
    /// Shown as optional; never needed for the trial to count as complete.
    public var isOptional: Bool
    /// Why the item can't be done right now ("Needs Karabiner-Elements"); nil when it can.
    public var unavailableReason: String?

    public init(id: String, title: String, detail: String? = nil, isOptional: Bool = false, unavailableReason: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isOptional = isOptional
        self.unavailableReason = unavailableReason
    }
}

public enum ChecklistItemState: Equatable, Sendable {
    case pending, done, skipped, unavailable
}

/// A trial's checklist (spec 4.2): items tick themselves as the user does them and stay ticked; each can be
/// skipped. Done wins over skipped, so doing a skipped item still ticks it.
public struct Checklist: Equatable, Sendable {
    public private(set) var items: [ChecklistItem]
    public private(set) var done: Set<String> = []
    public private(set) var skipped: Set<String> = []

    public init(items: [ChecklistItem] = []) {
        self.items = items
    }

    /// Replaces the item list (availability can change while the step shows); ticks and skips are kept by id.
    public mutating func update(items newItems: [ChecklistItem]) {
        items = newItems
    }

    /// Ticks every listed id that is an available item. Returns the ids that were newly ticked.
    @discardableResult
    public mutating func markDone(_ ids: Set<String>) -> Set<String> {
        let available = Set(items.filter { $0.unavailableReason == nil }.map(\.id))
        let fresh = ids.intersection(available).subtracting(done)
        done.formUnion(fresh)
        skipped.subtract(fresh)
        return fresh
    }

    /// Skips a pending item.
    public mutating func skip(_ id: String) {
        guard state(of: id) == .pending else { return }
        skipped.insert(id)
    }

    public func state(of id: String) -> ChecklistItemState {
        if done.contains(id) { return .done }
        if items.first(where: { $0.id == id })?.unavailableReason != nil { return .unavailable }
        if skipped.contains(id) { return .skipped }
        return .pending
    }

    /// Every required, available item is done or skipped.
    public var isComplete: Bool {
        items.allSatisfy { item in
            item.isOptional || [.done, .skipped, .unavailable].contains(state(of: item.id))
        }
    }

    public var doneCount: Int { items.filter { state(of: $0.id) == .done }.count }
}
