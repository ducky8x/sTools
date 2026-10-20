/// Reads and requests permissions. The real implementation is ``SystemPermissionProber``;
/// tests substitute a fake so no system prompt ever appears.
public protocol PermissionProbing: Sendable {
    /// The current status, without prompting.
    func status(for permission: Permission) -> PermissionStatus

    /// Asks the system for the permission (showing its prompt when it has one) and returns the outcome.
    /// A later `status(for:)` call must agree with the returned value whenever the system can report it.
    func request(_ permission: Permission) async -> PermissionStatus
}
