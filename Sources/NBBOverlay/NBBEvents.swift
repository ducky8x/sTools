import Foundation

/// Decoded shapes of Ninjabrain Bot's `/api/v1/*` JSON (spec 5.1.2), verified against its wiki and
/// 1.5.2 source. Unknown fields are ignored by `JSONDecoder` automatically; a field documented as
/// "`Dto` or `{}`" decodes to `nil` when the object is present but empty (`try?` below — an empty
/// object fails to decode the inner type's required fields, which `try?` turns into `nil`).
public enum NBBEvents {
    public struct Position: Codable, Equatable, Sendable {
        public var xInOverworld: Double
        public var zInOverworld: Double
        public var travelAngle: Double
        public var overworldDistance: Double
    }

    public struct PlayerPosition: Codable, Equatable, Sendable {
        public var xInOverworld: Double?
        public var zInOverworld: Double?
        public var horizontalAngle: Double?
        public var isInOverworld: Bool?
        public var isInNether: Bool?
    }

    public struct Prediction: Codable, Equatable, Sendable {
        public var chunkX: Int
        public var chunkZ: Int
        public var certainty: Double
        public var overworldDistance: Double
    }

    public struct EyeThrow: Codable, Equatable, Sendable {
        public var xInOverworld: Double
        public var zInOverworld: Double
        public var angle: Double
        public var angleWithoutCorrection: Double
        public var correction: Double
        /// 1.5.2+; absent on older versions.
        public var correctionIncrements: Int?
        public var error: Double
        /// Not an enumerated set in the wiki; kept as the server's own string rather than guessing cases.
        public var type: String
    }

    public enum ResultType: String, Codable, Sendable {
        case none = "NONE"
        case triangulation = "TRIANGULATION"
        case failed = "FAILED"
        case blind = "BLIND"
        case divine = "DIVINE"
        case allAdvancements = "ALL_ADVANCEMENTS"
    }

    /// `GET /api/v1/stronghold`.
    public struct Stronghold: Codable, Equatable, Sendable {
        public var resultType: ResultType
        public var predictions: [Prediction]
        public var eyeThrows: [EyeThrow]
        public var playerPosition: PlayerPosition?

        public init(resultType: ResultType, predictions: [Prediction], eyeThrows: [EyeThrow], playerPosition: PlayerPosition?) {
            self.resultType = resultType
            self.predictions = predictions
            self.eyeThrows = eyeThrows
            self.playerPosition = playerPosition
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            resultType = try container.decodeIfPresent(ResultType.self, forKey: .resultType) ?? .none
            predictions = try container.decodeIfPresent([Prediction].self, forKey: .predictions) ?? []
            eyeThrows = try container.decodeIfPresent([EyeThrow].self, forKey: .eyeThrows) ?? []
            playerPosition = try? container.decode(PlayerPosition.self, forKey: .playerPosition)
        }
    }

    public struct BlindResult: Codable, Equatable, Sendable {
        public var evaluation: String
        public var xInNether: Double
        public var zInNether: Double
        public var highrollThreshold: Double
        public var highrollProbability: Double
        public var improveDirection: Double
        public var improveDistance: Double
    }

    /// `GET /api/v1/blind`.
    public struct Blind: Codable, Equatable, Sendable {
        public var isBlindModeEnabled: Bool
        public var hasDivine: Bool
        public var blindResult: BlindResult?

        public init(isBlindModeEnabled: Bool, hasDivine: Bool, blindResult: BlindResult?) {
            self.isBlindModeEnabled = isBlindModeEnabled
            self.hasDivine = hasDivine
            self.blindResult = blindResult
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isBlindModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .isBlindModeEnabled) ?? false
            hasDivine = try container.decodeIfPresent(Bool.self, forKey: .hasDivine) ?? false
            blindResult = try? container.decode(BlindResult.self, forKey: .blindResult)
        }
    }

    public struct DivineResult: Codable, Equatable, Sendable {
        public var fossilXCoordinate: Double
        public var formattedSafeCoords: String
        public var formattedHighrollCoords: String
    }

    /// `GET /api/v1/divine`.
    public struct Divine: Codable, Equatable, Sendable {
        public var isDivineModeEnabled: Bool
        public var divineResult: DivineResult?

        public init(isDivineModeEnabled: Bool, divineResult: DivineResult?) {
            self.isDivineModeEnabled = isDivineModeEnabled
            self.divineResult = divineResult
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isDivineModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .isDivineModeEnabled) ?? false
            divineResult = try? container.decode(DivineResult.self, forKey: .divineResult)
        }
    }

    public enum BoatState: String, Codable, Sendable {
        case none = "NONE", error = "ERROR", measuring = "MEASURING", valid = "VALID"
    }

    /// `GET /api/v1/boat`.
    public struct Boat: Codable, Equatable, Sendable {
        public var boatState: BoatState
        public var boatAngle: Double?

        public init(boatState: BoatState, boatAngle: Double?) {
            self.boatState = boatState
            self.boatAngle = boatAngle
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            boatState = try container.decodeIfPresent(BoatState.self, forKey: .boatState) ?? .none
            boatAngle = try container.decodeIfPresent(Double.self, forKey: .boatAngle)
        }
    }

    public enum MessageSeverity: String, Codable, Sendable {
        case info = "INFO", warning = "WARNING", error = "ERROR"
    }

    public struct InformationMessage: Codable, Equatable, Sendable {
        public var severity: MessageSeverity
        /// Not an enumerated set in the wiki; kept as the server's own string.
        public var type: String
        /// May contain HTML, per spec 5.1.3's "HTML tags removed" display rule.
        public var message: String
    }

    /// `GET /api/v1/information-messages` (1.5.2+).
    public struct InformationMessages: Codable, Equatable, Sendable {
        public var informationMessages: [InformationMessage]

        public init(informationMessages: [InformationMessage]) {
            self.informationMessages = informationMessages
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            informationMessages = try container.decodeIfPresent([InformationMessage].self, forKey: .informationMessages) ?? []
        }
    }

    /// `GET /api/v1/all-advancements`.
    public struct AllAdvancements: Codable, Equatable, Sendable {
        public var isAllAdvancementsModeEnabled: Bool
        public var spawn: Position?
        public var monument: Position?
        public var stronghold: Position?
        public var outpost: Position?
        public var deepDark: Position?
        public var cityQuery: Position?
        public var shulkerTransport: Position?
        public var generalLocation: Position?

        public init(
            isAllAdvancementsModeEnabled: Bool, spawn: Position? = nil, monument: Position? = nil,
            stronghold: Position? = nil, outpost: Position? = nil, deepDark: Position? = nil,
            cityQuery: Position? = nil, shulkerTransport: Position? = nil, generalLocation: Position? = nil
        ) {
            self.isAllAdvancementsModeEnabled = isAllAdvancementsModeEnabled
            self.spawn = spawn
            self.monument = monument
            self.stronghold = stronghold
            self.outpost = outpost
            self.deepDark = deepDark
            self.cityQuery = cityQuery
            self.shulkerTransport = shulkerTransport
            self.generalLocation = generalLocation
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isAllAdvancementsModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAllAdvancementsModeEnabled) ?? false
            spawn = try? container.decode(Position.self, forKey: .spawn)
            monument = try? container.decode(Position.self, forKey: .monument)
            stronghold = try? container.decode(Position.self, forKey: .stronghold)
            outpost = try? container.decode(Position.self, forKey: .outpost)
            deepDark = try? container.decode(Position.self, forKey: .deepDark)
            cityQuery = try? container.decode(Position.self, forKey: .cityQuery)
            shulkerTransport = try? container.decode(Position.self, forKey: .shulkerTransport)
            generalLocation = try? container.decode(Position.self, forKey: .generalLocation)
        }
    }

    /// `GET /api/v1/version`.
    public struct Version: Codable, Equatable, Sendable {
        public var version: String
    }
}
