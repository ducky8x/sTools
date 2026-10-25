import AppKit
import Darwin
import Foundation
import Observation
import Security
import UniformTypeIdentifiers

/// Updates sTools from a DMG someone downloaded (spec 6.3): the first time they drag sTools into Applications; after
/// that they hand the next DMG to Settings ▸ Updates ▸ Install from DMG… (or the app menu), and sTools replaces itself
/// with the copy inside and opens again.
///
/// The copy inside must be sTools (same bundle identifier), signed by the same certificate as the running copy, and a
/// newer build; an older build installs only after the person confirms, the same build not at all. Nothing on the disk
/// changes until every check has passed, and the installed copy is swapped for the new one in one step.
@MainActor
@Observable
final class DMGInstaller {
    enum Phase: Equatable {
        case idle
        case checking
        /// The DMG holds an older build; installing it waits for the person to confirm.
        case confirmOlder(dmg: URL, found: AppVersion)
        case installing
        /// Installed; sTools is about to quit and open the new copy.
        case installed(AppVersion)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    @ObservationIgnored private let installedApp: URL
    @ObservationIgnored private let running: AppVersion
    @ObservationIgnored private let bundleIdentifier: String?
    @ObservationIgnored private let mounter: any DiskImageMounting
    @ObservationIgnored private let signatures: any AppSignatureChecking
    @ObservationIgnored private let relaunch: @MainActor () -> Void

    init(
        installedApp: URL = Bundle.main.bundleURL,
        running: AppVersion = AppVersion(),
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        mounter: any DiskImageMounting = HdiutilMounter(),
        signatures: any AppSignatureChecking = CodeSignatureChecker(),
        relaunch: @escaping @MainActor () -> Void = { AppRelauncher.relaunch() }
    ) {
        self.installedApp = installedApp
        self.running = running
        self.bundleIdentifier = bundleIdentifier
        self.mounter = mounter
        self.signatures = signatures
        self.relaunch = relaunch
    }

    var isBusy: Bool { phase == .checking || phase == .installing }

    /// Asks for a DMG, then installs from it.
    func chooseAndInstall() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Install sTools from a DMG"
        panel.prompt = "Install"
        panel.allowedContentTypes = [.diskImage]
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await install(from: url) }
    }

    /// Installs the sTools inside `dmg`. `allowingOlder` is set when the person confirmed an older build.
    func install(from dmg: URL, allowingOlder: Bool = false) async {
        guard !isBusy else { return }
        phase = .checking
        let mountPoint: URL
        do {
            mountPoint = try await mounter.attach(dmg)
        } catch {
            phase = .failed("This file couldn\u{2019}t be opened as a disk image.")
            return
        }
        let outcome = await installMounted(dmg: dmg, mountPoint: mountPoint, allowingOlder: allowingOlder)
        await mounter.detach(mountPoint)
        phase = outcome
        if case .installed = outcome { relaunch() }
    }

    func confirmOlder() async {
        guard case .confirmOlder(let dmg, _) = phase else { return }
        phase = .idle
        await install(from: dmg, allowingOlder: true)
    }

    func dismiss() {
        if !isBusy { phase = .idle }
    }

    private func installMounted(dmg: URL, mountPoint: URL, allowingOlder: Bool) async -> Phase {
        guard let candidate = Self.findApp(in: mountPoint, bundleIdentifier: bundleIdentifier) else {
            return .failed("This DMG has no sTools in it.")
        }
        let info = Self.infoPlist(of: candidate) ?? [:]
        let found = AppVersion(short: info["CFBundleShortVersionString"] as? String, build: info["CFBundleVersion"] as? String)
        switch Self.compare(found, running) {
        case .same:
            return .failed("This DMG has the build you already have (\(found.text.lowercased())).")
        case .older where !allowingOlder:
            return .confirmOlder(dmg: dmg, found: found)
        case .older, .newer, .unknown:
            break
        }
        guard signatures.isSignedLikeRunningApp(candidate) else {
            return .failed("This sTools isn\u{2019}t signed by the same developer as yours, so it won\u{2019}t be installed.")
        }
        phase = .installing
        do {
            try Self.replace(installedApp, with: candidate, verifying: signatures)
        } catch let error as DMGInstallError {
            return .failed(error.message(installedApp: installedApp))
        } catch {
            return .failed("sTools couldn\u{2019}t be replaced: \(error.localizedDescription)")
        }
        return .installed(found)
    }

    // MARK: - Steps (static, so tests can run them on temporary folders)

    /// The top-level app in `folder` with `bundleIdentifier` (any app when that is nil).
    static func findApp(in folder: URL, bundleIdentifier: String?) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items
            .filter { $0.pathExtension == "app" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first { app in
                guard let bundleIdentifier else { return true }
                return infoPlist(of: app)?["CFBundleIdentifier"] as? String == bundleIdentifier
            }
    }

    /// The app's Info.plist, read straight from disk (a `Bundle` would be cached for the path).
    static func infoPlist(of app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    enum Comparison: Equatable { case newer, same, older, unknown }

    /// Builds are compared by number; a copy without one compares as unknown and installs.
    static func compare(_ found: AppVersion, _ running: AppVersion) -> Comparison {
        guard let new = found.build.flatMap(Int.init), let old = running.build.flatMap(Int.init) else { return .unknown }
        return new > old ? .newer : new == old ? .same : .older
    }

    /// Copies `candidate` next to `installed`, clears the download quarantine the DMG passed on (the copy is signed like
    /// the running one, which the person already opened), checks the copy's signature again, then swaps it in.
    static func replace(_ installed: URL, with candidate: URL, verifying signatures: any AppSignatureChecking) throws {
        let files = FileManager.default
        let parent = installed.deletingLastPathComponent()
        guard files.isWritableFile(atPath: parent.path) else { throw DMGInstallError.folderNotWritable }
        let staging = parent.appending(path: ".sTools-update-\(UUID().uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        let staged = staging.appending(path: installed.lastPathComponent, directoryHint: .isDirectory)
        do {
            try files.copyItem(at: candidate, to: staged)
        } catch {
            throw DMGInstallError.copyFailed
        }
        removeQuarantine(under: staged)
        guard signatures.isSignedLikeRunningApp(staged) else { throw DMGInstallError.copyDamaged }
        _ = try files.replaceItemAt(installed, withItemAt: staged)
    }

    static func removeQuarantine(under root: URL) {
        let attribute = "com.apple.quarantine"
        removexattr(root.path, attribute, XATTR_NOFOLLOW)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            removexattr(url.path, attribute, XATTR_NOFOLLOW)
        }
    }

    // MARK: - Words

    /// The line under Install from DMG…, or nil when there's nothing to say.
    var statusText: String? {
        switch phase {
        case .idle: nil
        case .checking: "Checking the DMG\u{2026}"
        case .confirmOlder(_, let found): "This DMG has an older build (\(found.text.lowercased())) than yours (\(running.text.lowercased()))."
        case .installing: "Installing\u{2026}"
        case .installed(let found): "Installed \(found.text.lowercased()). sTools is opening again\u{2026}"
        case .failed(let message): message
        }
    }
}

enum DMGInstallError: Error, Equatable {
    case folderNotWritable, copyFailed, copyDamaged

    func message(installedApp: URL) -> String {
        switch self {
        case .folderNotWritable:
            "sTools can\u{2019}t write to \(installedApp.deletingLastPathComponent().lastPathComponent). Drag sTools from the DMG into it instead."
        case .copyFailed:
            "sTools couldn\u{2019}t copy the new version out of the DMG. Your copy wasn\u{2019}t changed."
        case .copyDamaged:
            "The copied sTools didn\u{2019}t pass its signature check. Your copy wasn\u{2019}t changed."
        }
    }
}

// MARK: - Disk images

/// Mounts and ejects a DMG. The live one uses `hdiutil`; tests use a fake.
protocol DiskImageMounting: Sendable {
    /// Mounts `dmg` read-only, hidden from Finder, and returns where.
    func attach(_ dmg: URL) async throws -> URL
    func detach(_ mountPoint: URL) async
}

enum DiskImageError: Error, Equatable {
    case attachFailed
}

/// `hdiutil attach -nobrowse -readonly`: no Finder window, no icon on the desktop, nothing written to the DMG.
struct HdiutilMounter: DiskImageMounting {
    func attach(_ dmg: URL) async throws -> URL {
        let output = try await Self.run(["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", dmg.path])
        guard let mountPoint = Self.mountPoint(fromPlist: output) else { throw DiskImageError.attachFailed }
        return mountPoint
    }

    func detach(_ mountPoint: URL) async {
        if (try? await Self.run(["detach", mountPoint.path])) == nil {
            _ = try? await Self.run(["detach", "-force", mountPoint.path])
        }
    }

    /// The mount point in `hdiutil attach -plist`'s output.
    static func mountPoint(fromPlist data: Data) -> URL? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        return entities.lazy.compactMap { $0["mount-point"] as? String }.first.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static func run(_ arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: DiskImageError.attachFailed)
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Signatures

/// Whether an app is signed by the same certificate as the running sTools. The live one uses the Security framework;
/// tests use a fake.
protocol AppSignatureChecking: Sendable {
    func isSignedLikeRunningApp(_ app: URL) -> Bool
}

/// Checks `app` against the running copy's own designated requirement (its identifier and signing certificate), with a
/// strict, all-architectures validation, so only a copy built and signed the same way passes.
struct CodeSignatureChecker: AppSignatureChecking {
    func isSignedLikeRunningApp(_ app: URL) -> Bool {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return false }
        var myStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &myStatic) == errSecSuccess, let myStatic else { return false }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(myStatic, [], &requirement) == errSecSuccess, let requirement else { return false }
        return Self.validate(app, against: requirement)
    }

    static func validate(_ app: URL, against requirement: SecRequirement) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess
    }
}
