import Foundation

/// Which build this is: the normal sTools, or the dev build (`scripts/build-app.sh --dev`), the copy to use day to day.
///
/// The dev build is the same app under another name: the same bundle identifier, signature, settings folder
/// (`~/Library/Application Support/sTools`) and defaults domain, so its settings, saved data and macOS permissions are
/// shared with the normal build. It is named "sTools Dev", has a blue icon, and has no update feed or key, so it never
/// updates itself into the normal build. Its Info.plist says so, under `STVariant`.
public enum AppVariant: Equatable, Sendable {
    case standard
    case dev

    /// The Info.plist key the dev build's marker is under; the normal build has none.
    public static let infoKey = "STVariant"
    private static let devMarker = "dev"

    /// What the Info.plist's `STVariant` says; anything but "dev" is the normal build.
    public init(marker: String?) {
        self = marker == Self.devMarker ? .dev : .standard
    }

    public init(bundle: Bundle = .main) {
        self.init(marker: bundle.object(forInfoDictionaryKey: Self.infoKey) as? String)
    }

    /// The running copy.
    public static var current: AppVariant { AppVariant() }

    /// The app's name in the menu bar, in Finder and in the app's own words about itself.
    public var name: String {
        switch self {
        case .standard: "sTools"
        case .dev: "sTools Dev"
        }
    }

    /// The other build.
    public var other: AppVariant { self == .dev ? .standard : .dev }
}
