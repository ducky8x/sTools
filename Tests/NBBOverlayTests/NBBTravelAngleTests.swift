import Foundation
import Testing
@testable import NBBOverlay

private func player(_ x: Double, _ z: Double, facing: Double?) -> NBBEvents.PlayerPosition {
    NBBEvents.PlayerPosition(xInOverworld: x, zInOverworld: z, horizontalAngle: facing, isInOverworld: true, isInNether: false)
}

/// Checked against Ninjabrain Bot 1.5.2's `StructureInformation.updateWithPlayerPos` worked by hand.
@Suite("NBB travel angle")
struct NBBTravelAngleTests {
    @Test func aimsAtTheChunks44BlockInMinecraftsYaw() throws {
        // From the origin, chunk (0, 10)'s 4,4 block is (4, 164): almost due south (0°), a hair east.
        let south = try #require(NBBTravelAngle.angle(chunkX: 0, chunkZ: 10, from: player(0, 0, facing: 0)))
        #expect(abs(south.angle - (-atan2(4.0, 164.0) * 180 / .pi)) < 1e-9)
        // Chunk (-10, 0)'s block (-156, 4) is west, about +88.5°.
        let west = try #require(NBBTravelAngle.angle(chunkX: -10, chunkZ: 0, from: player(0, 0, facing: 0)))
        #expect(abs(west.angle - 88.531) < 0.001)
    }

    @Test func theChangeIsTheTurnFromTheFacingWrappedToHalfATurn() throws {
        let behind = try #require(NBBTravelAngle.angle(chunkX: -10, chunkZ: 0, from: player(0, 0, facing: -90)))
        #expect(abs(behind.change! - 178.531) < 0.001)
        // Facing 170°, a target at about −170° is a 20° turn right, not 340° left.
        let x = -sin(-170 * Double.pi / 180) * 1600, z = cos(-170 * Double.pi / 180) * 1600
        let wrap = try #require(NBBTravelAngle.angle(chunkX: Int((x - 4) / 16), chunkZ: Int((z - 4) / 16), from: player(0, 0, facing: 170)))
        #expect(wrap.change! > 0 && wrap.change! < 40)
    }

    @Test func withoutAPositionThereIsNoAngleAndWithoutAFacingNoChange() {
        #expect(NBBTravelAngle.angle(chunkX: 1, chunkZ: 1, from: nil) == nil)
        #expect(NBBTravelAngle.angle(chunkX: 1, chunkZ: 1, from: player(0, 0, facing: nil))?.change == nil)
    }

    @Test func theTableRowsCarryTheAngleAndItsChange() {
        let stronghold = NBBEvents.Stronghold(
            resultType: .triangulation,
            predictions: [NBBEvents.Prediction(chunkX: -10, chunkZ: 0, certainty: 0.9, overworldDistance: 156)],
            eyeThrows: [], playerPosition: player(0, 0, facing: 80))
        guard case .triangulation(let data) = NBBOverlayLayout.content(
            stronghold: stronghold, blind: nil, divine: nil, boat: nil, allAdvancements: nil, maxPredictionRows: 5) else {
            Issue.record("expected triangulation"); return
        }
        #expect(abs((data.predictions.first?.angle ?? 0) - 88.531) < 0.001)
        #expect(abs((data.predictions.first?.angleChange ?? 0) - 8.531) < 0.001)
    }

    @Test func theChangeReadsLikeNinjabrainBotsWithAnArrow() {
        #expect(NBBAngleChange.text(47.44) == "\u{2192} 47.4")
        #expect(NBBAngleChange.text(-113.7) == "\u{2190} 113.7")
        #expect(NBBAngleChange.spoken(-113.7) == "Turn left 113.7 degrees")
        #expect(NBBAngleChange.closeness(0) == 1 && NBBAngleChange.closeness(-180) == 0)
    }

    @Test func theAngleColumnsAreOnByDefault() {
        let settings = NBBOverlaySettings()
        #expect(settings.showsAngleColumn && settings.showsAngleChangeColumn)
    }

    /// The API's JSON has no angle fields; decoding still works and leaves them to be worked out.
    @Test func aPredictionFromTheAPIDecodesWithoutAngles() throws {
        let prediction = try JSONDecoder().decode(NBBEvents.Prediction.self, from: Data(#"{"chunkX":1,"chunkZ":2,"certainty":0.5,"overworldDistance":10}"#.utf8))
        #expect(prediction.shownAngle == nil && prediction.chunkZ == 2)
    }
}
