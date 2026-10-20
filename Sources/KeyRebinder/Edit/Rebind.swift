/// One Simple Modifications entry: `from` is sent as `to`.
public struct Rebind: Hashable, Sendable {
    public var from: KarabinerEvent
    /// A multi-event or unusual `to` list is `.other`, kept verbatim (see `KarabinerEvent.isPlainEvent`).
    public var to: KarabinerEvent
    public var scope: RebindScope
    /// True when a later entry with the same `from` takes over, so this one never applies.
    public var isOverridden: Bool

    public init(from: KarabinerEvent, to: KarabinerEvent, scope: RebindScope, isOverridden: Bool = false) {
        self.from = from
        self.to = to
        self.scope = scope
        self.isOverridden = isOverridden
    }
}
