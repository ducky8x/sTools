/// A count with its noun, in the singular for exactly one and the plural otherwise (zero included): "1 frame",
/// "3 frames", "0 frames". Every count sTools shows in words goes through it, so none reads "1 frames".
public enum CountText {
    /// `plural` defaults to `singular` plus "s".
    public static func of(_ count: Int, _ singular: String, plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : plural ?? singular + "s")"
    }

    /// The same, followed by the verb that agrees with it: "1 frame was", "4 frames were".
    public static func of(_ count: Int, _ singular: String, plural: String? = nil, verb: (singular: String, plural: String)) -> String {
        "\(of(count, singular, plural: plural)) \(count == 1 ? verb.singular : verb.plural)"
    }
}
