import CoreGraphics
import STDesign
import Testing
@testable import TimerOverlay

/// The settings with one change, for the overrides below.
private func settings(_ change: (inout TimerOverlaySettings) -> Void = { _ in }) -> TimerOverlaySettings {
    var settings = TimerOverlaySettings()
    change(&settings)
    return settings
}

private func look(_ settings: TimerOverlaySettings = TimerOverlaySettings(), _ state: TimerOverlayContent.State = .counting,
                  increaseContrast: Bool = false) -> TimerLook {
    TimerLook(settings: settings, state: state, increaseContrast: increaseContrast)
}

@Suite("Timer look")
struct TimerLookTests {
    // MARK: sTools plate (spec 5.6.4)

    @Test func theSToolsPlateIsTheBackgroundAt85PercentWithAHairlineAndTwelvePointCorners() throws {
        let counting = look()
        let plate = try #require(counting.plate)
        #expect(plate.colorHex == STPalette.background)
        #expect(plate.opacity == 0.85)
        #expect(plate.edgeHex == STPalette.rule)
        #expect(plate.edgeWidth == 1)
        #expect(plate.shape == .rounded(12))
        #expect(counting.digitHex == STPalette.ink)
        #expect(counting.outline == nil)
    }

    @Test func atZeroThePlateTurnsGoldAndTheDigitsBackground() throws {
        let timesUp = look(TimerOverlaySettings(), .timesUp)
        let plate = try #require(timesUp.plate)
        #expect(plate.colorHex == STPalette.gold)
        #expect(plate.opacity == 0.85)
        #expect(timesUp.digitHex == STPalette.background)
        #expect(timesUp.captionHex == STPalette.background, "the label reads on the gold plate too")
    }

    @Test func pausedDimsTheDigitsAndTheCaption() {
        let paused = look(TimerOverlaySettings(), .paused)
        #expect(paused.digitHex == STPalette.inkSecondary)
        #expect(paused.captionHex == STPalette.inkSecondary)
        #expect(paused.plate?.colorHex == STPalette.background)
    }

    @Test func nearZeroColorsTheDigits() {
        #expect(look(TimerOverlaySettings(), .nearZeroGold).digitHex == STPalette.gold)
        #expect(look(TimerOverlaySettings(), .nearZeroDanger).digitHex == STPalette.danger)
        #expect(look(TimerOverlaySettings(), .nearZeroGold).plate?.colorHex == STPalette.background, "the plate stays")
    }

    @Test func theLabelIsQuieterThanTheDigitsWhileCounting() {
        #expect(look().captionHex == STPalette.inkSecondary)
    }

    // MARK: Digits only

    @Test func digitsOnlyHasNoPlateAndAThinDarkOutline() throws {
        let digits = look(settings { $0.look = .digitsOnly })
        #expect(digits.plate == nil)
        #expect(digits.digitHex == STPalette.ink)
        let outline = try #require(digits.outline)
        #expect(outline.colorHex == STPalette.background)
        #expect(outline.width >= 1 && outline.width <= 2, "thin at 40 pt")
        #expect(digits.captionHex == digits.digitHex, "the label is outlined digits' color, over the game")
    }

    @Test func digitsOnlyTurnGoldAtZero() {
        let timesUp = look(settings { $0.look = .digitsOnly }, .timesUp)
        #expect(timesUp.plate == nil)
        #expect(timesUp.digitHex == STPalette.gold)
        #expect(timesUp.outline?.colorHex == STPalette.background)
    }

    @Test func theOutlineGrowsWithTheDigits() throws {
        let small = try #require(look(settings { $0.look = .digitsOnly; $0.digitSize = 28 }).outline)
        let large = try #require(look(settings { $0.look = .digitsOnly; $0.digitSize = 140 }).outline)
        #expect(small.width >= 1)
        #expect(large.width > small.width)
    }

    @Test func digitsOnlyIgnoresThePlateOverrides() {
        let digits = look(settings {
            $0.look = .digitsOnly
            $0.plateColorHex = "#112233"
            $0.plateOpacityPercent = 60
            $0.edgeWidth = 0
            $0.edgeColorHex = "#445566"
        })
        #expect(digits.plate == nil)
        #expect(digits.outline?.colorHex == STPalette.background, "the outline that keeps them readable stays")
        #expect((digits.outline?.width ?? 0) > 0)
    }

    @Test func digitsOnlyStayGoldNearZeroWithNoPlateToFade() {
        #expect(look(settings { $0.look = .digitsOnly; $0.plateOpacityPercent = 60 }, .nearZeroGold).digitHex == STPalette.gold)
    }

    // MARK: Compact pill

    @Test func theCompactPillIsACapsuleInThePlatesColors() throws {
        let pill = look(settings { $0.look = .compactPill })
        let plate = try #require(pill.plate)
        #expect(plate.shape == .capsule)
        #expect(plate.colorHex == STPalette.background)
        #expect(plate.opacity == 0.85)
        #expect(plate.edgeHex == STPalette.rule)
        #expect(pill.digitHex == STPalette.ink)
        let timesUp = look(settings { $0.look = .compactPill }, .timesUp)
        #expect(timesUp.plate?.colorHex == STPalette.gold)
        #expect(timesUp.digitHex == STPalette.background)
    }

    @Test func aCornerOverrideRoundsThePillsEndsLess() {
        #expect(look(settings { $0.look = .compactPill; $0.cornerRadius = 6 }).plate?.shape == .rounded(6))
    }

    // MARK: Advanced overrides

    @Test func everyPlateOverrideApplies() throws {
        let custom = settings {
            $0.plateColorHex = "#203040"
            $0.plateOpacityPercent = 95
            $0.edgeColorHex = "#a0b0c0"
            $0.edgeWidth = 3
            $0.cornerRadius = 4
            $0.digitColorHex = "#E0F0FF"
        }
        let counting = look(custom)
        let plate = try #require(counting.plate)
        #expect(plate.colorHex == "#203040")
        #expect(plate.opacity == 0.95)
        #expect(plate.edgeHex == "#A0B0C0", "normalized")
        #expect(plate.edgeWidth == 3)
        #expect(plate.shape == .rounded(4))
        #expect(counting.digitHex == "#E0F0FF")
    }

    @Test func theTimesUpOverridesApplyAtZero() throws {
        let custom = settings {
            $0.timesUpPlateColorHex = "#AA2200"
            $0.timesUpDigitColorHex = "#FFFFFF"
            $0.plateColorHex = "#203040"
        }
        let timesUp = look(custom, .timesUp)
        #expect(timesUp.plate?.colorHex == "#AA2200")
        #expect(timesUp.digitHex == "#FFFFFF")
        #expect(look(custom).plate?.colorHex == "#203040", "counting keeps its own plate")
        #expect(look(settings { $0.look = .digitsOnly; $0.timesUpDigitColorHex = "#00FF00" }, .timesUp).digitHex == "#00FF00")
    }

    @Test func anEdgeOfZeroDrawsNoEdge() {
        #expect(look(settings { $0.edgeWidth = 0 }).plate?.edgeWidth == 0)
    }

    @Test func theNearZeroAndPausedColorsBeatTheDigitOverride() {
        let custom = settings { $0.digitColorHex = "#E0F0FF" }
        #expect(look(custom, .nearZeroGold).digitHex == STPalette.gold)
        #expect(look(custom, .nearZeroDanger).digitHex == STPalette.danger)
        #expect(look(custom, .paused).digitHex == STPalette.inkSecondary)
    }

    @Test func unusableOverridesFallBackToTheLook() throws {
        let broken = settings {
            $0.plateColorHex = "blue"
            $0.plateOpacityPercent = 5
            $0.edgeWidth = .infinity
            $0.cornerRadius = -3
            $0.digitColorHex = "#12345"
        }
        let resolved = look(broken)
        let plate = try #require(resolved.plate)
        #expect(plate.colorHex == STPalette.background)
        #expect(plate.opacity == 0.60, "clamped to 60-100%")
        #expect(plate.edgeWidth == 1)
        #expect(plate.shape == .rounded(0))
        #expect(resolved.digitHex == STPalette.ink)
    }

    // MARK: Contrast (spec 3.3, 5.6.4)

    @Test(arguments: [TimerOverlaySettings.Look.plate, .compactPill])
    func belowEightyPercentGoldDigitsTurnInk(look kind: TimerOverlaySettings.Look) {
        #expect(look(settings { $0.look = kind; $0.plateOpacityPercent = 79 }, .nearZeroGold).digitHex == STPalette.ink)
        #expect(look(settings { $0.look = kind; $0.plateOpacityPercent = 80 }, .nearZeroGold).digitHex == STPalette.gold)
        #expect(look(settings { $0.look = kind; $0.plateOpacityPercent = 60; $0.digitColorHex = "#d9ae52" }).digitHex == STPalette.ink,
                "gold chosen as the digit color too")
    }

    @Test func belowEightyPercentTheGoldPlateKeepsItsDarkDigits() {
        let timesUp = look(settings { $0.plateOpacityPercent = 60 }, .timesUp)
        #expect(timesUp.plate?.colorHex == STPalette.gold)
        #expect(timesUp.digitHex == STPalette.background)
    }

    @Test func increaseContrastThickensTheEdgeAndTheOutline() throws {
        let normal = try #require(look().plate)
        let raised = try #require(look(increaseContrast: true).plate)
        #expect(raised.edgeWidth > normal.edgeWidth)
        let thin = try #require(look(settings { $0.look = .digitsOnly }).outline)
        let thick = try #require(look(settings { $0.look = .digitsOnly }, increaseContrast: true).outline)
        #expect(thick.width > thin.width)
        #expect(look(increaseContrast: true).dangerEdgeWidth > look().dangerEdgeWidth)
    }

    @Test func increaseContrastKeepsANoEdgeChoice() {
        #expect(look(settings { $0.edgeWidth = 0 }, increaseContrast: true).plate?.edgeWidth == 0)
    }

    @Test func increaseContrastRaisesTheDimmedInkToInk() {
        #expect(look(TimerOverlaySettings(), .paused, increaseContrast: true).digitHex == STPalette.ink)
        #expect(look(TimerOverlaySettings(), .counting, increaseContrast: true).captionHex == STPalette.ink)
    }

    // MARK: What the overlay shows

    @Test func colorNearZeroOffKeepsCounting() {
        for seconds in [0, 5, 10, 30, 31, 150] {
            #expect(TimerOverlayContent.countingState(shownSeconds: seconds, settings: TimerOverlaySettings()) == .counting)
        }
    }

    @Test func goldFromItsTime() {
        let gold = settings { $0.nearZero = .gold }
        #expect(TimerOverlayContent.countingState(shownSeconds: 31, settings: gold) == .counting)
        #expect(TimerOverlayContent.countingState(shownSeconds: 30, settings: gold) == .nearZeroGold)
        #expect(TimerOverlayContent.countingState(shownSeconds: 1, settings: gold) == .nearZeroGold)
    }

    @Test func goldThenDangerFromTheirTimes() {
        let both = settings { $0.nearZero = .goldThenDanger; $0.nearZeroGoldSeconds = 20; $0.nearZeroDangerSeconds = 5 }
        #expect(TimerOverlayContent.countingState(shownSeconds: 21, settings: both) == .counting)
        #expect(TimerOverlayContent.countingState(shownSeconds: 20, settings: both) == .nearZeroGold)
        #expect(TimerOverlayContent.countingState(shownSeconds: 6, settings: both) == .nearZeroGold)
        #expect(TimerOverlayContent.countingState(shownSeconds: 5, settings: both) == .nearZeroDanger)
        #expect(TimerOverlayContent.countingState(shownSeconds: 1, settings: both) == .nearZeroDanger)
    }

    @Test func theContentTakesTheLabelAndProgressTheSettingsAskFor() {
        let plain = TimerOverlayContent(text: "02:30", state: .counting, steppedProgress: 1, settings: TimerOverlaySettings())
        #expect(plain.label == nil)
        #expect(plain.progress == nil)

        let full = TimerOverlayContent(
            text: "01:15", state: .counting, steppedProgress: 0.5, settings: settings { $0.showsLabel = true; $0.progress = .ring })
        #expect(full.label == "Fire res")
        #expect(full.progress == 0.5)
        #expect(!full.showsDangerEdge)

        let blank = TimerOverlayContent(text: "1", state: .counting, steppedProgress: 1, settings: settings { $0.showsLabel = true; $0.labelText = "  " })
        #expect(blank.label == nil, "a blank label shows nothing")
    }

    @Test func progressStaysBetweenEmptyAndFull() {
        #expect(TimerOverlayContent(text: "", progress: 1.4).progress == 1)
        #expect(TimerOverlayContent(text: "", progress: -0.2).progress == 0)
        #expect(TimerOverlayContent(text: "", progress: .nan).progress == 0)
    }
}
