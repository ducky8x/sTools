import Foundation

enum FixtureLoader {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures", directoryHint: .isDirectory)

    static func text(_ name: String) -> String {
        let url = directory.appending(path: "\(name).json")
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            fatalError("missing fixture \(name)")
        }
        return text
    }

    static let names = ["minimal", "typical", "future-keys"]
}
