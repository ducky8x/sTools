import Testing
@testable import KeyRebinder

@Suite struct KarabinerVersionTests {
    @Test(arguments: [
        ("16.3.0", 16, 3, 0, ""),
        ("15.9.0-beta", 15, 9, 0, "-beta"),
        ("16.0", 16, 0, 0, ""),
        ("16", 16, 0, 0, ""),
        ("v16.3.1\n", 16, 3, 1, ""),
        ("  16.10.2  ", 16, 10, 2, ""),
        ("16.3.0.1", 16, 3, 0, ".1"),
        ("16.x", 16, 0, 0, ".x"),
        ("17.0.0+build5", 17, 0, 0, "+build5"),
    ])
    func parses(text: String, major: Int, minor: Int, patch: Int, suffix: String) {
        let version = KarabinerVersion(text)
        #expect(version == KarabinerVersion(major: major, minor: minor, patch: patch, suffix: suffix))
    }

    @Test(arguments: ["", "beta", "x16.0", "-1.0", "."])
    func rejectsTextWithoutALeadingNumber(text: String) {
        #expect(KarabinerVersion(text) == nil)
    }

    @Test func comparesNumbersNotText() {
        let minimum = KarabinerVersion.minimumSupported
        #expect(KarabinerVersion("16.0.0")?.isAtLeast(minimum) == true)
        #expect(KarabinerVersion("16.3.0")?.isAtLeast(minimum) == true)
        #expect(KarabinerVersion("100.0.0")?.isAtLeast(minimum) == true)
        #expect(KarabinerVersion("15.9.0-beta")?.isAtLeast(minimum) == false)
        #expect(KarabinerVersion("15.99.99")?.isAtLeast(minimum) == false)
        #expect(KarabinerVersion("9.9.9")?.isAtLeast(minimum) == false)
        #expect(KarabinerVersion("16.10.0")?.isAtLeast(KarabinerVersion(major: 16, minor: 9)) == true)
    }

    @Test func aSuffixDoesNotLowerTheNumbers() {
        #expect(KarabinerVersion("16.0.0-beta")?.isAtLeast(.minimumSupported) == true)
    }

    @Test func describesItself() {
        #expect(KarabinerVersion("16.3")?.description == "16.3.0")
        #expect(KarabinerVersion("15.9.0-beta")?.description == "15.9.0-beta")
    }
}
