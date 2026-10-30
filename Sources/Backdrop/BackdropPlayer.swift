import QuartzCore

/// Plays one animated fill's file, looped and muted (spec 5.2.3), into a layer. There are two: a GIF's frames drawn one
/// by one, and a video played by AVFoundation (its hardware decoder). Both start paused and do nothing until `play()`;
/// nothing runs, polls or holds a timer while they're paused or stopped.
@MainActor
protocol BackdropPlayer: AnyObject {
    /// The layer the picture appears in. Its host sizes and places it by `naturalSize` and the fit mode.
    var mediaLayer: CALayer { get }
    /// The picture's size in pixels, once the file has been opened.
    var naturalSize: CGSize? { get }
    /// A plain line saying why the file can't be played, once that is known.
    var failure: String? { get }
    /// Calls `handler` when `naturalSize` or `failure` first becomes known. Any number of handlers may ask.
    func observe(_ handler: @escaping @MainActor () -> Void)
    /// Starts, or resumes from where it paused. Safe to call again.
    func play()
    /// Stops at the picture on screen and releases the timer. Safe to call again.
    func pause()
    /// Lets everything go: decoded frames, the player, the file. It can't play again.
    func stop()
}

/// The handlers a player tells when it learns something about its file.
@MainActor
struct BackdropPlayerObservers {
    private var handlers: [@MainActor () -> Void] = []

    mutating func add(_ handler: @escaping @MainActor () -> Void) { handlers.append(handler) }
    mutating func removeAll() { handlers.removeAll() }
    func notify() { for handler in handlers { handler() } }
}

enum BackdropPlayerMessages {
    /// Said on the page when a file that was chosen can't be played any more (moved, deleted, damaged).
    static let cantPlay = "sTools can\u{2019}t play this file. Choose another one."
}

/// Stands in for a file that isn't there or can't be opened at all: it has failed from the start and does nothing.
@MainActor
final class BackdropFailedPlayer: BackdropPlayer {
    let mediaLayer = CALayer()
    let naturalSize: CGSize? = nil
    let failure: String? = BackdropPlayerMessages.cantPlay
    func observe(_ handler: @escaping @MainActor () -> Void) {}
    func play() {}
    func pause() {}
    func stop() {}
}
