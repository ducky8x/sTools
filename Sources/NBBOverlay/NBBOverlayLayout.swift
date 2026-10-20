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
    var boatState: NBBEvents.BoatState?
}

/// One predictions-table row: only fields the API provides directly (spec 5.1.5's "nether" and
/// "angle" columns aren't computed here — see `NBBOverlaySettings`'s doc comment for why).
struct PredictionRow: Equatable, Sendable, Identifiable {
    var id: Int
    var chunkX: Int
    var chunkZ: Int
    var certaintyPercent: Int
    var overworldDistance: Double
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
            let rows = predictionRows(from: stronghold.predictions, maxRows: maxPredictionRows)
            return .triangulation(TriangulationContent(predictions: rows, eyeThrows: stronghold.eyeThrows, boatState: boat?.boatState))
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

    /// Up to `maxRows` predictions, dropping any whose certainty rounds to 0% (spec 5.1.3), in the
    /// order the API gave them (Ninjabrain Bot already sends them certainty-sorted, highest first).
    static func predictionRows(from predictions: [NBBEvents.Prediction], maxRows: Int) -> [PredictionRow] {
        var rows: [PredictionRow] = []
        for prediction in predictions {
            guard rows.count < maxRows else { break }
            let percent = Int((prediction.certainty * 100).rounded())
            guard percent > 0 else { continue }
            rows.append(PredictionRow(
                id: rows.count, chunkX: prediction.chunkX, chunkZ: prediction.chunkZ,
                certaintyPercent: percent, overworldDistance: prediction.overworldDistance))
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
