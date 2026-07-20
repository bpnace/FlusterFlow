@preconcurrency import ApplicationServices
import AppKit
import XCTest
@testable import WhisperFlow

final class AccessibilityAndInsertionTests: XCTestCase, @unchecked Sendable {
    func testContextOffDoesNotReadFocusedElementText() async throws {
        let sessionID = DictationSessionID(rawValue: 1)
        let target = makeTarget(sessionID: sessionID)
        let fake = FakeAccessibilityTargets(
            capture: .captured(
                RegisteredTargetCapture(
                    snapshot: target,
                    targetKind: .document,
                    security: .standard
                )
            ),
            context: "must-not-be-read"
        )
        let service = AccessibilityContextService(
            registry: fake,
            contextEnabled: { false }
        )

        let result = try await service.capture(for: sessionID)
        let contextReads = await fake.contextReadCount()

        XCTAssertEqual(result.context, .unavailable(targetKind: .document))
        XCTAssertEqual(contextReads, 0)
    }

    func testSensitiveTargetFailsClosedWithoutReadingText() async throws {
        let sessionID = DictationSessionID(rawValue: 2)
        let target = makeTarget(sessionID: sessionID)
        let fake = FakeAccessibilityTargets(
            capture: .captured(
                RegisteredTargetCapture(
                    snapshot: target,
                    targetKind: .unknown,
                    security: .deniedSensitive
                )
            ),
            context: "secret-canary"
        )
        let service = AccessibilityContextService(registry: fake)

        let result = try await service.capture(for: sessionID)
        let contextReads = await fake.contextReadCount()

        XCTAssertEqual(result.context.availability, .deniedSensitive)
        XCTAssertNil(result.context.boundedText)
        XCTAssertEqual(contextReads, 0)
    }

    func testContextIsDefenseInDepthBoundedToFifteenHundredCharacters() async throws {
        let sessionID = DictationSessionID(rawValue: 3)
        let target = makeTarget(sessionID: sessionID)
        let fake = FakeAccessibilityTargets(
            capture: .captured(
                RegisteredTargetCapture(
                    snapshot: target,
                    targetKind: .chat,
                    security: .standard
                )
            ),
            context: String(repeating: "x", count: 2_000)
        )
        let service = AccessibilityContextService(registry: fake)

        let result = try await service.capture(for: sessionID)

        XCTAssertEqual(result.context.availability, .available)
        XCTAssertEqual(result.context.boundedText?.count, 1_500)
    }

    func testVisibleChatContextIsCompactedWithoutSensitiveOrInterfaceFragments() {
        let result = BoundedContextComposer.compose(
            focusedFieldText: "  Bitte ergänze das logisch.  ",
            visibleFragments: [
                VisibleContextFragment(text: "New chat"),
                VisibleContextFragment(text: "Das Projekt heißt Nebelstern."),
                VisibleContextFragment(text: "sk-private-canary", isSensitive: true),
                VisibleContextFragment(text: "Das Projekt heißt Nebelstern.")
            ],
            maximumCharacters: 1_500
        )

        XCTAssertEqual(
            result,
            "Das Projekt heißt Nebelstern.\nBitte ergänze das logisch."
        )
        XCTAssertFalse(result?.contains("private-canary") == true)
        XCTAssertFalse(result?.contains("New chat") == true)
    }

    func testVisibleChatContextKeepsTheNewestBoundedTailAndFocusedDraft() {
        let result = BoundedContextComposer.compose(
            focusedFieldText: "Aktueller Entwurf",
            visibleFragments: [
                VisibleContextFragment(text: String(repeating: "alt ", count: 80)),
                VisibleContextFragment(text: "Neuester Gesprächshinweis")
            ],
            maximumCharacters: 70
        )

        XCTAssertNotNil(result)
        XCTAssertLessThanOrEqual(result?.count ?? .max, 70)
        XCTAssertTrue(result?.contains("Neuester Gesprächshinweis") == true)
        XCTAssertTrue(result?.hasSuffix("Aktueller Entwurf") == true)
    }

    func testResolvedTargetKindTurnsKnownBrowserMessagingSurfaceIntoChat() {
        XCTAssertEqual(
            AccessibilityTargetRegistry.resolvedTargetKind(
                .unknown,
                category: .workMessaging
            ),
            .chat
        )
        XCTAssertEqual(
            AccessibilityTargetRegistry.resolvedTargetKind(
                .document,
                category: .other
            ),
            .document
        )
        XCTAssertTrue(
            AccessibilityTargetRegistry.isBrowserBundleIdentifier("com.brave.Browser")
        )
        XCTAssertFalse(
            AccessibilityTargetRegistry.isBrowserBundleIdentifier("com.apple.TextEdit")
        )
    }

    func testInserterPrefersConfirmedAXSelectedText() async throws {
        let sessionID = DictationSessionID(rawValue: 4)
        let target = makeTarget(sessionID: sessionID)
        let fake = FakeAccessibilityTargets(
            capture: .captured(
                RegisteredTargetCapture(
                    snapshot: target,
                    targetKind: .document,
                    security: .standard
                )
            ),
            direct: .confirmed
        )
        let inserter = StrictLocalTextInserter(targets: fake)

        let outcome = try await inserter.insert(
            .local(LocalCandidate(text: "Hallo")),
            sessionID: sessionID
        )
        let directWrites = await fake.directWriteCount()
        let unicodeWrites = await fake.unicodeWriteCount()
        let observations = await fake.correctionObservationCount()

        XCTAssertEqual(outcome, .confirmedDirect)
        XCTAssertEqual(directWrites, 1)
        XCTAssertEqual(unicodeWrites, 0)
        XCTAssertEqual(observations, 1)
    }

    func testInserterRecapturesTheCurrentTextFieldImmediatelyBeforeCommit() async throws {
        let sessionID = DictationSessionID(rawValue: 41)
        let currentTarget = TargetSnapshot(
            processIdentifier: 84,
            token: TargetToken(rawValue: 999),
            selectionFingerprint: SelectionFingerprint(rawValue: 123),
            sessionID: sessionID
        )
        let fake = FakeAccessibilityTargets(
            capture: .captured(
                RegisteredTargetCapture(
                    snapshot: currentTarget,
                    targetKind: .chat,
                    security: .standard
                )
            ),
            direct: .confirmed
        )
        let inserter = StrictLocalTextInserter(targets: fake)

        let outcome = try await inserter.insert(
            .local(LocalCandidate(text: "Aktueller Cursor")),
            sessionID: sessionID
        )
        let captureCount = await fake.captureCount()
        let insertedTargets = await fake.insertedTargets()

        XCTAssertEqual(outcome, .confirmedDirect)
        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(insertedTargets, [currentTarget])
    }

    func testInserterRejectsACommitWithoutACurrentFocusedTextField() async throws {
        let sessionID = DictationSessionID(rawValue: 42)
        let fake = FakeAccessibilityTargets(
            capture: .unavailable(processIdentifier: 84),
            direct: .confirmed
        )
        let inserter = StrictLocalTextInserter(targets: fake)

        let outcome = try await inserter.insert(
            .local(LocalCandidate(text: "Nicht irgendwo einfügen")),
            sessionID: sessionID
        )
        let directWriteCount = await fake.directWriteCount()
        let insertedTargets = await fake.insertedTargets()

        XCTAssertEqual(outcome, .safeFallback)
        XCTAssertEqual(directWriteCount, 0)
        XCTAssertEqual(insertedTargets, [])
    }

    func testInserterRejectsProtectedTextFieldsAtFinalCommit() async throws {
        let sessionID = DictationSessionID(rawValue: 43)
        let target = makeTarget(sessionID: sessionID)
        let fake = FakeAccessibilityTargets(
            capture: .captured(
                RegisteredTargetCapture(
                    snapshot: target,
                    targetKind: .unknown,
                    security: .deniedSensitive
                )
            ),
            direct: .confirmed
        )
        let inserter = StrictLocalTextInserter(targets: fake)

        let outcome = try await inserter.insert(
            .local(LocalCandidate(text: "Kein Passwortfeld")),
            sessionID: sessionID
        )
        let directWriteCount = await fake.directWriteCount()

        XCTAssertEqual(outcome, .safeFallback)
        XCTAssertEqual(directWriteCount, 0)
    }

    func testProductionRoleAllowlistAcceptsOnlyEditableTextInputs() {
        XCTAssertTrue(
            AccessibilityTargetRegistry.supportsEditableRole(kAXTextFieldRole as String)
        )
        XCTAssertTrue(
            AccessibilityTargetRegistry.supportsEditableRole(kAXTextAreaRole as String)
        )
        XCTAssertFalse(
            AccessibilityTargetRegistry.supportsEditableRole(kAXButtonRole as String)
        )
        XCTAssertFalse(
            AccessibilityTargetRegistry.supportsEditableRole(kAXStaticTextRole as String)
        )
        XCTAssertFalse(
            AccessibilityTargetRegistry.supportsEditableRole(kAXGroupRole as String)
        )
    }

    func testFocusedEditableCandidateRejectsFocusedWebWrappers() {
        XCTAssertFalse(
            AccessibilityTargetRegistry.isFocusedEditableCandidate(
                role: "AXWebArea",
                isFocused: true
            )
        )
        XCTAssertFalse(
            AccessibilityTargetRegistry.isFocusedEditableCandidate(
                role: kAXTextAreaRole as String,
                isFocused: false
            )
        )
        XCTAssertTrue(
            AccessibilityTargetRegistry.isFocusedEditableCandidate(
                role: kAXTextAreaRole as String,
                isFocused: true
            )
        )
    }

    func testFocusedValueWebAreaIsAllowedOnlyForEditableMailMessageBodyCapability() {
        XCTAssertTrue(
            AccessibilityTargetRegistry.supportsFocusedValueWebArea(
                bundleIdentifier: "com.apple.mail",
                role: "AXWebArea",
                isFocused: true,
                valueIsSettable: true,
                hasSelectedTextMarkerRange: true
            )
        )
        XCTAssertFalse(
            AccessibilityTargetRegistry.supportsFocusedValueWebArea(
                bundleIdentifier: "com.brave.Browser",
                role: "AXWebArea",
                isFocused: true,
                valueIsSettable: true,
                hasSelectedTextMarkerRange: true
            )
        )
        XCTAssertFalse(
            AccessibilityTargetRegistry.supportsFocusedValueWebArea(
                bundleIdentifier: "com.apple.mail",
                role: "AXWebArea",
                isFocused: false,
                valueIsSettable: true,
                hasSelectedTextMarkerRange: true
            )
        )
        XCTAssertFalse(
            AccessibilityTargetRegistry.supportsFocusedValueWebArea(
                bundleIdentifier: "com.apple.mail",
                role: "AXWebArea",
                isFocused: true,
                valueIsSettable: true,
                hasSelectedTextMarkerRange: false
            )
        )
    }

    func testValueMutationVerifierAcceptsOnlyOneContiguousReplacement() {
        XCTAssertTrue(
            AXValueMutationVerifier.confirmsSingleReplacement(
                original: "",
                updated: "FlusterFlow-Live-Einfügung",
                replacement: "FlusterFlow-Live-Einfügung"
            )
        )
        XCTAssertTrue(
            AXValueMutationVerifier.confirmsSingleReplacement(
                original: "Vorher alter Text nachher",
                updated: "Vorher neuer Text nachher",
                replacement: "neuer Text"
            )
        )
        XCTAssertFalse(
            AXValueMutationVerifier.confirmsSingleReplacement(
                original: "Vorher unverändert nachher",
                updated: "Manipuliert neuer Text nachher",
                replacement: "neuer Text"
            )
        )
        XCTAssertFalse(
            AXValueMutationVerifier.confirmsSingleReplacement(
                original: "Unverändert",
                updated: "Unverändert",
                replacement: "Unverändert"
            )
        )
    }

    func testChromiumSectionObjectsExposeTheirAccessibilityElements() throws {
        let element = AXUIElementCreateSystemWide()
        let sections: NSArray = [
            ["SectionObject": element],
            ["SectionObject": "not-an-accessibility-element"],
            ["OtherKey": element],
            "not-a-section"
        ]

        let result = AccessibilityTargetRegistry.sectionObjects(from: sections)

        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(CFEqual(result[0], element))
    }

    func testLiveFrontmostEditableTargetCaptureWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["FLUSTERFLOW_RUN_LIVE_AX_CAPTURE"] == "1" else {
            throw XCTSkip("Set FLUSTERFLOW_RUN_LIVE_AX_CAPTURE=1 with a real text field focused")
        }

        let sessionID = DictationSessionID(rawValue: 44_001)
        let registry = AccessibilityTargetRegistry()
        XCTAssertTrue(
            AXIsProcessTrusted(),
            "The live test process does not have Accessibility authorization"
        )
        let result = await registry.captureTarget(for: sessionID)

        switch result {
        case .unavailable(let processIdentifier):
            XCTFail(
                "Production target capture returned unavailable for PID \(processIdentifier); "
                    + liveAXProbeSummary(processIdentifier: processIdentifier)
            )
        case .captured(let capture):
            XCTAssertEqual(capture.security, .standard)
            XCTAssertNotEqual(
                capture.snapshot.processIdentifier,
                Int32(ProcessInfo.processInfo.processIdentifier)
            )
            await registry.releaseTargets(for: sessionID)
        }
    }

    func testLiveVisibleChatContextWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["FLUSTERFLOW_RUN_LIVE_CHAT_CONTEXT"] == "1" else {
            throw XCTSkip("Set FLUSTERFLOW_RUN_LIVE_CHAT_CONTEXT=1 with the isolated chat fixture focused")
        }
        guard let expectedPIDValue = ProcessInfo.processInfo.environment[
            "FLUSTERFLOW_EXPECTED_TARGET_PID"
        ], let expectedProcessIdentifier = Int32(expectedPIDValue) else {
            XCTFail("Set FLUSTERFLOW_EXPECTED_TARGET_PID to the isolated browser PID")
            return
        }
        guard let expectedCanary = ProcessInfo.processInfo.environment[
            "FLUSTERFLOW_EXPECTED_CONTEXT_CANARY"
        ], !expectedCanary.isEmpty else {
            XCTFail("Set FLUSTERFLOW_EXPECTED_CONTEXT_CANARY to visible fixture text")
            return
        }
        guard let expectedApplication = NSRunningApplication(
            processIdentifier: expectedProcessIdentifier
        ), expectedApplication.activate(options: [.activateAllWindows]) else {
            XCTFail("Could not activate expected chat fixture PID \(expectedProcessIdentifier)")
            return
        }
        try await Task.sleep(for: .milliseconds(250))

        let sessionID = DictationSessionID(rawValue: 44_003)
        let registry = AccessibilityTargetRegistry()
        let result = await registry.captureTarget(for: sessionID)
        guard case .captured(let capture) = result else {
            XCTFail("Production target capture did not find the focused chat fixture")
            return
        }
        XCTAssertEqual(capture.snapshot.processIdentifier, expectedProcessIdentifier)
        XCTAssertEqual(capture.targetKind, .chat)
        XCTAssertEqual(capture.localCategory, .workMessaging)
        let context = await registry.boundedContext(
            for: capture.snapshot,
            maximumCharacters: 1_500
        )
        XCTAssertTrue(context?.contains(expectedCanary) == true)
        XCTAssertLessThanOrEqual(context?.count ?? .max, 1_500)
        await registry.releaseTargets(for: sessionID)
    }

    func testLiveProductionInsertionIntoFrontmostFieldWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["FLUSTERFLOW_RUN_LIVE_AX_INSERT"] == "1" else {
            throw XCTSkip("Set FLUSTERFLOW_RUN_LIVE_AX_INSERT=1 with the isolated test field focused")
        }
        guard let expectedPIDValue = ProcessInfo.processInfo.environment[
            "FLUSTERFLOW_EXPECTED_TARGET_PID"
        ], let expectedProcessIdentifier = Int32(expectedPIDValue) else {
            XCTFail(
                "Set FLUSTERFLOW_EXPECTED_TARGET_PID to the isolated test app PID so the live test cannot mutate an unintended frontmost field"
            )
            return
        }

        guard let expectedApplication = NSRunningApplication(
            processIdentifier: expectedProcessIdentifier
        ) else {
            XCTFail("Expected live insertion app PID \(expectedProcessIdentifier) is not running")
            return
        }
        guard expectedApplication.activate(options: [.activateAllWindows]) else {
            XCTFail("Could not activate expected live insertion app PID \(expectedProcessIdentifier)")
            return
        }
        try await Task.sleep(for: .milliseconds(250))

        let sessionID = DictationSessionID(rawValue: 44_002)
        let registry = AccessibilityTargetRegistry()
        let result = await registry.captureTarget(for: sessionID)
        let capture: RegisteredTargetCapture
        switch result {
        case .captured(let captured):
            capture = captured
        case .unavailable(let processIdentifier):
            XCTFail(
                "Production target capture did not find the isolated live test field; "
                    + liveAXProbeSummary(processIdentifier: processIdentifier)
            )
            return
        }
        XCTAssertEqual(capture.security, .standard)
        guard capture.snapshot.processIdentifier == expectedProcessIdentifier else {
            XCTFail(
                "Refusing live insertion: captured PID \(capture.snapshot.processIdentifier), expected \(expectedProcessIdentifier)"
            )
            await registry.releaseTargets(for: sessionID)
            return
        }

        let attempt = await registry.insertSelectedText(
            "FlusterFlow-Live-Einfügung",
            into: capture.snapshot,
            sessionID: sessionID,
            permit: InsertionCommitPermit()
        )

        XCTAssertEqual(attempt, .confirmed)
        await registry.releaseTargets(for: sessionID)
    }

    func testFocusedElementFallbackTraversalFindsDeepEditorsAndStopsAtCycles() {
        let children = [
            0: [1, 2],
            1: [0],
            2: [3],
            3: [2, 4]
        ]

        let result = BoundedDepthFirstTraversal.first(
            root: 0,
            maximumVisited: 10,
            maximumDepth: 10,
            identity: { $0 },
            areEqual: ==,
            matches: { $0 == 4 },
            children: { children[$0, default: []] }
        )

        XCTAssertEqual(result, 4)
    }

    func testFocusedElementFallbackTraversalHonorsItsSafetyBounds() {
        let children = [0: [1], 1: [2], 2: [3]]

        XCTAssertNil(
            BoundedDepthFirstTraversal.first(
                root: 0,
                maximumVisited: 2,
                maximumDepth: 10,
                identity: { $0 },
                areEqual: ==,
                matches: { $0 == 3 },
                children: { children[$0, default: []] }
            )
        )
        XCTAssertNil(
            BoundedDepthFirstTraversal.first(
                root: 0,
                maximumVisited: 10,
                maximumDepth: 1,
                identity: { $0 },
                areEqual: ==,
                matches: { $0 == 3 },
                children: { children[$0, default: []] }
            )
        )
    }

    func testAXValuePlannerReplacesTheUTF16SelectionAndMovesTheCaret() throws {
        let plan = try XCTUnwrap(
            AXValueInsertionPlanner.makePlan(
                original: "A😀C",
                selectionLocation: 1,
                selectionLength: 2,
                replacement: "ok"
            )
        )

        XCTAssertEqual(plan, AXValueInsertionPlan(value: "AokC", caretLocation: 3))
        XCTAssertNil(
            AXValueInsertionPlanner.makePlan(
                original: "A😀C",
                selectionLocation: 2,
                selectionLength: 1,
                replacement: "invalid surrogate split"
            )
        )
    }

    func testUnicodeEventChunksPreserveGraphemesAndReassembleExactly() throws {
        let text = String(repeating: "Grüße 😀 aus Köln. ", count: 12)
        let chunks = try XCTUnwrap(UnicodeEventTextChunker.chunks(text))

        XCTAssertEqual(chunks.joined(), text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(
            chunks.allSatisfy {
                $0.utf16.count <= UnicodeEventTextChunker.maximumChunkUTF16Length
            }
        )
    }

    func testUnicodeEventChunksRejectEmptyAndUnboundedText() {
        XCTAssertNil(UnicodeEventTextChunker.chunks(""))
        XCTAssertNil(
            UnicodeEventTextChunker.chunks(
                String(
                    repeating: "x",
                    count: UnicodeEventTextChunker.maximumUTF16Length + 1
                )
            )
        )
    }

    func testUnsupportedAXFailsClosedWithoutASecondMutationRoute() async throws {
        let sessionID = DictationSessionID(rawValue: 5)
        let target = makeTarget(sessionID: sessionID)
        let fake = FakeAccessibilityTargets(
            capture: .captured(
                RegisteredTargetCapture(
                    snapshot: target,
                    targetKind: .document,
                    security: .standard
                )
            ),
            direct: .unsupported
        )
        let inserter = StrictLocalTextInserter(targets: fake)

        let outcome = try await inserter.insert(
            .local(LocalCandidate(text: "Hello")),
            sessionID: sessionID
        )
        let directWrites = await fake.directWriteCount()

        XCTAssertEqual(outcome, .safeFallback)
        XCTAssertEqual(directWrites, 0)
    }

    func testUnconfirmedAXMutationNeverFallsThroughToSecondWrite() async throws {
        let sessionID = DictationSessionID(rawValue: 6)
        let target = makeTarget(sessionID: sessionID)
        let fake = FakeAccessibilityTargets(
            capture: .captured(
                RegisteredTargetCapture(
                    snapshot: target,
                    targetKind: .document,
                    security: .standard
                )
            ),
            direct: .unconfirmedMutation
        )
        let inserter = StrictLocalTextInserter(targets: fake)

        let outcome = try await inserter.insert(
            .local(LocalCandidate(text: "No duplicate")),
            sessionID: sessionID
        )
        let unicodeWrites = await fake.unicodeWriteCount()

        XCTAssertEqual(outcome, .safeFallback)
        XCTAssertEqual(unicodeWrites, 0)
    }

    func testCancelledSessionCannotInsert() async throws {
        let sessionID = DictationSessionID(rawValue: 7)
        let target = makeTarget(sessionID: sessionID)
        let fake = FakeAccessibilityTargets(
            capture: .captured(
                RegisteredTargetCapture(
                    snapshot: target,
                    targetKind: .document,
                    security: .standard
                )
            ),
            direct: .confirmed
        )
        let inserter = StrictLocalTextInserter(targets: fake)

        _ = await inserter.requestCancellation(sessionID: sessionID)
        let outcome = try await inserter.insert(
            .local(LocalCandidate(text: "Must not insert")),
            sessionID: sessionID
        )
        let directWrites = await fake.directWriteCount()

        XCTAssertEqual(outcome, .safeFallback)
        XCTAssertEqual(directWrites, 0)
    }

    func testCancelBeforeCommitPreventsEveryDirectMutation() async throws {
        let sessionID = DictationSessionID(rawValue: 8)
        let fake = RaceAccessibilityTargets(mode: .pauseBeforeCommit)
        let inserter = StrictLocalTextInserter(targets: fake)

        let insertion = Task {
            try await inserter.insert(
                .local(LocalCandidate(text: "Must remain local")),
                sessionID: sessionID
            )
        }

        await fake.waitUntilPausedBeforeCommit()
        let disposition = await inserter.requestCancellation(sessionID: sessionID)
        await fake.resumeCommit()
        let outcome = try await insertion.value
        let directWrites = await fake.directWriteCount()

        XCTAssertEqual(disposition, .cancelledBeforeCommit)
        XCTAssertEqual(outcome, .safeFallback)
        XCTAssertEqual(directWrites, 0)
    }

    func testCommitWinningRaceMakesCancellationTruthfullyTooLate() async throws {
        let sessionID = DictationSessionID(rawValue: 9)
        let fake = RaceAccessibilityTargets(mode: .pauseAfterCommit)
        let inserter = StrictLocalTextInserter(targets: fake)

        let insertion = Task {
            try await inserter.insert(
                .local(LocalCandidate(text: "Committed once")),
                sessionID: sessionID
            )
        }

        await fake.waitUntilCommitted()
        let disposition = await inserter.requestCancellation(sessionID: sessionID)
        await fake.resumeAdapterReturn()
        let outcome = try await insertion.value
        let directWrites = await fake.directWriteCount()

        XCTAssertEqual(disposition, .tooLateCommitted)
        XCTAssertEqual(outcome, .confirmedDirect)
        XCTAssertEqual(directWrites, 1)
    }

    func testCommittedPermitSurvivesAdapterReturnUntilTerminalRelease() async throws {
        let sessionID = DictationSessionID(rawValue: 10)
        let fake = RaceAccessibilityTargets(mode: .immediate)
        let inserter = StrictLocalTextInserter(targets: fake)

        let outcome = try await inserter.insert(
            .local(LocalCandidate(text: "Already committed")),
            sessionID: sessionID
        )
        let dispositionAfterReturn = await inserter.requestCancellation(sessionID: sessionID)
        let directWrites = await fake.directWriteCount()

        XCTAssertEqual(outcome, .confirmedDirect)
        XCTAssertEqual(dispositionAfterReturn, .tooLateCommitted)
        XCTAssertEqual(directWrites, 1)

        await inserter.releaseInsertionSession(sessionID: sessionID)
        let releaseCount = await fake.releaseCount()
        XCTAssertEqual(releaseCount, 1)
    }

    func testProductionInsertionUsesNoGeneralPasteboardMutationRoute() throws {
        let registry = try TestResourceLoader.string(
            "WhisperFlow/Core/Accessibility/AccessibilityTargetRegistry.swift"
        )
        let inserter = try TestResourceLoader.string(
            "WhisperFlow/Core/Insertion/StrictLocalTextInserter.swift"
        )

        XCTAssertFalse(registry.contains("NSPasteboard"))
        XCTAssertFalse(inserter.contains("NSPasteboard"))
        XCTAssertTrue(registry.contains("keyboardSetUnicodeString"))
        XCTAssertTrue(registry.contains("isWebBackedTextElement"))
    }
}

private func liveAXProbeSummary(processIdentifier: Int32) -> String {
    let application = AXUIElementCreateApplication(processIdentifier)
    let systemFocus = probeElementAttribute(
        kAXFocusedUIElementAttribute as String,
        from: AXUIElementCreateSystemWide()
    )
    let systemFocusRole = systemFocus.element.flatMap {
        probeStringAttribute(kAXRoleAttribute as String, from: $0)
    }
    let systemFocusAttributes = systemFocus.element.map(probeAttributeNames) ?? []
    let systemFocusHasSelectedRange = systemFocus.element.flatMap(probeSelectedRange) != nil
    let systemFocusSettableAttributes = systemFocus.element.map { element in
        [
            kAXValueAttribute as String,
            kAXSelectedTextAttribute as String,
            kAXSelectedTextRangeAttribute as String
        ].map { attribute in
            "\(attribute)=\(probeAttributeSettable(attribute, on: element))"
        }.joined(separator: ",")
    } ?? "none"
    var systemFocusPID: pid_t = 0
    let systemFocusPIDError = systemFocus.element.map {
        AXUIElementGetPid($0, &systemFocusPID)
    }
    let applicationFocus = probeElementAttribute(
        kAXFocusedUIElementAttribute as String,
        from: application
    )
    let focusedWindow = probeElementAttribute(
        kAXFocusedWindowAttribute as String,
        from: application
    )
    let windowFocus = focusedWindow.element.map {
        probeElementAttribute(kAXFocusedUIElementAttribute as String, from: $0)
    }

    guard let root = focusedWindow.element else {
        return "appFocusError=\(applicationFocus.error.rawValue), focusedWindowError=\(focusedWindow.error.rawValue)"
    }

    var stack: [(element: AXUIElement, depth: Int)] = [(root, 0)]
    var visited: [Int: [AXUIElement]] = [:]
    var visitedCount = 0
    var maximumDepth = 0
    var focusedRoles: [String] = []
    var editableRoles: [String] = []
    var roleDepths: [String] = []

    while let current = stack.popLast(), visitedCount < 10_000 {
        let key = Int(CFHash(current.element))
        if visited[key, default: []].contains(where: { CFEqual($0, current.element) }) {
            continue
        }
        visited[key, default: []].append(current.element)
        visitedCount += 1
        maximumDepth = max(maximumDepth, current.depth)

        let role = probeStringAttribute(kAXRoleAttribute as String, from: current.element) ?? "unknown"
        roleDepths.append("\(role)@\(current.depth)")
        let focused = probeBooleanAttribute(kAXFocusedAttribute as String, from: current.element)
        if focused == true {
            focusedRoles.append("\(role)@\(current.depth)")
        }
        if AccessibilityTargetRegistry.supportsEditableRole(role) {
            let rangeAvailable = probeSelectedRange(from: current.element) != nil
            editableRoles.append(
                "\(role)@\(current.depth):focused=\(focused.map(String.init) ?? "nil"):range=\(rangeAvailable)"
            )
        }

        if current.depth < 128 {
            let childAttributes = [
                kAXChildrenAttribute as String,
                kAXVisibleChildrenAttribute as String,
                kAXContentsAttribute as String,
                "AXChildrenInNavigationOrder"
            ]
            for attribute in childAttributes {
                for child in probeElementArrayAttribute(attribute, from: current.element) {
                    stack.append((child, current.depth + 1))
                }
            }
            for child in probeSectionElements(from: current.element) {
                stack.append((child, current.depth + 1))
            }
        }
    }

    return [
        "appFocusError=\(applicationFocus.error.rawValue)",
        "systemFocusError=\(systemFocus.error.rawValue)",
        "systemFocusPIDError=\(systemFocusPIDError?.rawValue.description ?? "none")",
        "systemFocusPID=\(systemFocusPID)",
        "systemFocusRole=\(systemFocusRole ?? "none")",
        "systemFocusAttributes=\(systemFocusAttributes.joined(separator: ","))",
        "systemFocusHasSelectedRange=\(systemFocusHasSelectedRange)",
        "systemFocusSettable=\(systemFocusSettableAttributes)",
        "windowFocusError=\(windowFocus?.error.rawValue.description ?? "none")",
        "appAttributes=\(probeAttributeNames(from: application).joined(separator: ","))",
        "windowAttributes=\(probeAttributeNames(from: root).joined(separator: ","))",
        "windowSpecials=\(["AXSections", kAXDocumentAttribute as String, "AXChildrenInNavigationOrder", kAXChildrenAttribute as String].map { probeValueShape($0, from: root) }.joined(separator: "|"))",
        "visited=\(visitedCount)",
        "maxDepth=\(maximumDepth)",
        "roles=\(roleDepths.joined(separator: ","))",
        "focused=\(focusedRoles.joined(separator: ","))",
        "editable=\(editableRoles.prefix(12).joined(separator: ","))"
    ].joined(separator: "; ")
}

private func probeAttributeSettable(_ attribute: String, on element: AXUIElement) -> Bool {
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(
        element,
        attribute as CFString,
        &settable
    ) == .success && settable.boolValue
}

private func probeSectionElements(from element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element,
        "AXSections" as CFString,
        &value
    ) == .success,
    let value,
    CFGetTypeID(value) == CFArrayGetTypeID() else {
        return []
    }
    let sections = value as! NSArray

    return sections.compactMap { value in
        guard let section = value as? NSDictionary else { return nil }
        guard let object = section["SectionObject"] else { return nil }
        let reference = object as CFTypeRef
        guard CFGetTypeID(reference) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(reference, to: AXUIElement.self)
    }
}

private func probeValueShape(_ attribute: String, from element: AXUIElement) -> String {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &value
    )
    guard error == .success, let value else {
        return "\(attribute):error=\(error.rawValue)"
    }
    if CFGetTypeID(value) == AXUIElementGetTypeID() {
        let child = unsafeDowncast(value, to: AXUIElement.self)
        let role = probeStringAttribute(kAXRoleAttribute as String, from: child) ?? "unknown"
        return "\(attribute):element=\(role)"
    }
    if CFGetTypeID(value) == CFArrayGetTypeID() {
        let array = value as! NSArray
        let shapes = array.prefix(8).map { item -> String in
            let reference = item as CFTypeRef
            if CFGetTypeID(reference) == AXUIElementGetTypeID() {
                let child = unsafeDowncast(reference, to: AXUIElement.self)
                return "element:\(probeStringAttribute(kAXRoleAttribute as String, from: child) ?? "unknown")"
            }
            if let dictionary = item as? NSDictionary {
                let objectShape: String
                if let object = dictionary["SectionObject"] {
                    let reference = object as CFTypeRef
                    let child = unsafeDowncast(reference, to: AXUIElement.self)
                    let role = probeStringAttribute(kAXRoleAttribute as String, from: child) ?? "none"
                    let attributes = probeAttributeNames(from: child)
                    objectShape = ":SectionObject=\(type(of: object))/\(CFCopyTypeIDDescription(CFGetTypeID(reference)) as String)/role=\(role)/attributes=\(attributes.count)/isRoot=\(CFEqual(child, element))"
                } else {
                    objectShape = ""
                }
                return "dictionaryKeys:\(dictionary.allKeys.map(String.init(describing:)).sorted().joined(separator: ","))\(objectShape)"
            }
            return "type:\(type(of: item))"
        }
        return "\(attribute):array[\(array.count)]=\(shapes.joined(separator: ","))"
    }
    return "\(attribute):type=\(CFCopyTypeIDDescription(CFGetTypeID(value)) as String)"
}

private func probeAttributeNames(from element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(element, &names) == .success,
          let names else {
        return []
    }
    return (names as NSArray).compactMap { $0 as? String }
}

private func probeElementAttribute(
    _ attribute: String,
    from element: AXUIElement
) -> (error: AXError, element: AXUIElement?) {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &value
    )
    guard error == .success,
          let value,
          CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return (error, nil)
    }
    return (error, unsafeDowncast(value, to: AXUIElement.self))
}

private func probeElementArrayAttribute(
    _ attribute: String,
    from element: AXUIElement
) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &value
    ) == .success,
    let elements = value as? [AXUIElement] else {
        return []
    }
    return elements
}

private func probeStringAttribute(
    _ attribute: String,
    from element: AXUIElement
) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &value
    ) == .success else {
        return nil
    }
    return value as? String
}

private func probeBooleanAttribute(
    _ attribute: String,
    from element: AXUIElement
) -> Bool? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &value
    ) == .success else {
        return nil
    }
    return (value as? NSNumber)?.boolValue
}

private func probeSelectedRange(from element: AXUIElement) -> CFRange? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element,
        kAXSelectedTextRangeAttribute as CFString,
        &value
    ) == .success,
    let value,
    CFGetTypeID(value) == AXValueGetTypeID() else {
        return nil
    }
    var range = CFRange()
    guard AXValueGetValue(
        unsafeDowncast(value, to: AXValue.self),
        .cfRange,
        &range
    ) else {
        return nil
    }
    return range
}

private func makeTarget(sessionID: DictationSessionID) -> TargetSnapshot {
    TargetSnapshot(
        processIdentifier: 42,
        token: TargetToken(rawValue: sessionID.rawValue),
        selectionFingerprint: SelectionFingerprint(rawValue: 99),
        sessionID: sessionID
    )
}

private actor FakeAccessibilityTargets: AccessibilityTargetAccessing {
    private let captureResult: RegisteredTargetCaptureResult
    private let contextValue: String?
    private let directResult: DirectInsertionAttempt
    private var contextReads = 0
    private var directWrites = 0
    private var captures = 0
    private var insertionTargets: [TargetSnapshot] = []
    private var correctionObservations = 0

    init(
        capture: RegisteredTargetCaptureResult,
        context: String? = nil,
        direct: DirectInsertionAttempt = .unsupported
    ) {
        captureResult = capture
        contextValue = context
        directResult = direct
    }

    func captureTarget(for sessionID: DictationSessionID) -> RegisteredTargetCaptureResult {
        captures += 1
        return captureResult
    }

    func boundedContext(for target: TargetSnapshot, maximumCharacters: Int) -> String? {
        contextReads += 1
        return contextValue
    }

    func insertSelectedText(
        _ text: String,
        into target: TargetSnapshot,
        sessionID: DictationSessionID,
        permit: InsertionCommitPermit
    ) -> DirectInsertionAttempt {
        insertionTargets.append(target)
        switch directResult {
        case .unsupported, .denied:
            return directResult
        case .confirmed, .unconfirmedMutation:
            switch permit.performCommit({
                directWrites += 1
                return directResult
            }) {
            case .cancelled:
                return .denied
            case .performed(let result):
                return result
            }
        }
    }

    func observeRecentCorrection(
        of insertedText: String,
        in target: TargetSnapshot,
        sessionID: DictationSessionID
    ) {
        correctionObservations += 1
    }

    func releaseTargets(for sessionID: DictationSessionID) {}

    func contextReadCount() -> Int { contextReads }
    func directWriteCount() -> Int { directWrites }
    func captureCount() -> Int { captures }
    func insertedTargets() -> [TargetSnapshot] { insertionTargets }
    func correctionObservationCount() -> Int { correctionObservations }
    func unicodeWriteCount() -> Int { 0 }
}

private actor RaceAccessibilityTargets: AccessibilityTargetAccessing {
    enum Mode: Equatable, Sendable {
        case immediate
        case pauseBeforeCommit
        case pauseAfterCommit
    }

    private let mode: Mode
    private let beforeCommit = AsyncInsertionGate()
    private let resumeCommitGate = AsyncInsertionGate()
    private let committed = AsyncInsertionGate()
    private let resumeReturnGate = AsyncInsertionGate()
    private var directWrites = 0
    private var releases = 0

    init(mode: Mode) {
        self.mode = mode
    }

    func captureTarget(for sessionID: DictationSessionID) -> RegisteredTargetCaptureResult {
        .captured(
            RegisteredTargetCapture(
                snapshot: makeTarget(sessionID: sessionID),
                targetKind: .document,
                security: .standard
            )
        )
    }

    func boundedContext(for target: TargetSnapshot, maximumCharacters: Int) -> String? {
        nil
    }

    func insertSelectedText(
        _ text: String,
        into target: TargetSnapshot,
        sessionID: DictationSessionID,
        permit: InsertionCommitPermit
    ) async -> DirectInsertionAttempt {
        if mode == .pauseBeforeCommit {
            await beforeCommit.open()
            await resumeCommitGate.wait()
        }

        let result = permit.performCommit {
            directWrites += 1
            return DirectInsertionAttempt.confirmed
        }
        guard case .performed(let attempt) = result else {
            return .denied
        }

        await committed.open()
        if mode == .pauseAfterCommit {
            await resumeReturnGate.wait()
        }
        return attempt
    }

    func releaseTargets(for sessionID: DictationSessionID) {
        releases += 1
    }

    func waitUntilPausedBeforeCommit() async {
        await beforeCommit.wait()
    }

    func resumeCommit() async {
        await resumeCommitGate.open()
    }

    func waitUntilCommitted() async {
        await committed.wait()
    }

    func resumeAdapterReturn() async {
        await resumeReturnGate.open()
    }

    func directWriteCount() -> Int { directWrites }
    func releaseCount() -> Int { releases }
}

private actor AsyncInsertionGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll(keepingCapacity: false)
        currentWaiters.forEach { $0.resume() }
    }
}
