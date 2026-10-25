import Foundation
import Testing
@testable import NBBOverlay

private func player(inNether: Bool?) -> NBBEvents.PlayerPosition {
    NBBEvents.PlayerPosition(xInOverworld: 0, zInOverworld: 0, horizontalAngle: 0, isInOverworld: inNether.map { !$0 }, isInNether: inNether)
}

private func stronghold(_ predictions: [NBBEvents.Prediction], player: NBBEvents.PlayerPosition?) -> NBBEvents.Stronghold {
    NBBEvents.Stronghold(resultType: .triangulation, predictions: predictions, eyeThrows: [], playerPosition: player)
}

private func triangulation(
    _ value: NBBEvents.Stronghold, display: NBBLocationDisplay = .fourFour, netherInNether: Bool = true
) -> TriangulationContent? {
    guard case .triangulation(let data) = NBBOverlayLayout.content(
        stronghold: value, blind: nil, divine: nil, boat: nil, allAdvancements: nil, maxPredictionRows: 5,
        locationDisplay: display, netherCoordinatesInNether: netherInNether) else { return nil }
    return data
}

/// Every expected value here is worked by hand from Ninjabrain Bot 1.5.2's source: `Chunk.fourFourX` (16·x + 4),
/// `eightEightX` (16·x + 8), `StructureInformation.xInNetherForDisplay` (`(int) Math.floor((16·x + 4) / 8.0)`) and
/// `getNetherDistance` (`overworldDistance / 8` on the `(int)` overworld distance, Java's truncating division).
@Suite("NBB coordinate column follows the dimension")
struct NBBNetherColumnTests {
    // MARK: - Ninjabrain Bot's numbers

    @Test(arguments: [
        // chunk x, chunk z, 4,4 block, 8,8 block
        (-84, 5, NBBBlock(x: -1340, z: 84), NBBBlock(x: -1336, z: 88)),
        (0, 0, NBBBlock(x: 4, z: 4), NBBBlock(x: 8, z: 8)),
        (-1, -1, NBBBlock(x: -12, z: -12), NBBBlock(x: -8, z: -8)),
        (7, -3, NBBBlock(x: 116, z: -44), NBBBlock(x: 120, z: -40)),
    ])
    func theLocationIsNinjabrainBotsForEachDisplayChoice(chunkX: Int, chunkZ: Int, fourFour: NBBBlock, eightEight: NBBBlock) {
        #expect(NBBStrongholdCoordinates.location(chunkX: chunkX, chunkZ: chunkZ, display: .fourFour) == fourFour)
        #expect(NBBStrongholdCoordinates.location(chunkX: chunkX, chunkZ: chunkZ, display: .eightEight) == eightEight)
        #expect(NBBStrongholdCoordinates.location(chunkX: chunkX, chunkZ: chunkZ, display: .chunk) == NBBBlock(x: chunkX, z: chunkZ))
    }

    @Test(arguments: [
        (-84, 5, NBBBlock(x: -168, z: 10)),   // floor(-1340 / 8 = -167.5) = -168; floor(84 / 8 = 10.5) = 10
        (-1, -1, NBBBlock(x: -2, z: -2)),     // floor(-12 / 8 = -1.5) = -2, not the truncated -1
        (0, 0, NBBBlock(x: 0, z: 0)),         // floor(4 / 8 = 0.5) = 0
        (7, -3, NBBBlock(x: 14, z: -6)),      // floor(116 / 8 = 14.5) = 14; floor(-44 / 8 = -5.5) = -6
        (-41, 108, NBBBlock(x: -82, z: 216)), // floor(-652 / 8 = -81.5) = -82; floor(1732 / 8 = 216.5) = 216
    ])
    func theNetherCoordinatesAreNinjabrainBotsFlooredFourFourBlockOverEight(chunkX: Int, chunkZ: Int, nether: NBBBlock) {
        #expect(NBBStrongholdCoordinates.nether(chunkX: chunkX, chunkZ: chunkZ) == nether)
    }

    @Test(arguments: [
        // API overworld distance, shown in the Overworld, shown in the Nether
        (1579.6, 1579, 197),  // (int) 1579.6 = 1579; 1579 / 8 = 197
        (1583.9, 1583, 197),  // 1583 / 8 = 197 (rounding would say 198)
        (7.9, 7, 0),
        (8.0, 8, 1),
        (0.0, 0, 0),
    ])
    func theDistanceIsNinjabrainBotsInEachDimension(overworld: Double, inOverworld: Int, inNether: Int) {
        #expect(NBBStrongholdCoordinates.distance(overworldDistance: overworld, inNether: false) == inOverworld)
        #expect(NBBStrongholdCoordinates.distance(overworldDistance: overworld, inNether: true) == inNether)
    }

    @Test func distancesThatJavaWouldSaturateDoNotTrap() {
        #expect(NBBStrongholdCoordinates.javaInt(.nan) == 0)
        #expect(NBBStrongholdCoordinates.javaInt(1e30) == Int(Int32.max))
        #expect(NBBStrongholdCoordinates.javaInt(-1e30) == Int(Int32.min))
        #expect(NBBStrongholdCoordinates.javaInt(-7.9) == -7, "Java's (int) truncates toward zero")
    }

    // MARK: - The swap

    @Test func inTheOverworldTheTableShowsTheLocationAndTheOverworldDistance() throws {
        let value = stronghold([NBBEvents.Prediction(chunkX: -84, chunkZ: 5, certainty: 0.9, overworldDistance: 1583.9)], player: player(inNether: false))
        let data = try #require(triangulation(value))
        #expect(data.column == .overworld)
        #expect(data.predictions[0].coordinates == NBBBlock(x: -1340, z: 84))
        #expect(data.predictions[0].distance == 1583)
    }

    @Test func inTheNetherTheTableShowsTheNetherCoordinatesAndTheNetherDistance() throws {
        let value = stronghold([NBBEvents.Prediction(chunkX: -84, chunkZ: 5, certainty: 0.9, overworldDistance: 1583.9)], player: player(inNether: true))
        let data = try #require(triangulation(value))
        #expect(data.column == .nether)
        #expect(data.predictions[0].coordinates == NBBBlock(x: -168, z: 10))
        #expect(data.predictions[0].distance == 197)
    }

    @Test func withTheSwapOffTheNetherShowsTheOverworldColumns() throws {
        let value = stronghold([NBBEvents.Prediction(chunkX: -84, chunkZ: 5, certainty: 0.9, overworldDistance: 1583.9)], player: player(inNether: true))
        let data = try #require(triangulation(value, netherInNether: false))
        #expect(data.column == .overworld)
        #expect(data.predictions[0].coordinates == NBBBlock(x: -1340, z: 84) && data.predictions[0].distance == 1583)
    }

    @Test func withoutAnF3CDimensionTheTableShowsTheOverworldColumns() throws {
        let prediction = NBBEvents.Prediction(chunkX: 1, chunkZ: 2, certainty: 0.9, overworldDistance: 100)
        #expect(try #require(triangulation(stronghold([prediction], player: nil))).column == .overworld)
        #expect(try #require(triangulation(stronghold([prediction], player: player(inNether: nil)))).column == .overworld)
    }

    @Test func theOverworldLocationFollowsTheDisplayChoice() throws {
        let value = stronghold([NBBEvents.Prediction(chunkX: 7, chunkZ: -3, certainty: 0.9, overworldDistance: 100)], player: player(inNether: false))
        #expect(try #require(triangulation(value, display: .eightEight)).predictions[0].coordinates == NBBBlock(x: 120, z: -40))
        #expect(try #require(triangulation(value, display: .chunk)).predictions[0].coordinates == NBBBlock(x: 7, z: -3))
        // In the Nether the display choice doesn't matter: Ninjabrain Bot's Nether column has no such choice.
        let nether = stronghold(value.predictions, player: player(inNether: true))
        #expect(try #require(triangulation(nether, display: .chunk)).predictions[0].coordinates == NBBBlock(x: 14, z: -6))
    }

    @Test func theAPIsPlayerPositionDecodesTheDimension() throws {
        let json = #"{"resultType":"TRIANGULATION","predictions":[],"eyeThrows":[],"playerPosition":{"isInOverworld":false,"isInNether":true,"xInOverworld":-800,"zInOverworld":96,"horizontalAngle":12.5}}"#
        let decoded = try JSONDecoder().decode(NBBEvents.Stronghold.self, from: Data(json.utf8))
        #expect(decoded.playerPosition?.isInNether == true)
        #expect(NBBOverlayLayout.coordinateColumn(for: decoded, netherCoordinatesInNether: true) == .nether)
    }

    // MARK: - Window mode

    @Test func windowModeShowsTheWindowsOwnLocationAndDistance() throws {
        let window = NBBEvents.Prediction(
            chunkX: -84, chunkZ: 5, certainty: 0.9, overworldDistance: 197,
            shownLocation: NBBBlock(x: -84, z: 5), shownNether: NBBBlock(x: -168, z: 10), shownDistance: 197)
        let data = try #require(triangulation(stronghold([window], player: nil), display: .fourFour))
        #expect(data.column == .windowLocation, "the window has no dimension to follow")
        #expect(data.predictions[0].coordinates == NBBBlock(x: -84, z: 5), "the window's own Location text, not sTools' 4,4 block")
        #expect(data.predictions[0].distance == 197)
    }

    @Test func eachColumnSaysWhatItShows() {
        #expect(NBBCoordinateColumn.overworld.title == "Overworld")
        #expect(NBBCoordinateColumn.nether.title == "Nether")
        #expect(NBBCoordinateColumn.windowLocation.title == "Location")
    }

    @Test func theDisplayChoicesAreNinjabrainBots() {
        #expect(NBBLocationDisplay.allCases.map(\.title) == ["(4, 4)", "(8, 8)", "Chunk"])
    }

    @Test func theCoordinatesReadAsTheOverlayWritesThem() {
        #expect(NBBBlock(x: -168, z: 10).text == "-168, 10")
    }

    // MARK: - Settings

    @Test func theSwapIsOnAndTheLocationIsFourFourByDefault() {
        let settings = NBBOverlaySettings()
        #expect(settings.showsNetherCoordinatesInNether)
        #expect(settings.locationDisplay == .fourFour, "Ninjabrain Bot 1.5.2's stronghold_display_type default is FOURFOUR")
    }

    @Test func theNewSettingsDecodeAndFallBackToTheirDefaults() throws {
        let set = try JSONDecoder().decode(
            NBBOverlaySettings.self, from: Data(#"{"showsNetherCoordinatesInNether":false,"locationDisplay":"chunk"}"#.utf8))
        #expect(!set.showsNetherCoordinatesInNether && set.locationDisplay == .chunk)
        let unknown = try JSONDecoder().decode(
            NBBOverlaySettings.self, from: Data(#"{"showsNetherCoordinatesInNether":"yes","locationDisplay":"sideways"}"#.utf8))
        #expect(unknown == NBBOverlaySettings.defaultValue)
        let old = try JSONDecoder().decode(NBBOverlaySettings.self, from: Data(#"{"width":400,"showsLocationColumn":false}"#.utf8))
        #expect(old.showsNetherCoordinatesInNether && old.locationDisplay == .fourFour)
        var round = NBBOverlaySettings()
        round.locationDisplay = .eightEight
        round.showsNetherCoordinatesInNether = false
        #expect(try JSONDecoder().decode(NBBOverlaySettings.self, from: JSONEncoder().encode(round)) == round)
    }
}
