/// Why an edit to the Karabiner configuration was refused. The configuration passed in is never modified.
public enum EditError: Error, Equatable, Sendable {
    case profileNotFound(String)
    /// A node the edit has to change exists but has the wrong shape (for example `simple_modifications` is not an array).
    case malformedConfig(String)
    case ruleIndexOutOfRange(Int)
    case profileIndexOutOfRange(Int)
    /// Function key numbers run from 1 to 12.
    case invalidFunctionKey(Int)
    case emptyProfileName
    case profileNameTaken(String)
    case cannotDeleteSelectedProfile(String)
}
