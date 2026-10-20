import Foundation

/// Where STDesign's bundled resources live. Inside a packaged app the SwiftPM resource bundle sits in
/// Contents/Resources; during `swift test`/`swift run` it sits next to the executable.
public enum STResources {
    static let bundleName = "sTools_STDesign.bundle"

    public static let bundle: Bundle = {
        if let url = locate(mainResourceURL: Bundle.main.resourceURL), let packaged = Bundle(url: url) {
            return packaged
        }
        return Bundle.module
    }()

    /// The resource bundle inside `mainResourceURL` (`Contents/Resources` of an app, or the executable's folder
    /// for a SwiftPM build), or `nil` when it isn't there and `Bundle.module` must be used instead.
    static func locate(mainResourceURL: URL?, fileManager: FileManager = .default) -> URL? {
        guard let candidate = mainResourceURL?.appendingPathComponent(bundleName, isDirectory: true) else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return candidate
    }
}
