import os

/// A handler that can be set, cleared and called from any thread, such as the one a capture source calls for every
/// frame or sound buffer.
///
/// Why not keep the closure as a lock's own state (`OSAllocatedUnfairLock<((Value) -> Void)?>`, a `Mutex` of one, and
/// so on): `withLock` hands its state to the body `inout` through a generic parameter, so a function-typed state is
/// converted to the generic form and back on every access and written back wrapped in one more reabstraction thunk.
/// Each read makes the next call go through one more thunk: the call cost grows with every frame, and a capture
/// queue's thread dies of a stack overflow (SIGBUS) after a few thousand. Here the lock holds a class reference, which
/// needs no conversion, and the closure inside it is stored once and never rewritten, so every call costs the same.
/// The handler is called outside the lock.
public final class HandlerSlot<Value>: @unchecked Sendable {
    /// The closure, stored once.
    private final class Handler: @unchecked Sendable {
        let call: @Sendable (Value) -> Void
        init(_ call: @escaping @Sendable (Value) -> Void) { self.call = call }
    }

    private let handler = OSAllocatedUnfairLock<Handler?>(uncheckedState: nil)

    public init() {}

    /// Replaces any handler set before.
    public func set(_ handler: @escaping @Sendable (Value) -> Void) {
        let boxed = Handler(handler)
        self.handler.withLockUnchecked { $0 = boxed }
    }

    /// Lets go of the handler; true if one was set.
    @discardableResult
    public func clear() -> Bool {
        let cleared = handler.withLockUnchecked { handler in
            defer { handler = nil }
            return handler
        }
        return cleared != nil
    }

    public var isSet: Bool { handler.withLockUnchecked { $0 != nil } }

    /// Calls the handler, if one is set.
    public func callAsFunction(_ value: Value) {
        handler.withLockUnchecked { $0 }?.call(value)
    }
}
