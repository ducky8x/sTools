import Foundation
import Testing
@testable import STPlatform

@Suite struct MinecraftGameDirectoryTests {
    @Test func readsTheGameDirectoryArgument() {
        let arguments = ["java", "-Xmx4G", "net.minecraft.client.main.Main", "--username", "x", "--gameDir", "/Users/x/Library/Application Support/minecraft", "--version", "1.16.1"]
        #expect(MinecraftGameDirectory.fromArguments(arguments)?.path == "/Users/x/Library/Application Support/minecraft")
    }

    @Test func acceptsTheEqualsFormAndKeepsTheLastOne() {
        #expect(MinecraftGameDirectory.fromArguments(["--gameDir=/a", "--gameDir", "/b"])?.path == "/b")
        #expect(MinecraftGameDirectory.fromArguments(["--gameDir", "/a", "--gameDir=/c"])?.path == "/c")
    }

    @Test func noUsableArgumentMeansNone() {
        #expect(MinecraftGameDirectory.fromArguments(["java", "-jar", "x.jar"]) == nil)
        #expect(MinecraftGameDirectory.fromArguments(["--gameDir"]) == nil)
        #expect(MinecraftGameDirectory.fromArguments(["--gameDir="]) == nil)
    }

    @Test func parsesAKernelArgumentBuffer() {
        var bytes = withUnsafeBytes(of: Int32(3).littleEndian, Array.init)
        bytes += Array("/usr/bin/java".utf8) + [0, 0, 0, 0]
        for argument in ["java", "--gameDir", "/games/mc"] { bytes += Array(argument.utf8) + [0] }
        bytes += Array("HOME=/Users/x".utf8) + [0]
        #expect(MinecraftGameDirectory.parseProcessArguments(bytes) == ["java", "--gameDir", "/games/mc"])
    }

    @Test func aTruncatedBufferIsRejected() {
        var bytes = withUnsafeBytes(of: Int32(4).littleEndian, Array.init)
        bytes += Array("/usr/bin/java".utf8) + [0] + Array("java".utf8) + [0]
        #expect(MinecraftGameDirectory.parseProcessArguments(bytes) == nil)
        #expect(MinecraftGameDirectory.parseProcessArguments([1, 0]) == nil)
    }

    @Test func readsThisTestProcessItself() {
        let pid = ProcessInfo.processInfo.processIdentifier
        #expect(MinecraftGameDirectory.arguments(processID: pid)?.isEmpty == false)
        let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
        #expect(MinecraftGameDirectory.workingDirectory(processID: pid)?.resolvingSymlinksInPath().path == expected)
    }
}
