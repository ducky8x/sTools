/// What the app needs from every tool module: a way to switch it on or off and to read its state.
/// The app owns the user-facing switch; the tool does the work behind it.
@MainActor
public protocol ToolController: AnyObject {
    /// Whether the tool is currently running.
    var isEnabled: Bool { get }

    /// Starts or stops the tool. Must be safe to call repeatedly with the same value.
    func setEnabled(_ enabled: Bool)
}
