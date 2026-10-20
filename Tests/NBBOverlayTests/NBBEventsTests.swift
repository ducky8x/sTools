import Foundation
import Testing
@testable import NBBOverlay

@Suite("NBB events decoding")
struct NBBEventsTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func strongholdDecodesPredictionsAndEyeThrows() throws {
        let json = """
        {"resultType":"TRIANGULATION",
         "predictions":[{"chunkX":12,"chunkZ":-34,"certainty":0.87,"overworldDistance":512.3}],
         "eyeThrows":[{"xInOverworld":100.0,"zInOverworld":-200.0,"angle":45.0,"angleWithoutCorrection":44.5,
                       "correction":0.5,"correctionIncrements":2,"error":0.01,"type":"NORMAL"}],
         "playerPosition":{"xInOverworld":1.0,"zInOverworld":2.0,"horizontalAngle":90.0,"isInOverworld":true,"isInNether":false}}
        """
        let value = try decode(NBBEvents.Stronghold.self, json)
        #expect(value.resultType == .triangulation)
        #expect(value.predictions.count == 1)
        #expect(value.predictions[0].chunkX == 12)
        #expect(value.predictions[0].certainty == 0.87)
        #expect(value.eyeThrows.count == 1)
        #expect(value.eyeThrows[0].correctionIncrements == 2)
        #expect(value.eyeThrows[0].type == "NORMAL")
        #expect(value.playerPosition?.xInOverworld == 1.0)
        #expect(value.playerPosition?.isInOverworld == true)
    }

    @Test func strongholdEmptyPlayerPositionDecodesToAllNilFields() throws {
        // PlayerPosition's own fields are all optional (per the API), so "{}" decodes successfully
        // into one with every field nil, rather than failing and falling back to the outer nil.
        let json = #"{"resultType":"NONE","predictions":[],"eyeThrows":[],"playerPosition":{}}"#
        let value = try decode(NBBEvents.Stronghold.self, json)
        #expect(value.playerPosition?.xInOverworld == nil)
        #expect(value.playerPosition?.isInOverworld == nil)
    }

    @Test func strongholdMissingFieldsFallBackToEmpty() throws {
        let value = try decode(NBBEvents.Stronghold.self, "{}")
        #expect(value.resultType == .none)
        #expect(value.predictions.isEmpty)
        #expect(value.eyeThrows.isEmpty)
        #expect(value.playerPosition == nil)
    }

    @Test func eyeThrowWithoutCorrectionIncrementsDecodesAsNil() throws {
        // Pre-1.5.2 shape: no correctionIncrements field at all.
        let json = """
        {"resultType":"FAILED","predictions":[],
         "eyeThrows":[{"xInOverworld":1,"zInOverworld":2,"angle":3,"angleWithoutCorrection":4,
                       "correction":5,"error":6,"type":"NORMAL"}]}
        """
        let value = try decode(NBBEvents.Stronghold.self, json)
        #expect(value.eyeThrows[0].correctionIncrements == nil)
    }

    @Test func blindDecodesAResult() throws {
        let json = """
        {"isBlindModeEnabled":true,"hasDivine":false,
         "blindResult":{"evaluation":"Good","xInNether":10,"zInNether":-5,"highrollThreshold":0.9,
                        "highrollProbability":0.42,"improveDirection":1.57,"improveDistance":30}}
        """
        let value = try decode(NBBEvents.Blind.self, json)
        #expect(value.isBlindModeEnabled)
        #expect(value.blindResult?.evaluation == "Good")
        #expect(value.blindResult?.highrollProbability == 0.42)
    }

    @Test func blindEmptyResultDecodesToNil() throws {
        let json = #"{"isBlindModeEnabled":true,"hasDivine":false,"blindResult":{}}"#
        let value = try decode(NBBEvents.Blind.self, json)
        #expect(value.blindResult == nil)
    }

    @Test func blindExtraUnknownFieldIsIgnored() throws {
        // Real NBB sends an extra "averageDistance" field the sTools spec doesn't surface; must not break decoding.
        let json = """
        {"isBlindModeEnabled":true,"hasDivine":false,
         "blindResult":{"evaluation":"Good","xInNether":1,"zInNether":2,"highrollThreshold":3,
                        "highrollProbability":4,"improveDirection":5,"improveDistance":6,"averageDistance":7}}
        """
        let value = try decode(NBBEvents.Blind.self, json)
        #expect(value.blindResult?.evaluation == "Good")
    }

    @Test func divineDecodesAResult() throws {
        let json = """
        {"isDivineModeEnabled":true,
         "divineResult":{"fossilXCoordinate":123.0,"formattedSafeCoords":"X: 1, Z: 2","formattedHighrollCoords":"X: 3, Z: 4"}}
        """
        let value = try decode(NBBEvents.Divine.self, json)
        #expect(value.divineResult?.formattedSafeCoords == "X: 1, Z: 2")
    }

    @Test func divineEmptyResultDecodesToNil() throws {
        let value = try decode(NBBEvents.Divine.self, #"{"isDivineModeEnabled":false,"divineResult":{}}"#)
        #expect(value.divineResult == nil)
    }

    @Test(arguments: [("NONE", NBBEvents.BoatState.none), ("ERROR", .error), ("MEASURING", .measuring), ("VALID", .valid)])
    func boatStateDecodesEveryCase(raw: String, expected: NBBEvents.BoatState) throws {
        let value = try decode(NBBEvents.Boat.self, #"{"boatState":"\#(raw)"}"#)
        #expect(value.boatState == expected)
    }

    @Test func boatAngleIsOptional() throws {
        let withAngle = try decode(NBBEvents.Boat.self, #"{"boatState":"VALID","boatAngle":12.5}"#)
        #expect(withAngle.boatAngle == 12.5)
        let withoutAngle = try decode(NBBEvents.Boat.self, #"{"boatState":"MEASURING"}"#)
        #expect(withoutAngle.boatAngle == nil)
    }

    @Test func informationMessagesDecodeSeverityAndHTML() throws {
        let json = """
        {"informationMessages":[{"severity":"WARNING","type":"SETUP","message":"Enable the <b>API</b> in settings."}]}
        """
        let value = try decode(NBBEvents.InformationMessages.self, json)
        #expect(value.informationMessages.count == 1)
        #expect(value.informationMessages[0].severity == .warning)
        #expect(value.informationMessages[0].message.contains("<b>"))
    }

    @Test func informationMessagesMissingArrayDefaultsToEmpty() throws {
        let value = try decode(NBBEvents.InformationMessages.self, "{}")
        #expect(value.informationMessages.isEmpty)
    }

    @Test func allAdvancementsDecodesPresentPositionsAndNilsEmptyOnes() throws {
        let json = """
        {"isAllAdvancementsModeEnabled":true,
         "spawn":{"xInOverworld":1,"zInOverworld":2,"travelAngle":3,"overworldDistance":4},
         "monument":{},"stronghold":{},"outpost":{},"deepDark":{},"cityQuery":{},"shulkerTransport":{},"generalLocation":{}}
        """
        let value = try decode(NBBEvents.AllAdvancements.self, json)
        #expect(value.isAllAdvancementsModeEnabled)
        #expect(value.spawn?.xInOverworld == 1)
        #expect(value.monument == nil)
        #expect(value.stronghold == nil)
    }

    @Test func versionDecodes() throws {
        let value = try decode(NBBEvents.Version.self, #"{"version":"1.5.2"}"#)
        #expect(value.version == "1.5.2")
    }
}
