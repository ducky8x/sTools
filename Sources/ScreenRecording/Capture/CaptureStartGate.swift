import Foundation
import os

/// A capture source's start against its stop. Every real source starts across awaits (ScreenCaptureKit's window list
/// and `startCapture`, a camera's or microphone's session on its queue, a browser page's window, a process tap that
/// waits for the app's first sound), and the tool can be switched off, or a start canceled by the key, in the middle.
/// The stop wins: once `close()` is called the gate stays closed, a start calls `check()` after each await and leaves
/// off there, and it ends with `finish(tearDown:)`, which takes down whatever it brought up if the stop came while it
/// ran. The source's stop calls `close()` before it tears anything down, so either the stop finds everything the
/// start brought up, or the start's `finish` sees the stop.
final class CaptureStartGate: Sendable {
    private let closed = OSAllocatedUnfairLock(initialState: false)

    /// Whether the source's stop came.
    var isClosed: Bool { closed.withLock { $0 } }

    /// The stop: from now on, every start leaves off. Closing again changes nothing.
    func close() {
        closed.withLock { $0 = true }
    }

    /// Throws `CancellationError` once the stop came, so the start leaves off before bringing anything more up.
    func check() throws {
        if isClosed { throw CancellationError() }
    }

    /// The last step of a start, once everything it brings up is stored where the stop finds it: when the stop came
    /// meanwhile (and so may have found some of it not yet there), `tearDown` takes it all down and the start throws
    /// `CancellationError`.
    func finish(tearDown: () async -> Void) async throws {
        guard isClosed else { return }
        await tearDown()
        throw CancellationError()
    }
}
