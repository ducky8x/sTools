import Foundation
import STDesign
import SwiftUI
import Testing
@testable import NBBOverlay

@Suite("NBB overlay layout")
struct NBBOverlayLayoutTests {
    private func prediction(_ certainty: Double) -> NBBEvents.Prediction {
        NBBEvents.Prediction(chunkX: 1, chunkZ: 2, certainty: certainty, overworldDistance: 500)
    }

    private func stronghold(_ resultType: NBBEvents.ResultType, predictions: [NBBEvents.Prediction] = []) -> NBBEvents.Stronghold {
        NBBEvents.Stronghold(resultType: resultType, predictions: predictions, eyeThrows: [], playerPosition: nil)
    }

    @Test func nilStrongholdIsHidden() {
        let content = NBBOverlayLayout.content(stronghold: nil, blind: nil, divine: nil, boat: nil, allAdvancements: nil, maxPredictionRows: 5)
        #expect(content == .hidden)
    }

    @Test func noneResultTypeIsHidden() {
        let content = NBBOverlayLayout.content(stronghold: stronghold(.none), blind: nil, divine: nil, boat: nil, allAdvancements: nil, maxPredictionRows: 5)
        #expect(content == .hidden)
    }

    @Test func triangulationCarriesPredictionsAndEyeThrows() {
        let boat = NBBEvents.Boat(boatState: .valid, boatAngle: 10)
        let content = NBBOverlayLayout.content(
            stronghold: stronghold(.triangulation, predictions: [prediction(0.8)]), blind: nil, divine: nil, boat: boat, allAdvancements: nil, maxPredictionRows: 5)
        guard case .triangulation(let data) = content else { Issue.record("expected triangulation"); return }
        #expect(data.predictions.count == 1)
    }

    // MARK: - Boat

    @Test(arguments: [
        (NBBEvents.BoatState.none, NBBBoatLook.Tone.gray, "No boat"),
        (.measuring, .blue, "Measuring boat"),
        (.valid, .green, "Boat ready"),
        (.error, .red, "Boat error"),
    ])
    func eachBoatStateHasNinjabrainBotsColorAndAWord(state: NBBEvents.BoatState, tone: NBBBoatLook.Tone, title: String) {
        let look = NBBBoatLook(state)
        #expect(look.tone == tone)
        #expect(look.title == title)
        #expect(look.tintsPlate == (tone != .gray))
    }

    @Test func theBoatShowsInEveryModeButGrayIsHiddenByDefault() {
        let settings = NBBOverlaySettings()
        #expect(NBBOverlayLayout.boatToShow(NBBEvents.Boat(boatState: .measuring, boatAngle: nil), settings: settings) == .measuring)
        #expect(NBBOverlayLayout.boatToShow(NBBEvents.Boat(boatState: .none, boatAngle: nil), settings: settings) == nil)
        #expect(NBBOverlayLayout.boatToShow(nil, settings: settings) == nil)
        var withGray = settings
        withGray.showsGrayBoat = true
        #expect(NBBOverlayLayout.boatToShow(NBBEvents.Boat(boatState: .none, boatAngle: nil), settings: withGray) == NBBEvents.BoatState.none)
        var off = settings
        off.showsBoatState = false
        #expect(NBBOverlayLayout.boatToShow(NBBEvents.Boat(boatState: .valid, boatAngle: 0), settings: off) == nil)
    }

    @Test func anActiveBoatAloneIsReasonToShowTheOverlay() {
        let settings = NBBOverlaySettings()
        for state in [NBBEvents.BoatState.measuring, .valid, .error] {
            #expect(NBBOverlayLayout.boatCountsAsData(NBBEvents.Boat(boatState: state, boatAngle: nil), settings: settings))
        }
        var withGray = settings
        withGray.showsGrayBoat = true
        #expect(!NBBOverlayLayout.boatCountsAsData(NBBEvents.Boat(boatState: .none, boatAngle: nil), settings: withGray))
    }

    @Test func thePlateTakesTheBoatsColorUnlessGrayOrTurnedOff() {
        let settings = NBBOverlaySettings()
        #expect(NBBOverlayLayout.plateTint(NBBEvents.Boat(boatState: .valid, boatAngle: 0), settings: settings)?.tone == .green)
        #expect(NBBOverlayLayout.plateTint(NBBEvents.Boat(boatState: .error, boatAngle: nil), settings: settings)?.tone == .red)
        #expect(NBBOverlayLayout.plateTint(NBBEvents.Boat(boatState: .none, boatAngle: nil), settings: settings) == nil)
        var off = settings
        off.tintsPlateByBoat = false
        #expect(NBBOverlayLayout.plateTint(NBBEvents.Boat(boatState: .valid, boatAngle: 0), settings: off) == nil)
    }

    /// Ink must stay readable on every tinted plate, at the plate's lowest opacity too.
    @Test func inkStaysReadableOnEveryTintedPlate() throws {
        for state in [NBBEvents.BoatState.measuring, .valid, .error] {
            let tint = try #require(STColorWellHex.components(from: NBBBoatLook(state).colorHex))
            let surface = try #require(STColorWellHex.components(from: STPalette.surface))
            let ink = try #require(STColorWellHex.components(from: STPalette.ink))
            let a = STPlate<EmptyView>.tintStrength
            let mixed = (surface.red * (1 - a) + tint.red * a, surface.green * (1 - a) + tint.green * a, surface.blue * (1 - a) + tint.blue * a)
            #expect(contrast(ink, mixed) >= 4.5, "ink on the \(state) plate")
        }
    }

    private func contrast(_ a: (red: Double, green: Double, blue: Double), _ b: (Double, Double, Double)) -> Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b) }
        let la = luminance(a.red, a.green, a.blue), lb = luminance(b.0, b.1, b.2)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test func failedCarriesEyeThrowsOnly() {
        var strongholdValue = stronghold(.failed)
        strongholdValue.eyeThrows = [NBBEvents.EyeThrow(xInOverworld: 1, zInOverworld: 2, angle: 3, angleWithoutCorrection: 4, correction: 5, correctionIncrements: nil, error: 6, type: "NORMAL")]
        let content = NBBOverlayLayout.content(stronghold: strongholdValue, blind: nil, divine: nil, boat: nil, allAdvancements: nil, maxPredictionRows: 5)
        guard case .failed(let eyeThrows) = content else { Issue.record("expected failed"); return }
        #expect(eyeThrows.count == 1)
    }

    @Test func blindModeNeedsAResultOrItStaysHidden() {
        let withoutResult = NBBEvents.Blind(isBlindModeEnabled: true, hasDivine: false, blindResult: nil)
        let hidden = NBBOverlayLayout.content(stronghold: stronghold(.blind), blind: withoutResult, divine: nil, boat: nil, allAdvancements: nil, maxPredictionRows: 5)
        #expect(hidden == .hidden)

        let result = NBBEvents.BlindResult(evaluation: "Good", xInNether: 1, zInNether: 2, highrollThreshold: 3, highrollProbability: 4, improveDirection: 5, improveDistance: 6)
        let withResult = NBBEvents.Blind(isBlindModeEnabled: true, hasDivine: false, blindResult: result)
        let shown = NBBOverlayLayout.content(stronghold: stronghold(.blind), blind: withResult, divine: nil, boat: nil, allAdvancements: nil, maxPredictionRows: 5)
        #expect(shown == .blind(result))
    }

    @Test func divineModeNeedsAResultOrItStaysHidden() {
        let result = NBBEvents.DivineResult(fossilXCoordinate: 1, formattedSafeCoords: "X: 1", formattedHighrollCoords: "X: 2")
        let divine = NBBEvents.Divine(isDivineModeEnabled: true, divineResult: result)
        let shown = NBBOverlayLayout.content(stronghold: stronghold(.divine), blind: nil, divine: divine, boat: nil, allAdvancements: nil, maxPredictionRows: 5)
        #expect(shown == .divine(result))

        let empty = NBBEvents.Divine(isDivineModeEnabled: true, divineResult: nil)
        let hidden = NBBOverlayLayout.content(stronghold: stronghold(.divine), blind: nil, divine: empty, boat: nil, allAdvancements: nil, maxPredictionRows: 5)
        #expect(hidden == .hidden)
    }

    @Test func allAdvancementsNeedsTheModeFlagOrItStaysHidden() throws {
        let data = try JSONDecoder().decode(NBBEvents.AllAdvancements.self, from: Data("""
        {"isAllAdvancementsModeEnabled":true,"spawn":{"xInOverworld":1,"zInOverworld":2,"travelAngle":3,"overworldDistance":4}}
        """.utf8))
        let shown = NBBOverlayLayout.content(stronghold: stronghold(.allAdvancements), blind: nil, divine: nil, boat: nil, allAdvancements: data, maxPredictionRows: 5)
        #expect(shown == .allAdvancements(data))

        var disabled = data
        disabled.isAllAdvancementsModeEnabled = false
        let hidden = NBBOverlayLayout.content(stronghold: stronghold(.allAdvancements), blind: nil, divine: nil, boat: nil, allAdvancements: disabled, maxPredictionRows: 5)
        #expect(hidden == .hidden)
    }

    @Test func predictionRowsDropThoseRoundingToZeroPercent() {
        // 0.001 rounds to 0% and must be dropped; 0.005 rounds to 1% (half-up) and must survive.
        let rows = NBBOverlayLayout.predictionRows(from: [prediction(0.8), prediction(0.001), prediction(0.005)], maxRows: 5)
        #expect(rows.map(\.certaintyPercent) == [80, 1])
    }

    @Test func predictionRowsAreCappedAtMaxRows() {
        let predictions = (0..<10).map { _ in prediction(0.5) }
        let rows = NBBOverlayLayout.predictionRows(from: predictions, maxRows: 3)
        #expect(rows.count == 3)
    }

    @Test func predictionRowsHandlesZeroMaxRows() {
        let rows = NBBOverlayLayout.predictionRows(from: [prediction(0.9)], maxRows: 0)
        #expect(rows.isEmpty)
    }

    @Test func htmlTagsAreStrippedFromMessages() {
        let messages = [NBBEvents.InformationMessage(severity: .warning, type: "SETUP", message: "Enable the <b>API</b> in <i>settings</i>.")]
        let plain = NBBOverlayLayout.plainTextMessages(from: messages)
        #expect(plain.map(\.text) == ["Enable the API in settings."])
        #expect(plain.map(\.severity) == [.warning])
    }

    @Test func messagesWithoutHTMLAreUnchanged() {
        let messages = [NBBEvents.InformationMessage(severity: .info, type: "X", message: "All good.")]
        #expect(NBBOverlayLayout.plainTextMessages(from: messages).map(\.text) == ["All good."])
    }
}
