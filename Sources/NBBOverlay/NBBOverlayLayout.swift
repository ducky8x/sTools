import Foundation

/// What the overlay currently shows (spec 5.1.3): a pure function of the six subscriptions' latest
/// state, so every state → content decision is directly testable without any networking.
///
/// `stronghold.resultType` is the authoritative mode signal — it names which of the other endpoints'
/// data is current (`BLIND` means look at `blind.blindResult`, and so on), matching how Ninjabrain
/// Bot's own window has exactly one mode showing at a time.
enum NBBOverlayContent: Equatable, Sendable {
    case hidden
    case triangulation(TriangulationContent)
    case failed(eyeThrows: [NBBEvents.EyeThrow])
    case blind(NBBEvents.BlindResult)
    case divine(NBBEvents.DivineResult)
    case allAdvancements(NBBEvents.AllAdvancements)
}

struct TriangulationContent: Equatable, Sendable {
    var predictions: [PredictionRow]
    var eyeThrows: [NBBEvents.EyeThrow]
    /// Which of Ninjabrain Bot's columns the coordinate and distance columns show.
    var column: NBBCoordinateColumn = .overworld
}

/// Which of Ninjabrain Bot's values the predictions table's coordinate and distance columns show, and the mark that
/// says so. The dimension comes only from the last F3+C, as the API reports it (`playerPosition.isInNether`), the same
/// signal Ninjabrain Bot uses for its own distance column; nothing else is used to guess it.
enum NBBCoordinateColumn: Equatable, Sendable {
    /// Ninjabrain Bot's Location column and its distance in the Overworld.
    case overworld
    /// Ninjabrain Bot's Nether column and its distance in the Nether.
    case nether
    /// A Ninjabrain Bot window's own Location and distance texts. The window doesn't say which dimension the last F3+C
    /// was in, so the mark names the column instead of a dimension.
    case windowLocation

    var title: String {
        switch self {
        case .overworld: "Overworld"
        case .nether: "Nether"
        case .windowLocation: "Location"
        }
    }

    var spoken: String {
        switch self {
        case .overworld: "Overworld coordinates"
        case .nether: "Nether coordinates"
        case .windowLocation: "Ninjabrain Bot\u{2019}s location"
        }
    }
}

/// An x, z pair of whole blocks (or chunks, for the Chunk display), as Ninjabrain Bot writes them.
struct NBBBlock: Equatable, Sendable {
    var x: Int
    var z: Int

    /// How the overlay writes it: Ninjabrain Bot's "(x, z)" without the parentheses.
    var text: String { "\(x), \(z)" }
}

/// Ninjabrain Bot 1.5.2's own numbers for a predicted chunk, from its source: `Chunk.fourFourX`/`eightEightX`
/// (`ChunkPanel.formatStrongholdCoords`), `StructureInformation.xInNetherForDisplay` and `getNetherDistance`, and its
/// distance column's `formatDistanceInPlayersDimension`. Only these values are shown, never anything else worked out.
enum NBBStrongholdCoordinates {
    /// The Location column under Ninjabrain Bot's stronghold display choice.
    static func location(chunkX: Int, chunkZ: Int, display: NBBLocationDisplay) -> NBBBlock {
        switch display {
        case .fourFour: NBBBlock(x: 16 * chunkX + 4, z: 16 * chunkZ + 4)
        case .eightEight: NBBBlock(x: 16 * chunkX + 8, z: 16 * chunkZ + 8)
        case .chunk: NBBBlock(x: chunkX, z: chunkZ)
        }
    }

    /// The Nether column: `(int) Math.floor((16 * chunk + 4) / 8.0)` on each axis, so negatives round down.
    static func nether(chunkX: Int, chunkZ: Int) -> NBBBlock {
        NBBBlock(x: floorOverEight(16 * chunkX + 4), z: floorOverEight(16 * chunkZ + 4))
    }

    /// The distance column: the `(int)` overworld distance in the Overworld, and that divided by 8 with Java's integer
    /// division in the Nether.
    static func distance(overworldDistance: Double, inNether: Bool) -> Int {
        let overworld = javaInt(overworldDistance)
        return inNether ? overworld / 8 : overworld
    }

    /// Java's `(int)` cast of a double: toward zero, NaN as 0, and out-of-range values held at `int`'s limits (where
    /// Swift's `Int(_:)` would trap).
    static func javaInt(_ value: Double) -> Int {
        if value.isNaN { return 0 }
        if value >= Double(Int32.max) { return Int(Int32.max) }
        if value <= Double(Int32.min) { return Int(Int32.min) }
        return Int(value.rounded(.towardZero))
    }

    private static func floorOverEight(_ block: Int) -> Int {
        Int((Double(block) / 8).rounded(.down))
    }
}

/// How the overlay shows Ninjabrain Bot's boat state: the same gray, blue, green and red boat Ninjabrain Bot's own window
/// shows, with a word for each, so the boat reads at a glance during a run.
struct NBBBoatLook: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case gray, blue, green, red }

    var tone: Tone
    var title: String

    init(_ state: NBBEvents.BoatState) {
        switch state {
        case .none: tone = .gray; title = "No boat"
        case .measuring: tone = .blue; title = "Measuring boat"
        case .valid: tone = .green; title = "Boat ready"
        case .error: tone = .red; title = "Boat error"
        }
    }

    /// The boat's color: Ninjabrain Bot's four, lifted to read on the dark plate.
    var colorHex: String {
        switch tone {
        case .gray: "#9A968E"
        case .blue: "#5C9DF0"
        case .green: "#6FCB7A"
        case .red: "#E8695C"
        }
    }

    /// Whether this boat colors the plate: blue, green and red do; gray leaves the plate as it is.
    var tintsPlate: Bool { tone != .gray }
}

/// One predictions-table row: Ninjabrain Bot's own values for one prediction (spec 5.1.3), from the API or its window.
struct PredictionRow: Equatable, Sendable, Identifiable {
    var id: Int
    var chunkX: Int
    var chunkZ: Int
    var certaintyPercent: Int
    /// What the coordinate column shows: Ninjabrain Bot's Location or Nether value (`TriangulationContent.column`).
    var coordinates: NBBBlock
    /// What the distance column shows, in the same dimension as `coordinates`.
    var distance: Int
    /// The angle to travel at and the turn from where the player faces (+ right, − left), when known.
    var angle: Double? = nil
    var angleChange: Double? = nil
}

/// Ninjabrain Bot's travel angle and turn hint (`StructureInformation.updateWithPlayerPos` in 1.5.2): the angle from
/// the player's last F3+C position to the chunk's 4,4 block, in Minecraft's yaw (south 0°, west 90°), and the turn
/// from the player's facing to it, wrapped into −180…180 (+ is a turn right, shown "->").
enum NBBTravelAngle {
    static func angle(chunkX: Int, chunkZ: Int, from player: NBBEvents.PlayerPosition?) -> (angle: Double, change: Double?)? {
        guard let player, let x = player.xInOverworld, let z = player.zInOverworld else { return nil }
        let xDiff = Double(16 * chunkX + 4) - x
        let zDiff = Double(16 * chunkZ + 4) - z
        let angle = -atan2(xDiff, zDiff) * 180 / .pi
        guard let facing = player.horizontalAngle else { return (angle, nil) }
        var change = (angle - facing).truncatingRemainder(dividingBy: 360)
        if change > 180 { change -= 360 }
        if change < -180 { change += 360 }
        return (angle, change)
    }
}

enum NBBOverlayLayout {
    static func content(
        stronghold: NBBEvents.Stronghold?, blind: NBBEvents.Blind?, divine: NBBEvents.Divine?,
        boat: NBBEvents.Boat?, allAdvancements: NBBEvents.AllAdvancements?, maxPredictionRows: Int,
        locationDisplay: NBBLocationDisplay = .fourFour, netherCoordinatesInNether: Bool = true
    ) -> NBBOverlayContent {
        guard let stronghold else { return .hidden }
        switch stronghold.resultType {
        case .none:
            return .hidden
        case .triangulation:
            let column = coordinateColumn(for: stronghold, netherCoordinatesInNether: netherCoordinatesInNether)
            let rows = predictionRows(
                from: stronghold.predictions, maxRows: maxPredictionRows, player: stronghold.playerPosition,
                column: column, locationDisplay: locationDisplay)
            return .triangulation(TriangulationContent(predictions: rows, eyeThrows: stronghold.eyeThrows, column: column))
        case .failed:
            return .failed(eyeThrows: stronghold.eyeThrows)
        case .blind:
            guard let result = blind?.blindResult else { return .hidden }
            return .blind(result)
        case .divine:
            guard let result = divine?.divineResult else { return .hidden }
            return .divine(result)
        case .allAdvancements:
            guard let allAdvancements, allAdvancements.isAllAdvancementsModeEnabled else { return .hidden }
            return .allAdvancements(allAdvancements)
        }
    }

    /// The boat state the overlay shows, or nil to show no boat: off in the settings, nothing from Ninjabrain Bot yet, or
    /// gray (no boat angle) while the gray boat is hidden.
    static func boatToShow(_ boat: NBBEvents.Boat?, settings: NBBOverlaySettings) -> NBBEvents.BoatState? {
        guard settings.showsBoatState, let state = boat?.boatState else { return nil }
        if state == .none, !settings.showsGrayBoat { return nil }
        return state
    }

    /// Whether the boat alone is reason to show the overlay: measuring, ready or failed. A runner sets the boat before the
    /// first throw, when there is nothing else to show yet.
    static func boatCountsAsData(_ boat: NBBEvents.Boat?, settings: NBBOverlaySettings) -> Bool {
        guard let state = boatToShow(boat, settings: settings) else { return false }
        return state != .none
    }

    /// The boat color the plate takes, or nil to leave the plate as it is.
    static func plateTint(_ boat: NBBEvents.Boat?, settings: NBBOverlaySettings) -> NBBBoatLook? {
        guard settings.tintsPlateByBoat, let state = boat?.boatState else { return nil }
        let look = NBBBoatLook(state)
        return look.tintsPlate ? look : nil
    }

    /// Which columns the table shows: a window's own Location when the predictions come from a window; otherwise the
    /// Nether column when the last F3+C was in the Nether (and the swap is on), else the Location column.
    static func coordinateColumn(for stronghold: NBBEvents.Stronghold, netherCoordinatesInNether: Bool) -> NBBCoordinateColumn {
        if stronghold.predictions.contains(where: { $0.shownLocation != nil }) { return .windowLocation }
        return netherCoordinatesInNether && stronghold.playerPosition?.isInNether == true ? .nether : .overworld
    }

    /// Up to `maxRows` predictions, dropping any whose certainty rounds to 0% (spec 5.1.3), in the
    /// order the API gave them (Ninjabrain Bot already sends them certainty-sorted, highest first).
    static func predictionRows(
        from predictions: [NBBEvents.Prediction], maxRows: Int, player: NBBEvents.PlayerPosition? = nil,
        column: NBBCoordinateColumn = .overworld, locationDisplay: NBBLocationDisplay = .fourFour
    ) -> [PredictionRow] {
        var rows: [PredictionRow] = []
        for prediction in predictions {
            guard rows.count < maxRows else { break }
            let percent = Int((prediction.certainty * 100).rounded())
            guard percent > 0 else { continue }
            let worked = NBBTravelAngle.angle(chunkX: prediction.chunkX, chunkZ: prediction.chunkZ, from: player)
            let coordinates: NBBBlock
            let distance: Int
            switch column {
            case .overworld:
                coordinates = NBBStrongholdCoordinates.location(chunkX: prediction.chunkX, chunkZ: prediction.chunkZ, display: locationDisplay)
                distance = NBBStrongholdCoordinates.distance(overworldDistance: prediction.overworldDistance, inNether: false)
            case .nether:
                coordinates = NBBStrongholdCoordinates.nether(chunkX: prediction.chunkX, chunkZ: prediction.chunkZ)
                distance = NBBStrongholdCoordinates.distance(overworldDistance: prediction.overworldDistance, inNether: true)
            case .windowLocation:
                // Only the window's own texts; a row without them isn't shown rather than filled in by sTools.
                guard let shownLocation = prediction.shownLocation, let shownDistance = prediction.shownDistance else { continue }
                coordinates = shownLocation
                distance = shownDistance
            }
            rows.append(PredictionRow(
                id: rows.count, chunkX: prediction.chunkX, chunkZ: prediction.chunkZ,
                certaintyPercent: percent, coordinates: coordinates, distance: distance,
                angle: prediction.shownAngle ?? worked?.angle, angleChange: prediction.shownAngleChange ?? worked?.change))
        }
        return rows
    }

    /// Information messages are shown under the main block in every state (spec 5.1.3), HTML removed.
    static func plainTextMessages(from messages: [NBBEvents.InformationMessage]) -> [(severity: NBBEvents.MessageSeverity, text: String)] {
        messages.map { ($0.severity, stripHTML($0.message)) }
    }

    private static func stripHTML(_ text: String) -> String {
        var result = ""
        var insideTag = false
        for character in text {
            if character == "<" { insideTag = true; continue }
            if character == ">" { insideTag = false; continue }
            if !insideTag { result.append(character) }
        }
        return result
    }
}
