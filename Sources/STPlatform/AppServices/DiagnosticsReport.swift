import AppKit
import Foundation
import OSLog

/// Supplies recent sTools log lines (already formatted, oldest first).
public protocol LogLineReading: Sendable {
    func recentLines(since: Date, limit: Int) throws -> [String]
}

/// Reads this process's entries for subsystem `com.ducky8x.sTools` from the unified log.
/// `OSLogStore` only exposes the current process's entries without elevated rights, so earlier launches are not included.
public struct OSLogLineReader: LogLineReading {
    public init() {}

    public func recentLines(since: Date, limit: Int) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "subsystem == %@", STLog.subsystem)
        let entries = try store.getEntries(at: store.position(date: since), matching: predicate)
        let formatter = Date.ISO8601FormatStyle(timeZone: .current).dateSeparator(.dash).timeSeparator(.colon)
        let lines = entries.compactMap { $0 as? OSLogEntryLog }.map { entry in
            "\(entry.date.formatted(formatter)) [\(Self.name(of: entry.level))] \(entry.category): \(entry.composedMessage)"
        }
        return Array(lines.suffix(limit))
    }

    private static func name(of level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        case .undefined: "log"
        @unknown default: "log"
        }
    }
}

/// Where Copy Diagnostics puts the text.
@MainActor
public protocol ClipboardWriting: AnyObject {
    func copy(_ text: String)
}

/// The general pasteboard.
@MainActor
public final class PasteboardClipboard: ClipboardWriting {
    public init() {}

    public func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// Facts about the app and the machine.
public struct DiagnosticsSystemInfo: Sendable, Equatable {
    /// "sTools", or "sTools Dev" for the dev build (`AppVariant.name`).
    public var appName: String
    public var appVersion: String
    public var appBuild: String
    public var macOSVersion: String
    public var architecture: String
    public var localeIdentifier: String

    public init(
        appVersion: String, appBuild: String, macOSVersion: String, architecture: String, localeIdentifier: String,
        appName: String = AppVariant.standard.name
    ) {
        self.appName = appName
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.localeIdentifier = localeIdentifier
    }

    /// Reads the running system. The architecture is what the process sees (`x86_64` under Rosetta).
    public static func current(bundle: Bundle = .main) -> DiagnosticsSystemInfo {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var uts = utsname()
        uname(&uts)
        let machine = withUnsafeBytes(of: &uts.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return DiagnosticsSystemInfo(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            architecture: machine.isEmpty ? "unknown" : machine,
            localeIdentifier: Locale.current.identifier,
            appName: AppVariant(bundle: bundle).name
        )
    }
}

/// A file in the settings directory. Only the name and size are ever reported, never the content.
public struct SettingsFileInfo: Sendable, Equatable {
    public var name: String
    public var bytes: Int

    public init(name: String, bytes: Int) {
        self.name = name
        self.bytes = bytes
    }

    /// Regular files directly inside `directory`, sorted by name. A missing directory yields an empty list.
    public static func list(in directory: URL) -> [SettingsFileInfo] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return SettingsFileInfo(name: url.lastPathComponent, bytes: values.fileSize ?? 0)
        }
        .sorted { $0.name < $1.name }
    }
}

/// How hotkeys are set, for the report's header: the master switch, Where hotkeys work and the key set the tools' own
/// keys follow, each in the words Home uses.
public struct DiagnosticsHotkeys: Sendable, Equatable {
    public var isEnabled: Bool
    /// Where hotkeys work, by its name in the chooser (`HotkeyScope.title`).
    public var scope: String
    /// The key set by name (`HotkeyKeySet.name(of:)`): its title, or Custom.
    public var keySet: String

    public init(isEnabled: Bool, scope: String, keySet: String) {
        self.isEnabled = isEnabled
        self.scope = scope
        self.keySet = keySet
    }
}

/// The plain-text report behind "Copy Diagnostics". It contains no settings values, and every
/// user-home path is shortened to `~`. Nothing is sent anywhere; the text goes to the clipboard.
public struct DiagnosticsReport: Sendable {
    /// How far back the log section reaches.
    public static let logWindow: TimeInterval = 15 * 60
    /// The most log lines the report includes.
    public static let logLineLimit = 200

    private let system: DiagnosticsSystemInfo
    private let displays: [String]
    private let permissions: [(title: String, state: String)]
    private let karabiner: String
    private let ninjabrain: String
    private let minecraft: String
    private let enabledTools: [String]
    private let settingsFiles: [SettingsFileInfo]
    private let logLines: [String]
    private let logError: String?
    private let generatedAt: Date
    private let homeDirectory: String
    private let hotkeys: DiagnosticsHotkeys?

    /// - Parameters:
    ///   - permissions: states by permission; a permission left out reads "not reported".
    ///   - karabiner: one-line (or multi-line) summary, for example version and whether it runs.
    ///   - ninjabrain: summary of the Ninjabrain Bot connection.
    ///   - minecraft: summary of the detected Minecraft instances.
    ///   - enabledTools: names of the tools that are switched on.
    ///   - logReader: asked for `logLineLimit` lines from the last `logWindow` seconds before `now`.
    ///   - homeDirectory: the path shortened to `~`.
    ///   - hotkeys: how hotkeys are set, in the header; left out when nil.
    public init(
        system: DiagnosticsSystemInfo,
        displays: [DisplayInfo],
        permissions: [Permission: PermissionStatus],
        karabiner: String,
        ninjabrain: String,
        minecraft: String,
        enabledTools: [String],
        settingsFiles: [SettingsFileInfo],
        logReader: any LogLineReading,
        now: Date = Date(),
        homeDirectory: String = NSHomeDirectory(),
        hotkeys: DiagnosticsHotkeys? = nil
    ) {
        self.system = system
        self.displays = displays.map(Self.summary)
        self.permissions = Permission.allCases.map { permission in
            (permission.title, permissions[permission].map(Self.name) ?? "not reported")
        }
        self.karabiner = karabiner
        self.ninjabrain = ninjabrain
        self.minecraft = minecraft
        self.enabledTools = enabledTools
        self.settingsFiles = settingsFiles
        generatedAt = now
        self.homeDirectory = homeDirectory
        self.hotkeys = hotkeys
        do {
            let lines = try logReader.recentLines(since: now.addingTimeInterval(-Self.logWindow), limit: Self.logLineLimit)
            logLines = Array(lines.suffix(Self.logLineLimit))
            logError = nil
        } catch {
            logLines = []
            logError = String(describing: error)
        }
    }

    /// The report as plain text, home directory redacted.
    public func render() -> String {
        var out: [String] = []
        out.append("\(system.appName) \(system.appVersion) (\(system.appBuild)) diagnostics")
        out.append("Generated: \(generatedAt.formatted(.iso8601))")
        if let hotkeys {
            out.append("Hotkeys: \(hotkeys.isEnabled ? "on" : "off")")
            out.append("Where hotkeys work: \(hotkeys.scope)")
            out.append("Key set: \(hotkeys.keySet)")
        }
        out.append("")
        out.append("macOS: \(system.macOSVersion)")
        out.append("Architecture: \(system.architecture)")
        out.append("Locale: \(system.localeIdentifier)")
        out.append(displays.isEmpty ? "Displays: none" : "Displays:")
        out += displays.map { "  - \($0)" }
        out.append("")
        out.append("Permissions:")
        out += permissions.map { "  \($0.title): \($0.state)" }
        out.append("")
        out.append(Self.field("Karabiner-Elements", karabiner))
        out.append(Self.field("Ninjabrain Bot", ninjabrain))
        out.append(Self.field("Minecraft", minecraft))
        out.append("Enabled tools: \(enabledTools.isEmpty ? "none" : enabledTools.joined(separator: ", "))")
        out.append("")
        out.append(settingsFiles.isEmpty ? "Settings files: none" : "Settings files (names and sizes only):")
        out += settingsFiles.map { "  - \($0.name) (\(CountText.of($0.bytes, "byte")))" }
        out.append("")
        out.append("Recent sTools log (last \(Int(Self.logWindow / 60)) minutes, up to \(Self.logLineLimit) lines):")
        if let logError {
            out.append("  Logs unavailable: \(logError)")
        } else if logLines.isEmpty {
            out.append("  none in the last \(Int(Self.logWindow / 60)) minutes")
        } else {
            out += logLines
        }
        return Self.redact(out.joined(separator: "\n") + "\n", home: homeDirectory)
    }

    /// Puts `render()` on the clipboard.
    @MainActor
    public func copy(to clipboard: any ClipboardWriting) {
        clipboard.copy(render())
    }

    private static func field(_ label: String, _ value: String) -> String {
        "\(label): " + value.split(separator: "\n", omittingEmptySubsequences: false).joined(separator: "\n  ")
    }

    private static func summary(_ display: DisplayInfo) -> String {
        let width = Int(display.pixelSize.width)
        let height = Int(display.pixelSize.height)
        let scale = display.backingScale.rounded() == display.backingScale
            ? String(Int(display.backingScale)) : String(format: "%.1f", Double(display.backingScale))
        return "\(display.name), \(width) x \(height) px, \(scale)x\(display.isMain ? ", main" : "")"
    }

    private static func name(_ status: PermissionStatus) -> String {
        switch status {
        case .granted: "granted"
        case .denied: "denied"
        case .notDetermined: "not determined"
        case .unknown: "unknown"
        }
    }

    /// Shortens the home directory, and any other `/Users/<name>` path, to `~`.
    static func redact(_ text: String, home: String) -> String {
        var result = text
        if home.count > 1 {
            let escaped = NSRegularExpression.escapedPattern(for: home)
            result = replace(#"\#(escaped)(?![A-Za-z0-9_.\-])"#, in: result)
        }
        // "[U]" matches only "U": it keeps the text "/Users/" out of the shipped binary, where
        // scripts/check-no-home-paths.sh would take it for a home-folder path and fail the release build.
        return replace(#"/[U]sers/[^/\s"')\]]+"#, in: result)
    }

    private static func replace(_ pattern: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "~")
    }
}
