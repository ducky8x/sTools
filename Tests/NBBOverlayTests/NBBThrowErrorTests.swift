import Testing
@testable import NBBOverlay

private func eyeThrow(error: Double) -> NBBEvents.EyeThrow {
    NBBEvents.EyeThrow(
        xInOverworld: -1374.7, zInOverworld: 81.61, angle: -80.64, angleWithoutCorrection: -80.64, correction: 0,
        correctionIncrements: 0, error: error, type: "NORMAL")
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
}
