import Testing
@testable import NBBOverlay

private typealias Item = NBBWindowParser.Item

private func eyeThrow(error: Double, showsError: Bool = true) -> NBBEvents.EyeThrow {
    NBBEvents.EyeThrow(
        xInOverworld: -1374.7, zInOverworld: 81.61, angle: -80.64, angleWithoutCorrection: -80.64, correction: 0,
        correctionIncrements: 0, error: error, type: "NORMAL", showsError: showsError)
}

/// A throw's error as Ninjabrain Bot 1.5.2 writes it (`ThrowPanel.updateError`: `String.format(Locale.US, "%.3f", ...)`):
/// a minus when it's negative, no plus when it's positive, and no ± in front.
@Suite("Eye throw errors")
struct NBBThrowErrorTests {
    @Test func aNegativeErrorHasOneMinusAndNoPlusMinus() {
        #expect(NBBThrowError.text(eyeThrow(error: -0.0022)) == "-0.002")
        #expect(NBBThrowError.text(eyeThrow(error: -0.0125)) == "-0.013", "rounded half up, as Java does")
    }

    @Test func aPositiveErrorHasNoSign() {
        #expect(NBBThrowError.text(eyeThrow(error: 0.0022)) == "0.002")
        // 0.0045 is just below the tie in binary: C's printf gives "0.004", Java "0.005".
        #expect(NBBThrowError.text(eyeThrow(error: 0.0045)) == "0.005")
    }

    @Test func aZeroErrorHasNoSign() {
        #expect(NBBThrowError.text(eyeThrow(error: 0)) == "0.000")
    }

    @Test func anUnknownErrorShowsNothing() {
        #expect(NBBThrowError.text(eyeThrow(error: 0, showsError: false)) == nil)
    }

    /// A Ninjabrain Bot window's own error text is shown as it is, with nothing put in front.
    @Test func aWindowsOwnErrorTextIsKept() throws {
        let t = Item.text
        var window = [t("Location"), t("%"), t("Dist."), t("Nether"), t("Angle"),
                      t("(-1340, 84)"), t("100.0%"), t("1"), t("(-168, 10)"), t("118.30"), t(" (<- 113.7)"), t("s1"),
                      t("Ender eye throws"), Item(role: "AXButton", text: "Undo"), Item(role: "AXButton", text: "Redo"),
                      Item(role: "AXButton", text: "Reset"), t("x"), t("z"), t("Angle"), t("Error")]
        for row in [["-1374.70", "81.61", "-80.64", "-0.0022"], ["-1300.00", "90.00", "-81.20", "0.004"], ["-1200.00", "95.00", "-82.00", "0.000"]] {
            window.append(.button)
            window += row.map(t)
        }
        window += [t(""), t(""), t("")]
        let read = try #require(NBBWindowParser.parse(window)).stronghold.eyeThrows
        #expect(read.map(NBBThrowError.text) == ["-0.0022", "0.004", "0.000"])
    }
}
