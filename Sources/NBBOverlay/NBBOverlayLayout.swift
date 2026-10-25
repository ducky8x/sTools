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

/// One predictions-table row: only fields the API provides directly (spec 5.1.5's "nether" and
/// "angle" columns aren't computed here — see `NBBOverlaySettings`'s doc comment for why).
struct PredictionRow: Equatable, Sendable, Identifiable {
    var id: Int
    var chunkX: Int
    var chunkZ: Int
    var certaintyPercent: Int
    var overworldDistance: Double
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
        boat: NBBEvents.Boat?, allAdvancements: NBBEvents.AllAdvancements?, maxPredictionRows: Int
    ) -> NBBOverlayContent {
        guard let stronghold else { return .hidden }
        switch stronghold.resultType {
        case .none:
            return .hidden
        case .triangulation:
            let rows = predictionRows(from: stronghold.predictions, maxRows: maxPredictionRows, player: stronghold.playerPosition)
            return .triangulation(TriangulationContent(predictions: rows, eyeThrows: stronghold.eyeThrows))
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

    /// Up to `maxRows` predictions, dropping any whose certainty rounds to 0% (spec 5.1.3), in the
    /// order the API gave them (Ninjabrain Bot already sends them certainty-sorted, highest first).
    static func predictionRows(from predictions: [NBBEvents.Prediction], maxRows: Int, player: NBBEvents.PlayerPosition? = nil) -> [PredictionRow] {
        var rows: [PredictionRow] = []
        for prediction in predictions {
            guard rows.count < maxRows else { break }
            let percent = Int((prediction.certainty * 100).rounded())
            guard percent > 0 else { continue }
            let worked = NBBTravelAngle.angle(chunkX: prediction.chunkX, chunkZ: prediction.chunkZ, from: player)
            rows.append(PredictionRow(
                id: rows.count, chunkX: prediction.chunkX, chunkZ: prediction.chunkZ,
                certaintyPercent: percent, overworldDistance: prediction.overworldDistance,
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
