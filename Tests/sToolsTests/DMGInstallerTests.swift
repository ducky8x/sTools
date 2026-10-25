import Darwin
import Foundation
import Testing
@testable import sTools

private let bundleID = "com.ducky8x.sTools"

/// A minimal app bundle: an Info.plist and one file whose text says which copy it is.
private func makeApp(at url: URL, id: String = bundleID, short: String = "0.2.0", build: String, marker: String) throws {
    let contents = url.appending(path: "Contents")
    try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": short, "CFBundleVersion": build]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
    try Data(marker.utf8).write(to: contents.appending(path: "MacOS/marker"))
}

private func marker(of app: URL) -> String? {
    (try? Data(contentsOf: app.appending(path: "Contents/MacOS/marker"))).map { String(decoding: $0, as: UTF8.self) }
}

private func tempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "dmg-installer-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// "Mounts" a DMG by handing back a folder that stands for its volume.
private final class FakeMounter: DiskImageMounting, @unchecked Sendable {
    let volume: URL?
    private(set) var detached: [URL] = []
    init(volume: URL?) { self.volume = volume }
    func attach(_ dmg: URL) async throws -> URL {
        guard let volume else { throw DiskImageError.attachFailed }
        return volume
    }
    func detach(_ mountPoint: URL) async { detached.append(mountPoint) }
}

private struct FakeSignatures: AppSignatureChecking {
    var passes = true
    func isSignedLikeRunningApp(_ app: URL) -> Bool { passes }
}

@Suite("Install from DMG")
@MainActor
struct DMGInstallerTests {
    private struct Setup {
        let installed: URL
        let volume: URL
        let dmg: URL
    }

    private func setup(installedBuild: String = "500", dmgBuild: String = "600") throws -> Setup {
        let root = try tempFolder()
        let installed = root.appending(path: "Applications/sTools.app")
        try makeApp(at: installed, build: installedBuild, marker: "old")
        let volume = root.appending(path: "Volume")
        try makeApp(at: volume.appending(path: "sTools.app"), build: dmgBuild, marker: "new")
        try FileManager.default.createSymbolicLink(at: volume.appending(path: "Applications"), withDestinationURL: URL(fileURLWithPath: "/Applications"))
        return Setup(installed: installed, volume: volume, dmg: root.appending(path: "sTools-0.2.0-beta-macOS.dmg"))
    }

    private func installer(_ setup: Setup, mounter: FakeMounter, signatures: FakeSignatures = FakeSignatures(), relaunched: @escaping @MainActor () -> Void = {}) -> DMGInstaller {
        DMGInstaller(
            installedApp: setup.installed, running: AppVersion(short: "0.1.0", build: DMGInstaller.infoPlist(of: setup.installed)?["CFBundleVersion"] as? String),
            bundleIdentifier: bundleID, mounter: mounter, signatures: signatures, relaunch: relaunched)
    }

    @Test func aNewerBuildReplacesThisCopyEjectsTheDMGAndOpensAgain() async throws {
        let setup = try setup()
        let mounter = FakeMounter(volume: setup.volume)
        var relaunches = 0
        let installer = installer(setup, mounter: mounter, relaunched: { relaunches += 1 })
        await installer.install(from: setup.dmg)
        #expect(installer.phase == .installed(AppVersion(short: "0.2.0", build: "600")))
        #expect(marker(of: setup.installed) == "new")
        #expect(mounter.detached == [setup.volume])
        #expect(relaunches == 1)
        // Nothing is left beside the installed copy.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: setup.installed.deletingLastPathComponent().path)
        #expect(siblings == ["sTools.app"])
    }

    @Test func theDownloadQuarantineIsClearedFromTheInstalledCopy() async throws {
        let setup = try setup()
        let file = setup.volume.appending(path: "sTools.app/Contents/MacOS/marker")
        let value = "0081;00000000;Safari;"
        #expect(setxattr(file.path, "com.apple.quarantine", value, value.utf8.count, 0, 0) == 0)
        await installer(setup, mounter: FakeMounter(volume: setup.volume)).install(from: setup.dmg)
        let installedFile = setup.installed.appending(path: "Contents/MacOS/marker")
        #expect(getxattr(installedFile.path, "com.apple.quarantine", nil, 0, 0, 0) < 0)
    }

    @Test func theSameBuildIsNotInstalled() async throws {
        let setup = try setup(installedBuild: "600", dmgBuild: "600")
        let installer = installer(setup, mounter: FakeMounter(volume: setup.volume))
        await installer.install(from: setup.dmg)
        #expect(installer.phase == .failed("This DMG has the build you already have (version 0.2.0 (build 600))."))
        #expect(marker(of: setup.installed) == "old")
    }

    @Test func anOlderBuildWaitsForAConfirmationThenInstalls() async throws {
        let setup = try setup(installedBuild: "700", dmgBuild: "600")
        let mounter = FakeMounter(volume: setup.volume)
        let installer = installer(setup, mounter: mounter)
        await installer.install(from: setup.dmg)
        #expect(installer.phase == .confirmOlder(dmg: setup.dmg, found: AppVersion(short: "0.2.0", build: "600")))
        #expect(marker(of: setup.installed) == "old")
        #expect(mounter.detached.count == 1)
        await installer.confirmOlder()
        #expect(marker(of: setup.installed) == "new")
        #expect(mounter.detached.count == 2)
    }

    @Test func aCopySignedBySomeoneElseIsRefused() async throws {
        let setup = try setup()
        var relaunches = 0
        let installer = installer(setup, mounter: FakeMounter(volume: setup.volume), signatures: FakeSignatures(passes: false), relaunched: { relaunches += 1 })
        await installer.install(from: setup.dmg)
        #expect(installer.phase == .failed("This sTools isn\u{2019}t signed by the same developer as yours, so it won\u{2019}t be installed."))
        #expect(marker(of: setup.installed) == "old")
        #expect(relaunches == 0)
    }

    @Test func aDMGWithoutSToolsSaysSo() async throws {
        let setup = try setup()
        try FileManager.default.removeItem(at: setup.volume.appending(path: "sTools.app"))
        try makeApp(at: setup.volume.appending(path: "Other.app"), id: "com.example.other", build: "900", marker: "other")
        let installer = installer(setup, mounter: FakeMounter(volume: setup.volume))
        await installer.install(from: setup.dmg)
        #expect(installer.phase == .failed("This DMG has no sTools in it."))
    }

    @Test func aFileThatIsntADiskImageSaysSo() async throws {
        let setup = try setup()
        let installer = installer(setup, mounter: FakeMounter(volume: nil))
        await installer.install(from: setup.dmg)
        #expect(installer.phase == .failed("This file couldn\u{2019}t be opened as a disk image."))
    }

    @Test func aFolderSToolsCantWriteToLeavesTheCopyAlone() async throws {
        let setup = try setup()
        let folder = setup.installed.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let installer = installer(setup, mounter: FakeMounter(volume: setup.volume))
        await installer.install(from: setup.dmg)
        #expect(installer.phase == .failed("sTools can\u{2019}t write to Applications. Drag sTools from the DMG into it instead."))
        #expect(marker(of: setup.installed) == "old")
    }

    @Test func aCopyRunningFromATemporaryPlaceSaysToMoveItFirst() throws {
        #expect(DMGInstaller.isTemporaryCopy(URL(fileURLWithPath: "/private/var/folders/xy/T/AppTranslocation/1234/d/sTools.app")))
        #expect(!DMGInstaller.isTemporaryCopy(try tempFolder().appending(path: "sTools.app")))
        #expect(DMGInstallError.runningFromTemporaryCopy.message(installedApp: URL(fileURLWithPath: "/x/sTools.app"))
            == "This sTools is running from the DMG or a temporary copy macOS made. Drag sTools into Applications, open it from there, then install again.")
    }

    @Test func buildsCompareByNumber() {
        #expect(DMGInstaller.compare(AppVersion(short: nil, build: "10"), AppVersion(short: nil, build: "9")) == .newer)
        #expect(DMGInstaller.compare(AppVersion(short: nil, build: "9"), AppVersion(short: nil, build: "10")) == .older)
        #expect(DMGInstaller.compare(AppVersion(short: nil, build: "9"), AppVersion(short: nil, build: "9")) == .same)
        #expect(DMGInstaller.compare(AppVersion(short: nil, build: nil), AppVersion(short: nil, build: "9")) == .unknown)
    }

    @Test func readsTheMountPointFromHdiutilsPlist() throws {
        let plist: [String: Any] = ["system-entities": [["dev-entry": "/dev/disk9"], ["dev-entry": "/dev/disk9s1", "mount-point": "/Volumes/sTools"]]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        #expect(HdiutilMounter.mountPoint(fromPlist: data)?.path == "/Volumes/sTools")
        #expect(HdiutilMounter.mountPoint(fromPlist: Data("nope".utf8)) == nil)
    }

    /// A real DMG, mounted hidden from Finder and ejected again: the live mounter finds sTools in it.
    @Test func theLiveMounterOpensARealDMG() async throws {
        let root = try tempFolder()
        let source = root.appending(path: "source")
        try makeApp(at: source.appending(path: "sTools.app"), build: "42", marker: "dmg")
        let dmg = root.appending(path: "test.dmg")
        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        create.arguments = ["create", "-quiet", "-fs", "HFS+", "-volname", "sToolsTest", "-srcfolder", source.path, "-format", "UDZO", dmg.path]
        try create.run()
        create.waitUntilExit()
        try #require(create.terminationStatus == 0)
        let mounter = HdiutilMounter()
        let mountPoint = try await mounter.attach(dmg)
        let app = DMGInstaller.findApp(in: mountPoint, bundleIdentifier: bundleID)
        await mounter.detach(mountPoint)
        #expect(app?.lastPathComponent == "sTools.app")
        #expect(!FileManager.default.fileExists(atPath: mountPoint.path))
    }
}
