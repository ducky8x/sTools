/// The reconnect backoff spec 5.1.2 calls for: start at 0.5 s, double up to a 5 s ceiling, and any
/// dispatched event resets it back to the start. Pure so the progression can be pinned down directly.
enum NBBBackoff {
    static let initialSeconds: Double = 0.5
    static let maximumSeconds: Double = 5

    static func next(afterSeconds current: Double) -> Double {
        min(current * 2, maximumSeconds)
    }
}
