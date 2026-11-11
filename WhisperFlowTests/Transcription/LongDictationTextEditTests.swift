@preconcurrency import AppKit
@preconcurrency import ApplicationServices
import Foundation
import XCTest
@testable import WhisperFlow

final class LongDictationTextEditTests: XCTestCase, @unchecked Sendable {
    func testLongSyntheticDictationIntoTextEditWhenExplicitlyRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FLUSTERFLOW_RUN_LONG_DICTATION_TEXTEDIT"] == "1" else {
            throw XCTSkip("Set FLUSTERFLOW_RUN_LONG_DICTATION_TEXTEDIT=1 for the acoustic TextEdit benchmark")
        }
        guard AXIsProcessTrusted() else {
            XCTFail("The benchmark process needs Accessibility permission before it can use the isolated TextEdit document")
            return
        }
        guard let audioPath = environment["FLUSTERFLOW_ACOUSTIC_SMOKE_AUDIO"],
              let reference = environment["FLUSTERFLOW_WHISPER_SMOKE_REFERENCE"],
              !audioPath.isEmpty,
              !reference.isEmpty else {
            XCTFail("Set FLUSTERFLOW_ACOUSTIC_SMOKE_AUDIO and FLUSTERFLOW_WHISPER_SMOKE_REFERENCE")
            return
        }

        let documentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flusterflow-long-dictation-\(UUID().uuidString).txt")
        try Data().write(to: documentURL, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: documentURL) }

        let textEdit = try await openIsolatedTextEdit(documentURL: documentURL)
        defer {
            if !textEdit.isTerminated {
                textEdit.terminate()
            }
        }
        guard textEdit.activate(options: [.activateAllWindows]) else {
            XCTFail("Could not activate the isolated TextEdit document")
            return
        }
        try await waitForFrontmost(processIdentifier: textEdit.processIdentifier)

        let store = AudioBufferStore()
        let capture = AVAudioEngineCapture(store: store)
        let recognizer = WhisperKitRecognizer(
            sampleAccess: store,
            modelStore: installedModelStore(.whisperLargeV3Turbo),
            tokenizerStore: installedModelStore(.whisperLargeV3Tokenizer),
            backend: .whisperKitLargeV3Turbo
        )
        let sessionID = DictationSessionID(rawValue: 71_001)
        let hints = RecognitionHints(language: .german, terms: [], prioritizedLexiconTerms: [])
        let playback = Process()
        playback.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        playback.arguments = [audioPath]
        defer {
            if playback.isRunning {
                playback.terminate()
            }
        }

        try await capture.startCapture(for: sessionID)
        try await recognizer.startRecognitionSession(hints: hints, sessionID: sessionID)
        let streaming = Task {
            var offset = 0
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(250))
                guard let batch = try await capture.incrementalAudioBatch(
                    for: sessionID,
                    afterFrameOffset: offset
                ) else {
                    continue
                }
                offset = batch.nextFrameOffset
                _ = try await recognizer.updateRecognitionSession(
                    with: batch.chunk,
                    sessionID: sessionID
                )
            }
        }
        defer {
            streaming.cancel()
            Task { await recognizer.stopRecognitionSession(sessionID: sessionID) }
        }

        try await Task.sleep(for: .milliseconds(250))
        try playback.run()
        while playback.isRunning {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(playback.terminationStatus, 0)

        let clock = ContinuousClock()
        let release = clock.now
        streaming.cancel()
        _ = await streaming.result
        await recognizer.stopRecognitionSession(sessionID: sessionID)
        let input = try await capture.finishCapture(for: sessionID)
        defer {
            Task { await capture.release(input) }
        }
        let transcript = try await recognizer.finalizeRecognitionSession(
            input,
            hints: hints,
            sessionID: sessionID
        )

        try await waitForFrontmost(processIdentifier: textEdit.processIdentifier)
        let insertionStarted = clock.now
        let registry = AccessibilityTargetRegistry()
        let targetResult = await registry.captureTarget(for: sessionID)
        guard case .captured(let target) = targetResult,
              target.snapshot.processIdentifier == textEdit.processIdentifier else {
            XCTFail("TextEdit was not the focused target at insertion")
            return
        }
        let insertion = await registry.insertSelectedText(
            transcript.text,
            into: target.snapshot,
            sessionID: sessionID,
            permit: InsertionCommitPermit()
        )
        let insertedAt = clock.now
        await registry.releaseTargets(for: sessionID)
        XCTAssertEqual(insertion, .confirmed)

        let targetText = try focusedText(in: textEdit)
        XCTAssertEqual(targetText, transcript.text)
        let quality = wordQuality(reference: reference, candidate: transcript.text)
        let stopMilliseconds = milliseconds(release.duration(to: insertedAt))
        let insertionMilliseconds = milliseconds(insertionStarted.duration(to: insertedAt))
        var metrics: [String] = [
            "FLUSTERFLOW_LONG_TEXTEDIT",
            "stop_to_insert_ms=\(stopMilliseconds)",
            "insertion_ms=\(insertionMilliseconds)",
            "reference_words=\(quality.referenceWords)",
            "candidate_words=\(quality.candidateWords)",
            "edits=\(quality.edits)",
            "deletions=\(quality.deletions)",
            "insertions=\(quality.insertions)",
            "substitutions=\(quality.substitutions)",
            "adjacent_duplicates=\(quality.adjacentDuplicates)"
        ]
        if environment["FLUSTERFLOW_LONG_TEXTEDIT_COMPARE_BATCH"] == "1" {
            let batchTranscript = try await recognizer.transcribe(
                input,
                hints: hints,
                sessionID: DictationSessionID(rawValue: 71_002)
            )
            let batchQuality = wordQuality(reference: reference, candidate: batchTranscript.text)
            let matchesBatchWords = words(batchTranscript.text) == words(transcript.text)
            metrics.append(contentsOf: [
                "batch_edits=\(batchQuality.edits)",
                "batch_deletions=\(batchQuality.deletions)",
                "batch_insertions=\(batchQuality.insertions)",
                "batch_substitutions=\(batchQuality.substitutions)",
                "matches_batch_words=\(matchesBatchWords)"
            ])
        }
        print(metrics.joined(separator: " "))
    }

    private func openIsolatedTextEdit(documentURL: URL) async throws -> NSRunningApplication {
        let textEditURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let previousProcessIdentifiers = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit")
                .map(\.processIdentifier)
        )
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let application = try await NSWorkspace.shared.open(
            [documentURL],
            withApplicationAt: textEditURL,
            configuration: configuration
        )
        guard !previousProcessIdentifiers.contains(application.processIdentifier) else {
            throw XCTSkip("TextEdit did not create an isolated process")
        }
        return application
    }

    private func waitForFrontmost(processIdentifier: pid_t) async throws {
        for _ in 0..<30 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw XCTSkip("TextEdit did not become frontmost in time")
    }

    private func focusedText(in application: NSRunningApplication) throws -> String {
        let element = AXUIElementCreateApplication(application.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            throw XCTSkip("TextEdit did not expose a focused accessibility element")
        }
        let textElement = unsafeBitCast(focusedValue, to: AXUIElement.self)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            textElement,
            kAXValueAttribute as CFString,
            &value
        ) == .success,
        let value = value as? String else {
            throw XCTSkip("TextEdit did not expose the focused text value")
        }
        return value
    }

    private func installedModelStore(_ manifest: ModelManifest) -> LocalModelStore {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/FlusterFlow/Models")
        return LocalModelStore(
            directory: manifest.installationDirectory(in: root),
            manifest: manifest
        )
    }

    private func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }

    private func wordQuality(reference: String, candidate: String) -> WordQuality {
        let expected = words(reference)
        let actual = words(candidate)
        var row = (0...actual.count).map {
            AlignmentScore(cost: $0, deletions: 0, insertions: $0, substitutions: 0)
        }
        for (expectedIndex, expectedWord) in expected.enumerated() {
            var next = [
                AlignmentScore(
                    cost: expectedIndex + 1,
                    deletions: expectedIndex + 1,
                    insertions: 0,
                    substitutions: 0
                )
            ]
            for (actualIndex, actualWord) in actual.enumerated() {
                let deletion = row[actualIndex + 1].addingDeletion()
                let insertion = next[actualIndex].addingInsertion()
                let substitution = row[actualIndex].addingSubstitution(
                    expectedWord == actualWord
                )
                next.append(minimum(deletion, insertion, substitution))
            }
            row = next
        }
        let duplicates = zip(actual, actual.dropFirst()).filter(==).count
        let score = row[actual.count]
        return WordQuality(
            referenceWords: expected.count,
            candidateWords: actual.count,
            edits: score.cost,
            deletions: score.deletions,
            insertions: score.insertions,
            substitutions: score.substitutions,
            adjacentDuplicates: duplicates
        )
    }

    private func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private func minimum(
        _ first: AlignmentScore,
        _ second: AlignmentScore,
        _ third: AlignmentScore
    ) -> AlignmentScore {
        [first, second, third].min {
            ($0.cost, $0.substitutions, $0.deletions, $0.insertions)
                < ($1.cost, $1.substitutions, $1.deletions, $1.insertions)
        }!
    }
}

private struct WordQuality {
    let referenceWords: Int
    let candidateWords: Int
    let edits: Int
    let deletions: Int
    let insertions: Int
    let substitutions: Int
    let adjacentDuplicates: Int
}

private struct AlignmentScore {
    let cost: Int
    let deletions: Int
    let insertions: Int
    let substitutions: Int

    func addingDeletion() -> Self {
        Self(
            cost: cost + 1,
            deletions: deletions + 1,
            insertions: insertions,
            substitutions: substitutions
        )
    }

    func addingInsertion() -> Self {
        Self(
            cost: cost + 1,
            deletions: deletions,
            insertions: insertions + 1,
            substitutions: substitutions
        )
    }

    func addingSubstitution(_ wordsMatch: Bool) -> Self {
        Self(
            cost: cost + (wordsMatch ? 0 : 1),
            deletions: deletions,
            insertions: insertions,
            substitutions: substitutions + (wordsMatch ? 0 : 1)
        )
    }
}
