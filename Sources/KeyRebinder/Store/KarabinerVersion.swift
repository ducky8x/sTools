import Foundation

/// A Karabiner-Elements version such as `16.3.0` or `15.9.0-beta`. Only the numeric part takes part in comparisons.
public struct KarabinerVersion: Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// Whatever followed the numbers (`-beta`), or empty.
    public var suffix: String

    /// The oldest version sTools supports (spec 5.5.1).
    public static let minimumSupported = KarabinerVersion(major: 16, minor: 0, patch: 0)

    public init(major: Int, minor: Int = 0, patch: Int = 0, suffix: String = "") {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.suffix = suffix
    }

    /// Reads `16`, `16.3`, `16.3.0`, `v16.3.0` or `15.9.0-beta` (surrounding whitespace is ignored);
    /// `nil` when the text does not start with a number.
    public init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        var numbers: [Int] = []
        while numbers.count < 3 {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let number = Int(digits) else { break }
            numbers.append(number)
            rest = rest.dropFirst(digits.count)
            guard rest.first == ".", numbers.count < 3 else { break }
            let afterDot = rest.dropFirst()
            guard afterDot.first?.isASCII == true, afterDot.first?.isNumber == true else { break }
            rest = afterDot
        }
        guard let major = numbers.first else { return nil }
        self.init(
            major: major, minor: numbers.count > 1 ? numbers[1] : 0, patch: numbers.count > 2 ? numbers[2] : 0,
            suffix: String(rest)
        )
    }

    public var description: String {
        "\(major).\(minor).\(patch)\(suffix)"
    }

    /// True when this version's numbers are at least `other`'s; suffixes such as `-beta` are ignored.
    public func isAtLeast(_ other: KarabinerVersion) -> Bool {
        (major, minor, patch) >= (other.major, other.minor, other.patch)
    }
}
