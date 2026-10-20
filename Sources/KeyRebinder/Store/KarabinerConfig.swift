import Foundation

/// One entry of the `profiles` array in `karabiner.json`.
public struct KarabinerProfile: Hashable, Sendable {
    /// The profile's `name` (empty when missing, as Karabiner treats it).
    public var name: String
    /// The profile's `selected` flag (false when missing).
    public var isSelected: Bool
    /// The whole profile object, with every key Karabiner wrote.
    public var json: JSONValue

    public init(json: JSONValue) {
        self.json = json
        name = json["name"]?.stringValue ?? ""
        isSelected = json["selected"]?.boolValue ?? false
    }
}

/// A parsed `karabiner.json`: the order-preserving tree plus typed read access to its profiles.
public struct KarabinerConfig: Hashable, Sendable {
    /// The complete document. Edits are made on this tree and written back unchanged apart from the edit.
    public let root: JSONValue
    /// True when the file on disk had comments, which Karabiner (and sTools) drop on the next save.
    public let containsComments: Bool

    public init(root: JSONValue, containsComments: Bool = false) {
        self.root = root
        self.containsComments = containsComments
    }

    /// The profiles in file order; empty when the file has no `profiles` array.
    public var profiles: [KarabinerProfile] {
        (root["profiles"]?.arrayValue ?? []).map(KarabinerProfile.init(json:))
    }

    /// The profile Karabiner uses: the first one marked `selected`, else the first one. `nil` without profiles.
    public var selectedProfileName: String? {
        let all = profiles
        return (all.first { $0.isSelected } ?? all.first)?.name
    }
}
