import ASRBenchmarkCore
import Darwin
import Foundation

private enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case validationFailed(String)

    var description: String {
        switch self {
        case .usage(let message): "usage: \(message)"
        case .validationFailed(let category): "validation failed: \(category)"
        }
    }
}

@main
private struct ASRBenchmarkCLI {
    static func main() {
        do {
            let command = try CommandLineOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            switch command.mode {
            case "validate": try validate(command)
            case "report": try report(command)
            case "evaluate": try evaluate(command)
            case "run-offline": try runOffline(command)
            case "help", "--help", "-h": printHelp()
            default: throw CLIError.usage("unknown mode '\(command.mode)'\n\n\(helpText)")
            }
        } catch {
            let message = "asr-benchmark: \(sanitized(error))\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(2)
        }
    }

    private static func validate(_ options: CommandLineOptions) throws {
        let contractURL = try options.requiredURL("--contract")
        let manifestURL = try options.requiredURL("--manifest")
        let contract = try BenchmarkJSON.decode(CorpusContract.self, from: contractURL)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try BenchmarkJSON.decode(CorpusManifest.self, from: manifestData)
        let assetRoot = options.optionalURL("--asset-root")
        let manifestResult = CorpusValidator.validateManifest(
            manifest,
            against: contract,
            assetRoot: assetRoot
        )
        var issues = manifestResult.issues

        if let evidenceURL = options.optionalURL("--evidence") {
            let evidence = try BenchmarkJSON.decode(BenchmarkEvidence.self, from: evidenceURL)
            issues.append(
                contentsOf: EvidenceValidator.validate(
                    evidence,
                    manifest: manifest,
                    contract: contract,
                    manifestData: manifestData
                )
            )
        }

        if let scheduleURL = options.optionalURL("--schedule-output") {
            let candidateIDs = options.values("--candidate")
            guard !candidateIDs.isEmpty else {
                throw CLIError.usage("--schedule-output requires at least one --candidate")
            }
            let seed = try options.uint64("--seed")
            let schedule = RunScheduler.make(
                manifest: manifest,
                candidateIDs: candidateIDs,
                seed: seed,
                warmupRunsPerCandidate: contract.performanceSample.warmupRunsPerCandidate
            )
            try BenchmarkJSON.write(schedule, to: scheduleURL)
        }

        let uniqueIssues: [ValidationIssue] = Set(issues).sorted {
            $0.path == $1.path ? $0.code < $1.code : $0.path < $1.path
        }
        let result = ValidationResult(
            valid: uniqueIssues.isEmpty,
            releaseEligible: manifestResult.releaseEligible && uniqueIssues.isEmpty,
            corpusAssetsVerified: manifestResult.corpusAssetsVerified,
            issues: uniqueIssues
        )
        try BenchmarkJSON.write(result, to: options.optionalURL("--output"))
        if !result.valid { throw CLIError.validationFailed("contract, manifest, or evidence") }
    }

    private static func report(_ options: CommandLineOptions) throws {
        let contractURL = try options.requiredURL("--contract")
        let manifestURL = try options.requiredURL("--manifest")
        let evidenceURL = try options.requiredURL("--evidence")
        let contract = try BenchmarkJSON.decode(CorpusContract.self, from: contractURL)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try BenchmarkJSON.decode(CorpusManifest.self, from: manifestData)
        let evidence = try BenchmarkJSON.decode(BenchmarkEvidence.self, from: evidenceURL)
        let validation = CorpusValidator.validateManifest(
            manifest,
            against: contract,
            assetRoot: options.optionalURL("--asset-root")
        )
        guard validation.valid else { throw CLIError.validationFailed("manifest") }
        let result = try BenchmarkReporter.makeReport(
            contract: contract,
            manifest: manifest,
            manifestData: manifestData,
            evidence: evidence,
            corpusAssetsVerified: validation.corpusAssetsVerified
        )
        try BenchmarkJSON.write(result, to: options.optionalURL("--output"))
    }

    private static func evaluate(_ options: CommandLineOptions) throws {
        let gate = try options.required("--gate").lowercased()
        switch gate {
        case "asr-a", "a":
            let report = try BenchmarkJSON.decode(
                BenchmarkReport.self,
                from: try options.requiredURL("--report")
            )
            let result = ASRGateEvaluator.evaluateASRA(report)
            try BenchmarkJSON.write(result, to: options.optionalURL("--output"))
        case "asr-b", "b":
            let report = try BenchmarkJSON.decode(
                BenchmarkReport.self,
                from: try options.requiredURL("--report")
            )
            let prior = try BenchmarkJSON.decode(
                GateEvaluation.self,
                from: try options.requiredURL("--asr-a")
            )
            let result = ASRGateEvaluator.evaluateASRB(report, priorASRA: prior)
            try BenchmarkJSON.write(result, to: options.optionalURL("--output"))
        case "personal", "wf-personal-de-1":
            let report = try BenchmarkJSON.decode(
                RuntimeBenchmarkReport.self,
                from: try options.requiredURL("--runtime-report")
            )
            let result = PersonalBenchmarkGateEvaluator.evaluate(report)
            try BenchmarkJSON.write(result, to: options.optionalURL("--output"))
        default:
            throw CLIError.usage("--gate must be asr-a, asr-b, or personal")
        }
    }

    private static func runOffline(_ options: CommandLineOptions) throws {
        let manifest = try BenchmarkJSON.decode(
            CorpusManifest.self,
            from: try options.requiredURL("--manifest")
        )
        let commands = try options.values("--backend-command").map(parseBackendCommand)
        guard !commands.isEmpty else {
            throw CLIError.usage("run-offline requires at least one --backend-command BACKEND=EXECUTABLE")
        }
        let runner = OfflineASRBenchmarkRunner(invoker: ProcessASRBenchmarkCommandInvoker())
        let report = try runner.run(
            manifest: manifest,
            backendCommands: commands,
            seed: try options.optionalUInt64("--seed") ?? 4_242,
            warmupRunsPerCandidate: try options.optionalInt("--warmup-runs") ?? 0
        )
        try BenchmarkJSON.write(report, to: options.optionalURL("--output"))
    }

    private static func parseBackendCommand(_ value: String) throws -> BackendCommandConfiguration {
        let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let backendID = ASRBenchmarkBackendID(rawValue: String(parts[0])),
              !parts[1].isEmpty else {
            throw CLIError.usage("--backend-command must be BACKEND=EXECUTABLE where BACKEND is one of \(ASRBenchmarkBackendID.allCases.map(\.rawValue).joined(separator: ","))")
        }
        return BackendCommandConfiguration(
            backendID: backendID,
            executable: String(parts[1])
        )
    }

    private static func sanitized(_ error: Error) -> String {
        switch error {
        case let error as CLIError:
            error.description
        case BenchmarkValidationError.invalidContract(let issues):
            "invalid contract (\(issues.map(\.code).sorted().joined(separator: ",")))"
        case BenchmarkValidationError.invalidManifest(let issues):
            "invalid manifest (\(issues.map(\.code).sorted().joined(separator: ",")))"
        case BenchmarkValidationError.invalidEvidence(let issues):
            "invalid evidence (\(issues.map(\.code).sorted().joined(separator: ",")))"
        case is DecodingError:
            "invalid JSON schema"
        default:
            "operation failed (\(String(describing: type(of: error))))"
        }
    }

    private static func printHelp() {
        FileHandle.standardOutput.write(Data((helpText + "\n").utf8))
    }

    fileprivate static let helpText = """
    Reproducible WF-ASR-1 benchmark evidence tooling (no model download, no network).

    validate --contract FILE --manifest FILE [--evidence FILE] [--asset-root DIR]
             [--schedule-output FILE --candidate ID ... --seed UINT64] [--output FILE]
    report   --contract FILE --manifest FILE --evidence FILE [--asset-root DIR] [--output FILE]
    evaluate --gate asr-a --report FILE [--output FILE]
    evaluate --gate asr-b --report FILE --asr-a FILE [--output FILE]
    evaluate --gate personal --runtime-report FILE [--output FILE]
    run-offline --manifest FILE --backend-command BACKEND=EXECUTABLE ...
                [--seed UINT64] [--warmup-runs INT] [--output FILE]

    Omit --output to write JSON to stdout. A release gate remains ineligible until the
    complete WF-ASR-1 corpus, corpus hashes, both ASR-A candidates, and M5 measurements
    have been supplied explicitly. run-offline persists only content-free runtime
    observations; backend commands must emit BackendRunResult JSON without transcript text.
    """
}

private struct CommandLineOptions {
    let mode: String
    private let options: [String: [String]]

    init(arguments: [String]) throws {
        guard let mode = arguments.first else {
            throw CLIError.usage(ASRBenchmarkCLI.helpText)
        }
        self.mode = mode
        var parsed: [String: [String]] = [:]
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--") else {
                throw CLIError.usage("unexpected argument '\(key)'")
            }
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw CLIError.usage("missing value for \(key)")
            }
            parsed[key, default: []].append(arguments[index + 1])
            index += 2
        }
        options = parsed
    }

    func required(_ key: String) throws -> String {
        guard let values = options[key], values.count == 1, let value = values.first else {
            throw CLIError.usage("\(key) is required exactly once")
        }
        return value
    }

    func requiredURL(_ key: String) throws -> URL {
        URL(fileURLWithPath: try required(key))
    }

    func optionalURL(_ key: String) -> URL? {
        guard let value = options[key]?.last else { return nil }
        return URL(fileURLWithPath: value)
    }

    func values(_ key: String) -> [String] {
        options[key] ?? []
    }

    func uint64(_ key: String) throws -> UInt64 {
        guard let value = UInt64(try required(key)) else {
            throw CLIError.usage("\(key) must be an unsigned integer")
        }
        return value
    }

    func optionalUInt64(_ key: String) throws -> UInt64? {
        guard let value = options[key]?.last else { return nil }
        guard let parsed = UInt64(value) else {
            throw CLIError.usage("\(key) must be an unsigned integer")
        }
        return parsed
    }

    func optionalInt(_ key: String) throws -> Int? {
        guard let value = options[key]?.last else { return nil }
        guard let parsed = Int(value), parsed >= 0 else {
            throw CLIError.usage("\(key) must be a non-negative integer")
        }
        return parsed
    }
}
