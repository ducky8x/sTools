import Foundation

/// Where the user is in the first-run introduction (the Prologue). Stored as `appState.json`.
/// Deleting the file (what `ResetService` does) means "never started".
public struct AppState: SettingsDocument {
    public static let name = "appState"
    public static let version = 1
    public static let defaultValue = AppState(prologueCompleted: false, prologueStep: 0)

    /// True once the user finished or skipped the introduction.
    public var prologueCompleted: Bool
    /// Index of the step to resume at while the introduction is unfinished.
    public var prologueStep: Int

    public init(prologueCompleted: Bool = false, prologueStep: Int = 0) {
        self.prologueCompleted = prologueCompleted
        self.prologueStep = prologueStep
    }

    private enum CodingKeys: String, CodingKey {
        case prologueCompleted, prologueStep
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prologueCompleted = try container.decodeIfPresent(Bool.self, forKey: .prologueCompleted) ?? false
        prologueStep = try container.decodeIfPresent(Int.self, forKey: .prologueStep) ?? 0
    }
}
