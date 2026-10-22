import Foundation

/// A count with its noun in the right number, for the app's English text: "1 item", "3 items", "0 items".
public enum CountWording {
    /// `count` and `singular`, or `plural` (by default `singular` plus "s") for any count but 1.
    public static func counted(_ count: Int, _ singular: String, plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : plural ?? singular + "s")"
    }
}
