import Testing
@testable import NBBOverlay

private func eyeThrow(
    angle: Double = -80.63, without: Double = -80.64, correction: Double = 0.01, increments: Int? = 1, shown: String? = nil
) -> NBBEvents.EyeThrow {
    NBBEvents.EyeThrow(
        xInOverworld: -1374.7, zInOverworld: 81.61, angle: angle, angleWithoutCorrection: without, correction: correction,
        correctionIncrements: increments, error: 0.0022, type: "NORMAL", shownCorrection: shown)
}

/// The angle adjustment beside a throw's angle, as Ninjabrain Bot 1.5.2 writes it (`ThrowPanel.updateCorrection`).
@Suite("Eye throw angle corrections")
struct NBBAngleCorrectionTests {
    @Test func anAngleChangeIsWrittenWithASignAndTwoDecimals() {
        #expect(NBBAngleCorrection.text(eyeThrow(correction: 0.01), display: .angleChange) == "+0.01")
        #expect(NBBAngleCorrection.text(eyeThrow(correction: -0.02), display: .angleChange) == "-0.02")
        #expect(NBBAngleCorrection.text(eyeThrow(correction: 0.3), display: .angleChange) == "+0.30")
    }

    /// A correction with more than two decimals gets three, rounded half up as Java's formatter does (C's printf would
    /// give "+0.010" for 0.0105, whose binary value is just below the tie).
    @Test func aFinerAngleChangeGetsThreeDecimalsRoundedLikeJava() {
        #expect(NBBAngleCorrection.text(eyeThrow(correction: 0.0105), display: .angleChange) == "+0.011")
        #expect(NBBAngleCorrection.text(eyeThrow(correction: -0.0125), display: .angleChange) == "-0.013")
        #expect(NBBAngleCorrection.text(eyeThrow(correction: 0.0109), display: .angleChange) == "+0.011")
    }

    @Test func theNumberOfAdjustmentsIsASignedWholeNumber() {
        #expect(NBBAngleCorrection.text(eyeThrow(correction: 0.06, increments: 6), display: .increments) == "+6")
        #expect(NBBAngleCorrection.text(eyeThrow(correction: -0.03, increments: -3), display: .increments) == "-3")
    }

    /// Ninjabrain Bot shows nothing beside an angle that wasn't adjusted.
    @Test func noCorrectionShowsNothing() {
        #expect(NBBAngleCorrection.text(eyeThrow(correction: 0, increments: 0), display: .angleChange) == nil)
        #expect(NBBAngleCorrection.text(eyeThrow(correction: 5e-8, increments: 0), display: .angleChange) == nil)
        #expect(NBBAngleCorrection.text(eyeThrow(correction: 0, increments: 0), display: .increments) == nil)
        // Adjusted up and back down: the increments are 0 even if rounding left the angle a hair off.
        #expect(NBBAngleCorrection.text(eyeThrow(correction: 1e-9, increments: 0), display: .increments) == nil)
    }

    /// Before 1.5.2 the API sends no increments; the angle change is shown instead.
    @Test func withoutIncrementsTheAngleChangeIsShown() {
        #expect(NBBAngleCorrection.text(eyeThrow(correction: 0.01, increments: nil), display: .increments) == "+0.01")
    }

    /// A window's own text is shown as it is, whichever choice is set here: the window follows Ninjabrain Bot's own.
    @Test func aWindowsOwnCorrectionTextIsKept() {
        #expect(NBBAngleCorrection.text(eyeThrow(shown: "+6"), display: .angleChange) == "+6")
        #expect(NBBAngleCorrection.text(eyeThrow(shown: "-0.01"), display: .increments) == "-0.01")
    }

    /// Green for up, red for down, Ninjabrain Bot's dark theme's Subpixel + and Subpixel − colors.
    @Test func theColorFollowsTheSign() {
        #expect(NBBAngleCorrection.colorHex("+6") == "#75CC6C")
        #expect(NBBAngleCorrection.colorHex("+0.01") == "#75CC6C")
        #expect(NBBAngleCorrection.colorHex("-0.013") == "#CC6E72")
    }

    /// Ninjabrain Bot shows the angle before the correction, then the correction beside it.
    @Test func theAngleShownIsTheOneBeforeTheCorrection() {
        #expect(NBBAngleCorrection.angleText(eyeThrow(angle: -80.63, without: -80.64)) == "-80.64")
        // Rounded half up like Java's "%.2f", not to even.
        #expect(NBBAngleCorrection.angleText(eyeThrow(without: -80.645)) == "-80.65")
        #expect(NBBAngleCorrection.angleText(eyeThrow(without: 2.675)) == "2.68")
    }

    @Test func javaFixedFormatting() {
        #expect(NBBJavaFormat.fixed(0.125, places: 2) == "0.13")
        #expect(NBBJavaFormat.fixed(-0.125, places: 2) == "-0.13")
        #expect(NBBJavaFormat.fixed(3, places: 2) == "3.00")
        #expect(NBBJavaFormat.fixed(-0.0004, places: 3) == "-0.000")
        #expect(NBBJavaFormat.fixed(0.01, places: 2, plusSign: true) == "+0.01")
        #expect(NBBJavaFormat.fixed(1e-5, places: 3) == "0.000")
        #expect(NBBJavaFormat.fixed(123456.785, places: 2) == "123456.79")
    }
}
