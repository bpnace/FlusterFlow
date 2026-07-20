import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .boolean(let value) = self else { return nil }
        return value
    }
}

public struct TargetHarnessContract: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let harnessId: String
    public let scenarios: [TargetHarnessScenario]

    public init(schemaVersion: Int, harnessId: String, scenarios: [TargetHarnessScenario]) {
        self.schemaVersion = schemaVersion
        self.harnessId = harnessId
        self.scenarios = scenarios
    }
}

public struct TargetHarnessScenario: Codable, Equatable, Sendable {
    public let id: String
    public let surface: String
    public let configuration: [String: JSONValue]
    public let initial: [String: JSONValue]
    public let action: [String: JSONValue]
    public let expected: [String: JSONValue]

    public init(
        id: String,
        surface: String,
        configuration: [String: JSONValue],
        initial: [String: JSONValue],
        action: [String: JSONValue],
        expected: [String: JSONValue]
    ) {
        self.id = id
        self.surface = surface
        self.configuration = configuration
        self.initial = initial
        self.action = action
        self.expected = expected
    }
}

public struct TargetHarnessContractValidator: Sendable {
    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case unsupportedSchema(Int)
        case invalidHarnessID(String)
        case duplicateScenarioID(String)
        case missingField(scenarioID: String, field: String)
        case invalidOutcome(scenarioID: String, value: String)
        case successfulOutcomeNotConfirmed(scenarioID: String)
        case automaticPasteboardWrite(scenarioID: String)

        public var description: String {
            switch self {
            case .unsupportedSchema(let version):
                return "unsupported schemaVersion: \(version)"
            case .invalidHarnessID(let value):
                return "invalid harnessId: \(value)"
            case .duplicateScenarioID(let id):
                return "duplicate scenario id: \(id)"
            case .missingField(let id, let field):
                return "scenario \(id) is missing \(field)"
            case .invalidOutcome(let id, let value):
                return "scenario \(id) has invalid outcome \(value)"
            case .successfulOutcomeNotConfirmed(let id):
                return "scenario \(id) declares success without confirmedMutation"
            case .automaticPasteboardWrite(let id):
                return "scenario \(id) writes the general pasteboard outside explicit compatibility coverage"
            }
        }
    }

    private static let validOutcomes: Set<String> = [
        "directAX",
        "validatedAXValue",
        "guardedCGEvent",
        "guardedPaste",
        "safeFallback",
        "insertionDenied",
        "ignoredStaleSession",
        "contextOnly"
    ]

    private static let successfulOutcomes: Set<String> = [
        "directAX",
        "validatedAXValue",
        "guardedCGEvent",
        "guardedPaste"
    ]

    public init() {}

    public func validate(_ contract: TargetHarnessContract) throws {
        guard contract.schemaVersion == 1 else {
            throw ValidationError.unsupportedSchema(contract.schemaVersion)
        }
        guard contract.harnessId == "E-TARGET-HARNESS" else {
            throw ValidationError.invalidHarnessID(contract.harnessId)
        }

        var ids = Set<String>()
        for scenario in contract.scenarios {
            guard ids.insert(scenario.id).inserted else {
                throw ValidationError.duplicateScenarioID(scenario.id)
            }
            guard !scenario.surface.isEmpty else {
                throw ValidationError.missingField(scenarioID: scenario.id, field: "surface")
            }
            guard let outcome = scenario.expected["outcome"]?.stringValue else {
                throw ValidationError.missingField(scenarioID: scenario.id, field: "expected.outcome")
            }
            guard Self.validOutcomes.contains(outcome) else {
                throw ValidationError.invalidOutcome(scenarioID: scenario.id, value: outcome)
            }
            if Self.successfulOutcomes.contains(outcome),
               scenario.expected["confirmedMutation"]?.boolValue != true {
                throw ValidationError.successfulOutcomeNotConfirmed(scenarioID: scenario.id)
            }

            let writes = scenario.expected["pasteboardWriteCount"]
            if case .number(let value) = writes,
               value > 0,
               scenario.configuration["compatibilityPasteEnabled"]?.boolValue != true {
                throw ValidationError.automaticPasteboardWrite(scenarioID: scenario.id)
            }
        }
    }
}

public enum TargetHarnessContractLoader {
    public static func load(from url: URL) throws -> TargetHarnessContract {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let contract = try JSONDecoder().decode(TargetHarnessContract.self, from: data)
        try TargetHarnessContractValidator().validate(contract)
        return contract
    }
}

public enum HarnessRunStatus: String, Codable, Equatable, Sendable {
    case passed
    case failed
    case manual
    case tccRequired
}

public struct HarnessAssertion: Codable, Equatable, Sendable {
    public let id: String
    public let passed: Bool
    public let detail: String

    public init(id: String, passed: Bool, detail: String) {
        self.id = id
        self.passed = passed
        self.detail = detail
    }
}

public struct TargetHarnessResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let harnessId: String
    public let runId: String
    public let scenarioId: String
    public let surface: String
    public let status: HarnessRunStatus
    public let outcome: String
    public let confirmedMutation: Bool
    public let pasteboardChanged: Bool
    public let assertions: [HarnessAssertion]
    public let residual: String?

    public init(
        runId: String,
        scenarioId: String,
        surface: String,
        status: HarnessRunStatus,
        outcome: String,
        confirmedMutation: Bool,
        pasteboardChanged: Bool,
        assertions: [HarnessAssertion],
        residual: String? = nil
    ) {
        self.schemaVersion = 1
        self.harnessId = "E-TARGET-HARNESS"
        self.runId = runId
        self.scenarioId = scenarioId
        self.surface = surface
        self.status = status
        self.outcome = outcome
        self.confirmedMutation = confirmedMutation
        self.pasteboardChanged = pasteboardChanged
        self.assertions = assertions
        self.residual = residual
    }
}
