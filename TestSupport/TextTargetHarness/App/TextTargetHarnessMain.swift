@preconcurrency import AppKit
import Darwin
import Foundation
import TextTargetHarnessCore

@main
enum TextTargetHarnessMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        do {
            if arguments.contains("--validate-contract") {
                let contractURL = try scenarioURL(arguments: arguments)
                let contract = try TargetHarnessContractLoader.load(from: contractURL)
                try writeJSON(
                    ContractValidationOutput(
                        schemaVersion: 1,
                        harnessId: contract.harnessId,
                        status: "passed",
                        scenarioCount: contract.scenarios.count
                    )
                )
                return
            }

            if arguments.contains("--privacy-smoke") {
                try runPrivacySmoke()
                return
            }

            if let index = arguments.firstIndex(of: "--probe-pid"),
               arguments.indices.contains(index + 1),
               let pid = Int32(arguments[index + 1]) {
                let result = AXTargetProbe().run(processIdentifier: pid)
                try writeJSON(result)
                if result.status == .tccRequired {
                    exit(77)
                }
                if result.status != .passed {
                    exit(1)
                }
                return
            }

            HarnessApplication.run(automationMode: arguments.contains("--automation"))
        } catch {
            let result = TargetHarnessResult(
                runId: "command",
                scenarioId: "harness-command",
                surface: "harness",
                status: .failed,
                outcome: "safeFallback",
                confirmedMutation: false,
                pasteboardChanged: false,
                assertions: [
                    HarnessAssertion(
                        id: "command",
                        passed: false,
                        detail: "Harness command failed: \(contentFreeFailureCode(error))."
                    )
                ]
            )
            try? writeJSON(result)
            exit(1)
        }
    }

    private static func scenarioURL(arguments: [String]) throws -> URL {
        if let index = arguments.firstIndex(of: "--scenarios"),
           arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1])
        }
        return URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent("TestSupport/TextTargetHarness/scenarios.json")
    }

    private static func runPrivacySmoke() throws {
        let environment = ProcessInfo.processInfo.environment
        let canaryKeys = [
            "WHISPERFLOW_PRIVACY_CANARY_TRANSCRIPT",
            "WHISPERFLOW_PRIVACY_CANARY_CONTEXT",
            "WHISPERFLOW_PRIVACY_CANARY_WINDOW_TITLE",
            "WHISPERFLOW_PRIVACY_CANARY_PATH",
            "WHISPERFLOW_PRIVACY_CANARY_KEY"
        ]
        let canaries = canaryKeys.compactMap { environment[$0] }
        guard canaries.count == canaryKeys.count,
              canaries.allSatisfy({ !$0.isEmpty }) else {
            throw HarnessCommandError.missingPrivacyCanary
        }

        let state = HarnessTargetState(
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            targetIdentifier: "privacy-smoke",
            sessionIdentifier: "local-only",
            selection: HarnessSelection(location: 0, length: 0),
            isFocused: true,
            isProtected: false,
            supportsSelectedText: true,
            supportsUnicodeFallback: true
        )
        let decision = TargetMutationPolicy().decision(
            captured: state,
            current: state,
            activeSessionIdentifier: "local-only"
        )
        let mutated = ConfirmedTextMutation.replacingUTF16Range(
            in: "",
            range: state.selection,
            with: canaries[0]
        )
        let inMemoryOnly = ([mutated].compactMap { $0 } + Array(canaries.dropFirst()))
            .joined(separator: "|")
        guard decision == .directAX,
              inMemoryOnly.utf8.count > canaries.reduce(0, { $0 + $1.utf8.count }) else {
            throw HarnessCommandError.privacySmokeInvariant
        }

        Thread.sleep(forTimeInterval: 0.8)
        try writeJSON(
            TargetHarnessResult(
                runId: "privacy-smoke",
                scenarioId: "local-memory-canary",
                surface: "in-memory",
                status: .passed,
                outcome: "directAX",
                confirmedMutation: true,
                pasteboardChanged: false,
                assertions: [
                    HarnessAssertion(
                        id: "in-memory-only",
                        passed: true,
                        detail: "synthetic canary was handled without persistence or network capability"
                    )
                ]
            )
        )
    }
}

private struct ContractValidationOutput: Codable {
    let schemaVersion: Int
    let harnessId: String
    let status: String
    let scenarioCount: Int
}

private enum HarnessCommandError: String, Error {
    case missingPrivacyCanary = "missing-privacy-canary"
    case privacySmokeInvariant = "privacy-smoke-invariant"
}

private func contentFreeFailureCode(_ error: any Error) -> String {
    (error as? HarnessCommandError)?.rawValue ?? "runtime-operation"
}

private func writeJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}
