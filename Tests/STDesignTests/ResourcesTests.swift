import Foundation
import Testing
@testable import STDesign

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("stools-resources-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func locatesBundleInPackagedAppLayout() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("sTools.app/Contents/Resources", isDirectory: true)
    let fake = resources.appendingPathComponent("sTools_STDesign.bundle", isDirectory: true)
    try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
    #expect(STResources.locate(mainResourceURL: resources)?.standardizedFileURL == fake.standardizedFileURL)
}

@Test func locatesBundleNextToTheExecutableInSwiftPMLayout() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fake = root.appendingPathComponent("sTools_STDesign.bundle", isDirectory: true)
    try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
    #expect(STResources.locate(mainResourceURL: root)?.standardizedFileURL == fake.standardizedFileURL)
}

@Test func locateReturnsNilWhenBundleIsAbsent() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(STResources.locate(mainResourceURL: root) == nil)
    #expect(STResources.locate(mainResourceURL: nil) == nil)
}

@Test func locateIgnoresAPlainFileWithTheBundleName() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appendingPathComponent("sTools_STDesign.bundle"))
    #expect(STResources.locate(mainResourceURL: root) == nil)
}

@Test func bundleContainsTheFonts() {
    let fonts = STResources.bundle.url(forResource: "DMSerifDisplay-Regular", withExtension: "ttf", subdirectory: "Resources/Fonts")
    #expect(fonts != nil)
}
