import Foundation

/// The first thing keeping the Key Rebinder from editing, or `.ready` (spec 5.5.7).
public enum KarabinerRequirement: Equatable, Sendable {
    case ready
    /// `/Applications/Karabiner-Elements.app` is missing.
    case notInstalled
    /// `karabiner_cli --version` did not answer with a version.
    case notRunning
    /// The installed version is older than 16.0; `found` is what it reported.
    case versionTooOld(found: String)
    /// `karabiner.json` is missing, unreadable or not valid JSON.
    case configUnreadable

    public var isReady: Bool { self == .ready }

    /// One sentence telling the user how to fix it; empty for `.ready`.
    public var fixText: String {
        switch self {
        case .ready:
            ""
        case .notInstalled:
            "Install Karabiner-Elements 16.0 or later from karabiner-elements.pqrs.org, then check again."
        case .notRunning:
            "Open Karabiner-Elements and finish its setup, then check again."
        case .versionTooOld(let found):
            "Update Karabiner-Elements to 16.0 or later (this Mac has \(found)), then check again."
        case .configUnreadable:
            "Open Karabiner-Elements once so it can create or repair its settings file, then check again."
        }
    }
}

/// The facts the status check reads, injected so the check itself is pure.
public struct KarabinerProbes: Sendable {
    public var appBundleExists: @Sendable () -> Bool
    /// What `karabiner_cli --version` printed, or `nil` when it did not answer.
    public var cliVersion: @Sendable () async -> String?
    public var configReadable: @Sendable () -> Bool

    public init(
        appBundleExists: @escaping @Sendable () -> Bool,
        cliVersion: @escaping @Sendable () async -> String?,
        configReadable: @escaping @Sendable () -> Bool
    ) {
        self.appBundleExists = appBundleExists
        self.cliVersion = cliVersion
        self.configReadable = configReadable
    }

    public static let defaultAppURL = URL(fileURLWithPath: "/Applications/Karabiner-Elements.app")

    /// Probes against the real machine: the app bundle at `appURL`, the CLI through `cli`, and a config file
    /// that must exist and parse as a JSON object.
    public static func live(
        cli: KarabinerCLI,
        configURL: URL = KarabinerConfigStore.defaultConfigURL(),
        appURL: URL = KarabinerProbes.defaultAppURL
    ) -> KarabinerProbes {
        KarabinerProbes(
            appBundleExists: { FileManager.default.fileExists(atPath: appURL.path) },
            cliVersion: { try? await cli.version() },
            configReadable: {
                guard let data = try? Data(contentsOf: configURL), let root = try? JSONValue.parse(data: data) else {
                    return false
                }
                return root.isObject
            }
        )
    }
}

/// Checks installed → running → version ≥ 16.0 → config readable, in that order.
public struct KarabinerStatus: Sendable {
    private let probes: KarabinerProbes

    public init(probes: KarabinerProbes) {
        self.probes = probes
    }

    /// The first requirement that fails; later probes are not run once one fails.
    public func evaluate() async -> KarabinerRequirement {
        guard probes.appBundleExists() else { return .notInstalled }
        guard let text = await probes.cliVersion(), let version = KarabinerVersion(text) else { return .notRunning }
        guard version.isAtLeast(.minimumSupported) else { return .versionTooOld(found: text) }
        guard probes.configReadable() else { return .configUnreadable }
        return .ready
    }
}
