@preconcurrency import AppKit
@preconcurrency import ApplicationServices
import Foundation

actor AccessibilityTargetRegistry: AccessibilityTargetAccessing {
    typealias CorrectionSink = @Sendable (PersonalLexiconCorrection) async -> Void

    private static let maximumFallbackVisitedElements = 4_096
    private static let maximumFallbackDepth = 64
    private static let webAreaRole = "AXWebArea"
    private static let childrenInNavigationOrderAttribute = "AXChildrenInNavigationOrder"
    private static let sectionsAttribute = "AXSections"
    private static let sectionObjectKey = "SectionObject"
    private static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"
    private static let enhancedUIActivationTimeout = Duration.seconds(3)
    private static let enhancedUIActivationPollInterval = Duration.milliseconds(100)
    private static let mailBundleIdentifier = "com.apple.mail"
    private static let selectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange"
    private static let maximumVisibleContextElements = 768
    private static let maximumVisibleContextDepth = 32
    private static let visibleContextRoles: Set<String> = [
        kAXStaticTextRole as String,
        kAXTextAreaRole as String,
        kAXTextFieldRole as String,
        "AXHeading"
    ]

    private enum InsertionMode: Sendable {
        case rangeBased
        case focusedValueWebArea
    }

    private struct UnicodeEventPair {
        let keyDown: CGEvent
        let keyUp: CGEvent
    }

    private struct Entry {
        let element: AXUIElement
        let processIdentifier: Int32
        let bundleIdentifier: String?
        let security: TargetSecurityDisposition
        let sessionID: DictationSessionID
        let insertionMode: InsertionMode
        let targetKind: TargetKind
        let localCategory: LocalContextCategory
    }

    private struct FrontmostDescriptor: Sendable {
        let processIdentifier: Int32
        let bundleIdentifier: String?
    }

    private struct CorrectionObservation: @unchecked Sendable {
        let element: AXUIElement
        let processIdentifier: Int32
        let insertedText: String
        let insertedStart: Int
        let initialCharacterCount: Int
        let prefix: String
        let suffix: String
        let language: DictationLanguage
        let insertedAt: Date
    }

    private var entries: [TargetToken: Entry] = [:]
    private var nextTokenValue: UInt64 = 0
    private var enhancedUIActivationRequestedPIDs: Set<Int32> = []
    private let isCorrectionLearningEnabled: @Sendable () async -> Bool
    private let correctionLanguage: @Sendable () async -> DictationLanguage
    private let correctionSink: CorrectionSink

    init(
        isCorrectionLearningEnabled: @escaping @Sendable () async -> Bool = { false },
        correctionLanguage: @escaping @Sendable () async -> DictationLanguage = { .automatic },
        correctionSink: @escaping CorrectionSink = { _ in }
    ) {
        self.isCorrectionLearningEnabled = isCorrectionLearningEnabled
        self.correctionLanguage = correctionLanguage
        self.correctionSink = correctionSink
    }

    func captureTarget(for sessionID: DictationSessionID) async -> RegisteredTargetCaptureResult {
        let frontmost = await Self.frontmostDescriptor()
        guard AXIsProcessTrusted(), let frontmost else {
            return .unavailable(processIdentifier: frontmost?.processIdentifier ?? 0)
        }

        let application = AXUIElementCreateApplication(frontmost.processIdentifier)
        guard let element = await focusedElementWithActivation(
            in: application,
            processIdentifier: frontmost.processIdentifier,
            bundleIdentifier: frontmost.bundleIdentifier
        ) else {
            return .unavailable(processIdentifier: frontmost.processIdentifier)
        }
        let currentFrontmost = await Self.frontmostDescriptor()
        guard currentFrontmost?.processIdentifier == frontmost.processIdentifier else {
            return .unavailable(processIdentifier: currentFrontmost?.processIdentifier ?? 0)
        }

        let role = copyStringAttribute(kAXRoleAttribute as String, from: element) ?? ""
        let subrole = copyStringAttribute(kAXSubroleAttribute as String, from: element)
        let containsProtectedContent = copyBooleanAttribute(
            NSAccessibility.Attribute.containsProtectedContent.rawValue,
            from: element
        ) == true
        let insertionMode: InsertionMode = isFocusedValueWebArea(
            element,
            bundleIdentifier: frontmost.bundleIdentifier
        ) ? .focusedValueWebArea : .rangeBased
        let security = securityDisposition(
            role: role,
            subrole: subrole,
            containsProtectedContent: containsProtectedContent,
            insertionMode: insertionMode
        )
        let range = copySelectedRange(from: element)
        let markerHash = insertionMode == .focusedValueWebArea
            ? copyAttributeHash(Self.selectedTextMarkerRangeAttribute, from: element)
            : nil
        let fingerprint = Self.fingerprint(
            processIdentifier: frontmost.processIdentifier,
            role: role,
            subrole: subrole,
            range: range,
            markerHash: markerHash
        )

        nextTokenValue &+= 1
        let token = TargetToken(rawValue: nextTokenValue)
        let focusedWindow = copyElementAttribute(
            kAXFocusedWindowAttribute as String,
            from: application
        )
        let windowTitle = focusedWindow.flatMap {
            copyStringAttribute(kAXTitleAttribute as String, from: $0)
        }
        let websiteHost = websiteHost(from: element)
        let browserWindowTitle = websiteHost != nil
            || Self.isBrowserBundleIdentifier(frontmost.bundleIdentifier)
            ? windowTitle
            : nil
        let surface = ContextSurfaceDetector().detect(
            bundleIdentifier: frontmost.bundleIdentifier,
            websiteHost: websiteHost,
            windowTitle: browserWindowTitle
        )
        let initialTargetKind = Self.targetKind(bundleIdentifier: frontmost.bundleIdentifier)
        let classification = ContextCategoryClassifier().classify(
            targetKind: initialTargetKind,
            identityHints: ContextIdentityHints(
                bundleIdentifier: frontmost.bundleIdentifier,
                websiteHost: websiteHost,
                visibleName: surface?.canonicalName,
                role: role,
                subrole: subrole,
                containsProtectedContent: containsProtectedContent
            )
        )
        let targetKind = Self.resolvedTargetKind(
            initialTargetKind,
            category: classification.category
        )
        entries[token] = Entry(
            element: element,
            processIdentifier: frontmost.processIdentifier,
            bundleIdentifier: frontmost.bundleIdentifier,
            security: security,
            sessionID: sessionID,
            insertionMode: insertionMode,
            targetKind: targetKind,
            localCategory: classification.category
        )

        return .captured(
            RegisteredTargetCapture(
                snapshot: TargetSnapshot(
                    processIdentifier: frontmost.processIdentifier,
                    token: token,
                    selectionFingerprint: fingerprint,
                    sessionID: sessionID
                ),
                targetKind: targetKind,
                security: security,
                localCategory: classification.category,
                safeDecoderHints: classification.safeDecoderHints
            )
        )
    }

    func boundedContext(
        for target: TargetSnapshot,
        maximumCharacters: Int
    ) async -> String? {
        guard maximumCharacters > 0,
              let entry = validatedEntry(for: target),
              entry.security == .standard else {
            return nil
        }

        let focusedFieldText = boundedFocusedFieldContext(
            for: entry,
            maximumCharacters: maximumCharacters
        )
        let visibleFragments = shouldCaptureVisibleConversation(for: entry)
            ? visibleConversationFragments(for: entry)
            : []
        return BoundedContextComposer.compose(
            focusedFieldText: focusedFieldText,
            visibleFragments: visibleFragments,
            maximumCharacters: maximumCharacters
        )
    }

    func insertSelectedText(
        _ text: String,
        into target: TargetSnapshot,
        sessionID: DictationSessionID,
        permit: InsertionCommitPermit
    ) async -> DirectInsertionAttempt {
        guard !text.isEmpty,
              target.sessionID == sessionID,
              let entry = validatedEntry(for: target),
              entry.security == .standard else {
            return .denied
        }

        if entry.insertionMode == .focusedValueWebArea {
            return await insertUsingFocusedValueWebArea(
                text,
                into: target,
                permit: permit
            )
        }

        guard let originalRange = copySelectedRange(from: entry.element) else {
            return .denied
        }

        // Chromium/Electron contenteditables can claim AXSelectedText is
        // settable and return success while ignoring the mutation. A focused
        // text element inside AXWebArea therefore uses direct Unicode keyboard
        // events as its single commit route. This never touches the pasteboard.
        if isWebBackedTextElement(entry.element) {
            return await insertUsingUnicodeEvents(
                text,
                into: target,
                originalRange: originalRange,
                permit: permit
            )
        }

        if isAttributeSettable(
            kAXSelectedTextAttribute as String,
            on: entry.element
        ) {
            return await insertUsingSelectedText(
                text,
                into: target,
                originalRange: originalRange,
                permit: permit
            )
        }

        return await insertUsingValue(
            text,
            into: target,
            originalRange: originalRange,
            permit: permit
        )
    }

    func observeRecentCorrection(
        of insertedText: String,
        in target: TargetSnapshot,
        sessionID: DictationSessionID
    ) async {
        guard await isCorrectionLearningEnabled(),
              !insertedText.isEmpty,
              insertedText.utf16.count <= 1_500,
              target.sessionID == sessionID,
              let entry = entries[target.token],
              entry.sessionID == sessionID,
              entry.processIdentifier == target.processIdentifier,
              entry.security == .standard,
              isStillFocused(entry),
              isStandardEditableElement(entry.element),
              let currentRange = copySelectedRange(from: entry.element),
              currentRange.length == 0 else {
            return
        }

        let insertedLength = insertedText.utf16.count
        let insertedStart = currentRange.location - insertedLength
        guard insertedStart >= 0,
              copyString(
                for: CFRange(location: insertedStart, length: insertedLength),
                from: entry.element
              ) == insertedText,
              let characterCount = copyIntegerAttribute(
                kAXNumberOfCharactersAttribute as String,
                from: entry.element
              ),
              characterCount >= insertedStart + insertedLength else {
            return
        }

        let prefixStart = max(0, insertedStart - 32)
        let prefix = copyString(
            for: CFRange(location: prefixStart, length: insertedStart - prefixStart),
            from: entry.element
        ) ?? ""
        let suffixStart = insertedStart + insertedLength
        let suffixLength = min(32, max(0, characterCount - suffixStart))
        let suffix = copyString(
            for: CFRange(location: suffixStart, length: suffixLength),
            from: entry.element
        ) ?? ""
        let language = await correctionLanguage()
        let observation = CorrectionObservation(
            element: entry.element,
            processIdentifier: entry.processIdentifier,
            insertedText: insertedText,
            insertedStart: insertedStart,
            initialCharacterCount: characterCount,
            prefix: prefix,
            suffix: suffix,
            language: language,
            insertedAt: Date()
        )

        Task { [weak self] in
            await self?.pollForRecentCorrection(observation)
        }
    }

    private func pollForRecentCorrection(_ observation: CorrectionObservation) async {
        while Date().timeIntervalSince(observation.insertedAt) < 10 {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard await isCorrectionLearningEnabled(),
                  let currentText = currentObservedText(for: observation) else {
                return
            }
            let elapsed = Date().timeIntervalSince(observation.insertedAt)
            guard let candidate = RecentCorrectionDetector.correction(
                from: observation.insertedText,
                to: currentText,
                language: observation.language,
                secondsSinceInsertion: elapsed
            ) else {
                continue
            }

            do {
                try await Task.sleep(for: .milliseconds(750))
            } catch {
                return
            }
            let confirmationElapsed = Date().timeIntervalSince(observation.insertedAt)
            guard confirmationElapsed <= 10,
                  await isCorrectionLearningEnabled(),
                  let confirmedText = currentObservedText(for: observation),
                  let confirmed = RecentCorrectionDetector.correction(
                    from: observation.insertedText,
                    to: confirmedText,
                    language: observation.language,
                    secondsSinceInsertion: confirmationElapsed
                  ),
                  confirmed.heard == candidate.heard,
                  confirmed.corrected == candidate.corrected else {
                continue
            }
            await correctionSink(confirmed)
            return
        }
    }

    private func currentObservedText(for observation: CorrectionObservation) -> String? {
        guard isStillFocused(
            element: observation.element,
            processIdentifier: observation.processIdentifier
        ),
        isStandardEditableElement(observation.element),
        let characterCount = copyIntegerAttribute(
            kAXNumberOfCharactersAttribute as String,
            from: observation.element
        ) else {
            return nil
        }

        let characterDelta = characterCount - observation.initialCharacterCount
        guard abs(characterDelta) <= 160 else { return nil }
        let currentLength = observation.insertedText.utf16.count + characterDelta
        guard currentLength > 0, currentLength <= 1_660 else { return nil }

        let prefixStart = observation.insertedStart - observation.prefix.utf16.count
        guard prefixStart >= 0,
              observation.prefix.isEmpty || copyString(
                for: CFRange(location: prefixStart, length: observation.prefix.utf16.count),
                from: observation.element
              ) == observation.prefix else {
            return nil
        }

        let suffixStart = observation.insertedStart + currentLength
        guard suffixStart + observation.suffix.utf16.count <= characterCount,
              observation.suffix.isEmpty || copyString(
                for: CFRange(location: suffixStart, length: observation.suffix.utf16.count),
                from: observation.element
              ) == observation.suffix else {
            return nil
        }

        return copyString(
            for: CFRange(location: observation.insertedStart, length: currentLength),
            from: observation.element
        )
    }

    private func insertUsingSelectedText(
        _ text: String,
        into target: TargetSnapshot,
        originalRange: CFRange,
        permit: InsertionCommitPermit
    ) async -> DirectInsertionAttempt {
        guard let commitEntry = validatedEntry(for: target),
              commitEntry.security == .standard,
              let commitRange = copySelectedRange(from: commitEntry.element),
              commitRange.location == originalRange.location,
              commitRange.length == originalRange.length else {
            return .denied
        }

        let execution = permit.performCommit {
            AXUIElementSetAttributeValue(
                commitEntry.element,
                kAXSelectedTextAttribute as CFString,
                text as CFString
            )
        }
        guard case .performed(let writeError) = execution else {
            return .denied
        }
        guard writeError == .success else {
            return .unconfirmedMutation
        }

        return await waitForInsertionConfirmation(
            text,
            originalRange: commitRange,
            element: commitEntry.element
        ) ? .confirmed : .unconfirmedMutation
    }

    private func insertUsingValue(
        _ text: String,
        into target: TargetSnapshot,
        originalRange: CFRange,
        permit: InsertionCommitPermit
    ) async -> DirectInsertionAttempt {
        guard let entry = validatedEntry(for: target),
              isAttributeSettable(kAXValueAttribute as String, on: entry.element),
              isAttributeSettable(
                kAXSelectedTextRangeAttribute as String,
                on: entry.element
              ),
              let originalValue = copyStringAttribute(
                kAXValueAttribute as String,
                from: entry.element
              ),
              originalValue.utf16.count <= AXValueInsertionPlanner.maximumUTF16Length,
              let plan = AXValueInsertionPlanner.makePlan(
                original: originalValue,
                selectionLocation: originalRange.location,
                selectionLength: originalRange.length,
                replacement: text
              ) else {
            return .unsupported
        }

        guard let commitEntry = validatedEntry(for: target),
              let commitRange = copySelectedRange(from: commitEntry.element),
              commitRange.location == originalRange.location,
              commitRange.length == originalRange.length,
              copyStringAttribute(
                kAXValueAttribute as String,
                from: commitEntry.element
              ) == originalValue else {
            return .denied
        }

        let execution = permit.performCommit {
            let valueError = AXUIElementSetAttributeValue(
                commitEntry.element,
                kAXValueAttribute as CFString,
                plan.value as CFString
            )
            guard valueError == .success else { return false }

            var caretRange = CFRange(location: plan.caretLocation, length: 0)
            guard let caretValue = AXValueCreate(.cfRange, &caretRange) else {
                return false
            }
            return AXUIElementSetAttributeValue(
                commitEntry.element,
                kAXSelectedTextRangeAttribute as CFString,
                caretValue
            ) == .success
        }
        guard case .performed(let writeSucceeded) = execution else {
            return .denied
        }
        guard writeSucceeded else {
            return .unconfirmedMutation
        }

        return await waitForValueInsertionConfirmation(
            plan,
            element: commitEntry.element
        ) ? .confirmed : .unconfirmedMutation
    }

    private func insertUsingUnicodeEvents(
        _ text: String,
        into target: TargetSnapshot,
        originalRange: CFRange,
        permit: InsertionCommitPermit
    ) async -> DirectInsertionAttempt {
        guard let eventPairs = makeUnicodeEventPairs(for: text) else {
            return .unsupported
        }
        guard let commitEntry = validatedEntry(for: target),
              commitEntry.security == .standard,
              isWebBackedTextElement(commitEntry.element),
              let commitRange = copySelectedRange(from: commitEntry.element),
              commitRange.location == originalRange.location,
              commitRange.length == originalRange.length else {
            return .denied
        }

        let execution = permit.performCommit {
            for pair in eventPairs {
                pair.keyDown.post(tap: .cghidEventTap)
                pair.keyUp.post(tap: .cghidEventTap)
            }
        }
        guard case .performed = execution else {
            return .denied
        }

        return await waitForInsertionConfirmation(
            text,
            originalRange: commitRange,
            element: commitEntry.element
        ) ? .confirmed : .unconfirmedMutation
    }

    private func insertUsingFocusedValueWebArea(
        _ text: String,
        into target: TargetSnapshot,
        permit: InsertionCommitPermit
    ) async -> DirectInsertionAttempt {
        guard let eventPairs = makeUnicodeEventPairs(for: text),
              let entry = validatedEntry(for: target),
              entry.insertionMode == .focusedValueWebArea,
              isFocusedValueWebArea(
                entry.element,
                bundleIdentifier: entry.bundleIdentifier
              ),
              let originalValue = copyTextMarkerString(from: entry.element),
              originalValue.utf16.count <= AXValueInsertionPlanner.maximumUTF16Length else {
            return .denied
        }

        let execution = permit.performCommit {
            guard self.isStillFocused(entry),
                  self.copyTextMarkerString(from: entry.element) == originalValue else {
                return false
            }
            for pair in eventPairs {
                pair.keyDown.post(tap: .cghidEventTap)
                pair.keyUp.post(tap: .cghidEventTap)
            }
            return true
        }
        guard case .performed(let didPostEvents) = execution else {
            return .denied
        }
        guard didPostEvents else {
            return .denied
        }

        return await waitForFocusedValueWebAreaConfirmation(
            text,
            originalValue: originalValue,
            element: entry.element
        ) ? .confirmed : .unconfirmedMutation
    }

    private func makeUnicodeEventPairs(for text: String) -> [UnicodeEventPair]? {
        guard let chunks = UnicodeEventTextChunker.chunks(text),
              let source = CGEventSource(stateID: .hidSystemState) else {
            return nil
        }

        var pairs: [UnicodeEventPair] = []
        pairs.reserveCapacity(chunks.count)
        for chunk in chunks {
            guard let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: false
            ) else {
                return nil
            }

            let utf16 = Array(chunk.utf16)
            guard utf16.withUnsafeBufferPointer({ buffer -> Bool in
                guard let baseAddress = buffer.baseAddress else { return false }
                keyDown.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: baseAddress
                )
                keyUp.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: baseAddress
                )
                return true
            }) else {
                return nil
            }
            keyDown.flags = []
            keyUp.flags = []
            pairs.append(UnicodeEventPair(keyDown: keyDown, keyUp: keyUp))
        }
        return pairs
    }

    private func boundedFocusedFieldContext(
        for entry: Entry,
        maximumCharacters: Int
    ) -> String? {
        if entry.insertionMode == .focusedValueWebArea {
            return copyTextMarkerString(from: entry.element).map {
                String($0.suffix(maximumCharacters))
            }
        }

        if let selectedRange = copySelectedRange(from: entry.element),
           let characterCount = copyIntegerAttribute(
               kAXNumberOfCharactersAttribute as String,
               from: entry.element
           ),
           characterCount >= 0 {
            let boundedRange = Self.boundedRange(
                around: selectedRange,
                characterCount: characterCount,
                maximumCharacters: maximumCharacters
            )
            if let text = copyString(for: boundedRange, from: entry.element) {
                return String(text.prefix(maximumCharacters))
            }
        }

        return copyStringAttribute(kAXValueAttribute as String, from: entry.element).map {
            String($0.suffix(maximumCharacters))
        }
    }

    private func shouldCaptureVisibleConversation(for entry: Entry) -> Bool {
        entry.targetKind == .chat
            || entry.localCategory == .workMessaging
            || entry.localCategory == .personalMessaging
    }

    private func visibleConversationFragments(for entry: Entry) -> [VisibleContextFragment] {
        guard let root = visibleContextRoot(for: entry) else { return [] }

        var stack: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var visited: [Int: [AXUIElement]] = [:]
        var visitedCount = 0
        var fragments: [VisibleContextFragment] = []

        while let current = stack.popLast(),
              visitedCount < Self.maximumVisibleContextElements,
              fragments.count < 160 {
            let key = Int(CFHash(current.element))
            if visited[key, default: []].contains(where: { CFEqual($0, current.element) }) {
                continue
            }
            visited[key, default: []].append(current.element)
            visitedCount += 1

            guard copyBooleanAttribute(
                kAXHiddenAttribute as String,
                from: current.element
            ) != true else {
                continue
            }

            let subrole = copyStringAttribute(
                kAXSubroleAttribute as String,
                from: current.element
            )
            let containsProtectedContent = copyBooleanAttribute(
                NSAccessibility.Attribute.containsProtectedContent.rawValue,
                from: current.element
            ) == true
            guard !containsProtectedContent,
                  subrole != (kAXSecureTextFieldSubrole as String) else {
                continue
            }

            let role = copyStringAttribute(
                kAXRoleAttribute as String,
                from: current.element
            ) ?? ""
            if !CFEqual(current.element, entry.element),
               Self.visibleContextRoles.contains(role),
               let text = visibleText(from: current.element) {
                fragments.append(
                    VisibleContextFragment(text: String(text.suffix(1_000)))
                )
            }

            guard current.depth < Self.maximumVisibleContextDepth else { continue }
            for child in traversalChildren(from: current.element).reversed() {
                stack.append((child, current.depth + 1))
            }
        }
        return fragments
    }

    private func visibleContextRoot(for entry: Entry) -> AXUIElement? {
        var current = entry.element
        var visited: [AXUIElement] = []

        for _ in 0..<Self.maximumFallbackDepth {
            if copyStringAttribute(
                kAXRoleAttribute as String,
                from: current
            ) == Self.webAreaRole {
                return current
            }
            guard let parent = copyElementAttribute(
                kAXParentAttribute as String,
                from: current
            ),
            !visited.contains(where: { CFEqual($0, parent) }) else {
                break
            }
            visited.append(current)
            current = parent
        }

        let application = AXUIElementCreateApplication(entry.processIdentifier)
        return copyElementAttribute(
            kAXFocusedWindowAttribute as String,
            from: application
        )
    }

    private func visibleText(from element: AXUIElement) -> String? {
        for attribute in [
            kAXValueAttribute as String,
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String
        ] {
            if let value = copyStringAttribute(attribute, from: element),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private func websiteHost(from element: AXUIElement) -> String? {
        var current = element
        var visited: [AXUIElement] = []

        for _ in 0..<Self.maximumFallbackDepth {
            if let host = copyWebsiteHost(from: current) {
                return host
            }
            guard let parent = copyElementAttribute(
                kAXParentAttribute as String,
                from: current
            ),
            !visited.contains(where: { CFEqual($0, parent) }) else {
                return nil
            }
            visited.append(current)
            current = parent
        }
        return nil
    }

    private func copyWebsiteHost(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXURLAttribute as CFString,
            &value
        ) == .success,
        let value else {
            return nil
        }

        if let url = value as? URL {
            return url.host?.lowercased()
        }
        if let url = value as? NSURL {
            return url.host?.lowercased()
        }
        guard let rawValue = value as? String else { return nil }
        if let host = URL(string: rawValue)?.host {
            return host.lowercased()
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("."), !trimmed.contains(" ") else { return nil }
        return trimmed.lowercased()
    }

    func releaseTargets(for sessionID: DictationSessionID) {
        entries = entries.filter { $0.value.sessionID != sessionID }
    }

    private func validatedEntry(for target: TargetSnapshot) -> Entry? {
        guard let entry = entries[target.token],
              entry.sessionID == target.sessionID,
              entry.processIdentifier == target.processIdentifier,
              isStillFocused(entry) else {
            return nil
        }
        let currentRole = copyStringAttribute(
            kAXRoleAttribute as String,
            from: entry.element
        ) ?? ""
        let currentSubrole = copyStringAttribute(
            kAXSubroleAttribute as String,
            from: entry.element
        )
        let containsProtectedContent = copyBooleanAttribute(
            NSAccessibility.Attribute.containsProtectedContent.rawValue,
            from: entry.element
        ) == true
        guard securityDisposition(
            role: currentRole,
            subrole: currentSubrole,
            containsProtectedContent: containsProtectedContent,
            insertionMode: entry.insertionMode
        ) == .standard else {
            return nil
        }
        if entry.insertionMode == .focusedValueWebArea,
           !isFocusedValueWebArea(
            entry.element,
            bundleIdentifier: entry.bundleIdentifier
           ) {
            return nil
        }
        let currentRange = copySelectedRange(from: entry.element)
        let markerHash = entry.insertionMode == .focusedValueWebArea
            ? copyAttributeHash(Self.selectedTextMarkerRangeAttribute, from: entry.element)
            : nil
        guard entry.insertionMode == .focusedValueWebArea ? markerHash != nil : currentRange != nil else {
            return nil
        }
        let currentFingerprint = Self.fingerprint(
            processIdentifier: entry.processIdentifier,
            role: currentRole,
            subrole: currentSubrole,
            range: currentRange,
            markerHash: markerHash
        )
        return currentFingerprint == target.selectionFingerprint ? entry : nil
    }

    private func isStillFocused(_ entry: Entry) -> Bool {
        isStillFocused(
            element: entry.element,
            processIdentifier: entry.processIdentifier
        )
    }

    private func isStillFocused(
        element: AXUIElement,
        processIdentifier: Int32
    ) -> Bool {
        guard let frontmost = Self.frontmostDescriptorSynchronous(),
              frontmost.processIdentifier == processIdentifier else {
            return false
        }
        let application = AXUIElementCreateApplication(processIdentifier)
        if let focusedElement = copyElementAttribute(
            kAXFocusedUIElementAttribute as String,
            from: application
        ) {
            return CFEqual(focusedElement, element)
        }

        // Some Chromium-derived apps expose AXFocused=true on the actual
        // editor but return kAXErrorNoValue for AXFocusedUIElement at the
        // application node. The frontmost-process check above plus the
        // element's focused flag preserves the same fail-closed invariant.
        return copyBooleanAttribute(
            kAXFocusedAttribute as String,
            from: element
        ) == true
    }

    private func isStandardEditableElement(_ element: AXUIElement) -> Bool {
        let role = copyStringAttribute(kAXRoleAttribute as String, from: element) ?? ""
        let subrole = copyStringAttribute(kAXSubroleAttribute as String, from: element)
        let containsProtectedContent = copyBooleanAttribute(
            NSAccessibility.Attribute.containsProtectedContent.rawValue,
            from: element
        ) == true
        return securityDisposition(
            role: role,
            subrole: subrole,
            containsProtectedContent: containsProtectedContent,
            insertionMode: .rangeBased
        ) == .standard
    }

    private func isWebBackedTextElement(_ element: AXUIElement) -> Bool {
        var current = element
        var visited: [AXUIElement] = []

        for _ in 0..<Self.maximumFallbackDepth {
            if copyStringAttribute(
                kAXRoleAttribute as String,
                from: current
            ) == Self.webAreaRole {
                return true
            }
            guard let parent = copyElementAttribute(
                kAXParentAttribute as String,
                from: current
            ),
            !visited.contains(where: { CFEqual($0, parent) }) else {
                return false
            }
            visited.append(current)
            current = parent
        }
        return false
    }

    private func isFocusedValueWebArea(
        _ element: AXUIElement,
        bundleIdentifier: String?
    ) -> Bool {
        let role = copyStringAttribute(kAXRoleAttribute as String, from: element) ?? ""
        let isFocused = copyBooleanAttribute(kAXFocusedAttribute as String, from: element) == true
        let valueIsSettable = isAttributeSettable(kAXValueAttribute as String, on: element)
        let hasSelectedTextMarkerRange = copyAttributeHash(
            Self.selectedTextMarkerRangeAttribute,
            from: element
        ) != nil
        return Self.supportsFocusedValueWebArea(
            bundleIdentifier: bundleIdentifier,
            role: role,
            isFocused: isFocused,
            valueIsSettable: valueIsSettable,
            hasSelectedTextMarkerRange: hasSelectedTextMarkerRange
        )
    }

    private func confirmsInsertion(
        _ text: String,
        originalRange: CFRange,
        element: AXUIElement
    ) -> Bool {
        let insertedRange = CFRange(
            location: originalRange.location,
            length: text.utf16.count
        )
        guard copyString(for: insertedRange, from: element) == text,
              let currentRange = copySelectedRange(from: element) else {
            return false
        }
        return currentRange.location == originalRange.location + text.utf16.count
            && currentRange.length == 0
    }

    private func confirmsValueInsertion(
        _ plan: AXValueInsertionPlan,
        element: AXUIElement
    ) -> Bool {
        guard copyStringAttribute(
            kAXValueAttribute as String,
            from: element
        ) == plan.value,
        let currentRange = copySelectedRange(from: element) else {
            return false
        }
        return currentRange.location == plan.caretLocation && currentRange.length == 0
    }

    private func waitForInsertionConfirmation(
        _ text: String,
        originalRange: CFRange,
        element: AXUIElement
    ) async -> Bool {
        for attempt in 0..<10 {
            if confirmsInsertion(
                text,
                originalRange: originalRange,
                element: element
            ) {
                return true
            }
            if attempt < 9 {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        return false
    }

    private func waitForValueInsertionConfirmation(
        _ plan: AXValueInsertionPlan,
        element: AXUIElement
    ) async -> Bool {
        for attempt in 0..<10 {
            if confirmsValueInsertion(plan, element: element) {
                return true
            }
            if attempt < 9 {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        return false
    }

    private func waitForFocusedValueWebAreaConfirmation(
        _ text: String,
        originalValue: String,
        element: AXUIElement
    ) async -> Bool {
        for attempt in 0..<10 {
            if let currentValue = copyTextMarkerString(from: element),
               AXValueMutationVerifier.confirmsSingleReplacement(
                original: originalValue,
                updated: currentValue,
                replacement: text
            ) {
                return true
            }
            if attempt < 9 {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        return false
    }

    private func isAttributeSettable(
        _ attribute: String,
        on element: AXUIElement
    ) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element,
            attribute as CFString,
            &settable
        ) == .success && settable.boolValue
    }

    private func copyElementAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func copyElementArrayAttribute(
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

    private func traversalChildren(from element: AXUIElement) -> [AXUIElement] {
        let attributes = [
            kAXChildrenAttribute as String,
            Self.childrenInNavigationOrderAttribute,
            kAXVisibleChildrenAttribute as String,
            kAXContentsAttribute as String
        ]
        var candidates = attributes.flatMap {
            copyElementArrayAttribute($0, from: element)
        }

        var sectionsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            Self.sectionsAttribute as CFString,
            &sectionsValue
        ) == .success,
        let sectionsValue,
        CFGetTypeID(sectionsValue) == CFArrayGetTypeID() {
            let sections = sectionsValue as! NSArray
            candidates.append(contentsOf: Self.sectionObjects(from: sections))
        }

        var unique: [AXUIElement] = []
        unique.reserveCapacity(candidates.count)
        for candidate in candidates where !unique.contains(where: { CFEqual($0, candidate) }) {
            unique.append(candidate)
        }
        return unique
    }

    private func focusedElement(
        in application: AXUIElement,
        bundleIdentifier: String?
    ) -> AXUIElement? {
        if let focusedElement = copyElementAttribute(
            kAXFocusedUIElementAttribute as String,
            from: application
        ) {
            let role = copyStringAttribute(
                kAXRoleAttribute as String,
                from: focusedElement
            ) ?? ""
            if Self.supportsEditableRole(role) {
                return focusedElement
            }
            if isFocusedValueWebArea(
                focusedElement,
                bundleIdentifier: bundleIdentifier
            ) {
                return focusedElement
            }
            if let nestedEditor = focusedEditableElement(in: focusedElement) {
                return nestedEditor
            }
        }

        guard let focusedWindow = copyElementAttribute(
            kAXFocusedWindowAttribute as String,
            from: application
        ) else {
            return nil
        }

        return focusedEditableElement(in: focusedWindow)
    }

    private func focusedElementWithActivation(
        in application: AXUIElement,
        processIdentifier: Int32,
        bundleIdentifier: String?
    ) async -> AXUIElement? {
        if let element = focusedElement(
            in: application,
            bundleIdentifier: bundleIdentifier
        ) {
            return element
        }
        guard supportsAttribute(
            Self.enhancedUserInterfaceAttribute,
            on: application
        ),
        enhancedUIActivationRequestedPIDs.insert(processIdentifier).inserted else {
            return nil
        }

        // Chromium handles this request before its AX bridge reports
        // `notImplemented`, then enables the complete web tree after a debounce.
        _ = AXUIElementSetAttributeValue(
            application,
            Self.enhancedUserInterfaceAttribute as CFString,
            kCFBooleanTrue
        )

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.enhancedUIActivationTimeout)
        while clock.now < deadline {
            do {
                try await Task.sleep(for: Self.enhancedUIActivationPollInterval)
            } catch {
                return nil
            }
            if let element = focusedElement(
                in: application,
                bundleIdentifier: bundleIdentifier
            ) {
                return element
            }
        }
        return nil
    }

    private func focusedEditableElement(in root: AXUIElement) -> AXUIElement? {
        BoundedDepthFirstTraversal.first(
            root: root,
            maximumVisited: Self.maximumFallbackVisitedElements,
            maximumDepth: Self.maximumFallbackDepth,
            identity: { Int(CFHash($0)) },
            areEqual: { CFEqual($0, $1) },
            matches: {
                let role = self.copyStringAttribute(
                    kAXRoleAttribute as String,
                    from: $0
                ) ?? ""
                let isFocused = self.copyBooleanAttribute(
                    kAXFocusedAttribute as String,
                    from: $0
                ) == true
                return Self.isFocusedEditableCandidate(
                    role: role,
                    isFocused: isFocused
                )
            },
            children: {
                self.traversalChildren(from: $0)
            }
        )
    }

    private func copyStringAttribute(
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

    private func supportsAttribute(
        _ attribute: String,
        on element: AXUIElement
    ) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let names else {
            return false
        }
        return (names as NSArray).contains { ($0 as? String) == attribute }
    }

    private func copyIntegerAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return (value as? NSNumber)?.intValue
    }

    private func copyBooleanAttribute(
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

    private func copyAttributeHash(
        _ attribute: String,
        from element: AXUIElement
    ) -> UInt? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let value else {
            return nil
        }
        return CFHash(value)
    }

    private func copyTextMarkerString(from element: AXUIElement) -> String? {
        guard let startMarker = copyTextMarker(
            "AXStartTextMarker",
            from: element
        ), let endMarker = copyTextMarker(
            "AXEndTextMarker",
            from: element
        ) else {
            return nil
        }
        let markerRange = AXTextMarkerRangeCreate(nil, startMarker, endMarker)
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXStringForTextMarkerRange" as CFString,
            markerRange,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func copyTextMarker(
        _ attribute: String,
        from element: AXUIElement
    ) -> AXTextMarker? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXTextMarkerGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXTextMarker.self)
    }

    private func copySelectedRange(from element: AXUIElement) -> CFRange? {
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

    private func copyString(for range: CFRange, from element: AXUIElement) -> String? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else {
            return nil
        }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func securityDisposition(
        role: String,
        subrole: String?,
        containsProtectedContent: Bool,
        insertionMode: InsertionMode
    ) -> TargetSecurityDisposition {
        guard !containsProtectedContent,
              subrole != (kAXSecureTextFieldSubrole as String) else {
            return .deniedSensitive
        }
        switch insertionMode {
        case .rangeBased:
            guard Self.supportsEditableRole(role) else { return .deniedSensitive }
        case .focusedValueWebArea:
            guard role == Self.webAreaRole else { return .deniedSensitive }
        }
        return .standard
    }

    nonisolated static func supportsEditableRole(_ role: String) -> Bool {
        role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String)
    }

    nonisolated static func isFocusedEditableCandidate(
        role: String,
        isFocused: Bool
    ) -> Bool {
        isFocused && supportsEditableRole(role)
    }

    nonisolated static func supportsFocusedValueWebArea(
        bundleIdentifier: String?,
        role: String,
        isFocused: Bool,
        valueIsSettable: Bool,
        hasSelectedTextMarkerRange: Bool
    ) -> Bool {
        bundleIdentifier?.lowercased() == mailBundleIdentifier
            && role == webAreaRole
            && isFocused
            && valueIsSettable
            && hasSelectedTextMarkerRange
    }

    nonisolated static func sectionObjects(from sections: NSArray) -> [AXUIElement] {
        sections.compactMap { value in
            guard let section = value as? NSDictionary else { return nil }
            guard let object = section[sectionObjectKey] else { return nil }
            let reference = object as CFTypeRef
            guard CFGetTypeID(reference) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(reference, to: AXUIElement.self)
        }
    }

    private static func boundedRange(
        around selection: CFRange,
        characterCount: Int,
        maximumCharacters: Int
    ) -> CFRange {
        let safeCount = max(0, characterCount)
        let safeLocation = min(max(0, selection.location), safeCount)
        let selectionEnd = min(
            safeCount,
            safeLocation + max(0, selection.length)
        )
        let center = safeLocation + ((selectionEnd - safeLocation) / 2)
        var start = max(0, center - (maximumCharacters / 2))
        let end = min(safeCount, start + maximumCharacters)
        start = max(0, end - maximumCharacters)
        return CFRange(location: start, length: max(0, end - start))
    }

    private static func targetKind(bundleIdentifier: String?) -> TargetKind {
        let identifier = bundleIdentifier?.lowercased() ?? ""
        if ["mail", "outlook"].contains(where: identifier.contains) {
            return .email
        }
        if ["slack", "discord", "messages", "whatsapp", "teams"].contains(where: identifier.contains) {
            return .chat
        }
        if ["pages", "word", "notes", "textedit", "obsidian"].contains(where: identifier.contains) {
            return .document
        }
        return .unknown
    }

    nonisolated static func resolvedTargetKind(
        _ initialTargetKind: TargetKind,
        category: LocalContextCategory
    ) -> TargetKind {
        switch category {
        case .email:
            return .email
        case .workMessaging, .personalMessaging:
            return .chat
        case .other:
            return initialTargetKind
        }
    }

    nonisolated static func isBrowserBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        let identifier = bundleIdentifier?.lowercased() ?? ""
        return [
            "safari", "chrome", "chromium", "brave", "firefox", "arc",
            "edge", "orion", "vivaldi"
        ].contains(where: identifier.contains)
    }

    private static func fingerprint(
        processIdentifier: Int32,
        role: String,
        subrole: String?,
        range: CFRange?,
        markerHash: UInt?
    ) -> SelectionFingerprint {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func append(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        for byte in withUnsafeBytes(of: processIdentifier.littleEndian, Array.init) {
            append(byte)
        }
        for byte in role.utf8 { append(byte) }
        for byte in (subrole ?? "").utf8 { append(byte) }
        var location = Int64(range?.location ?? -1).littleEndian
        var length = Int64(range?.length ?? -1).littleEndian
        var marker = UInt64(markerHash ?? UInt.max).littleEndian
        withUnsafeBytes(of: &location) { bytes in bytes.forEach(append) }
        withUnsafeBytes(of: &length) { bytes in bytes.forEach(append) }
        withUnsafeBytes(of: &marker) { bytes in bytes.forEach(append) }
        return SelectionFingerprint(rawValue: hash)
    }

    @MainActor
    private static func frontmostDescriptor() -> FrontmostDescriptor? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return FrontmostDescriptor(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier
        )
    }

    private static func frontmostDescriptorSynchronous() -> FrontmostDescriptor? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return FrontmostDescriptor(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier
        )
    }
}

enum BoundedDepthFirstTraversal {
    static func first<Node>(
        root: Node,
        maximumVisited: Int,
        maximumDepth: Int,
        identity: (Node) -> Int,
        areEqual: (Node, Node) -> Bool,
        matches: (Node) -> Bool,
        children: (Node) -> [Node]
    ) -> Node? {
        guard maximumVisited > 0, maximumDepth >= 0 else { return nil }

        var stack: [(node: Node, depth: Int)] = [(root, 0)]
        var visited: [Int: [Node]] = [:]
        var visitedCount = 0

        while let current = stack.popLast(), visitedCount < maximumVisited {
            let key = identity(current.node)
            if visited[key, default: []].contains(where: {
                areEqual($0, current.node)
            }) {
                continue
            }
            visited[key, default: []].append(current.node)
            visitedCount += 1

            if matches(current.node) {
                return current.node
            }
            guard current.depth < maximumDepth else { continue }

            for child in children(current.node) {
                stack.append((child, current.depth + 1))
            }
        }

        return nil
    }
}

enum UnicodeEventTextChunker {
    static let maximumUTF16Length = 50_000
    static let maximumChunkUTF16Length = 64

    static func chunks(_ text: String) -> [String]? {
        guard !text.isEmpty,
              text.utf16.count <= maximumUTF16Length else {
            return nil
        }

        var chunks: [String] = []
        var current = ""
        var currentUTF16Length = 0

        for character in text {
            let value = String(character)
            let valueUTF16Length = value.utf16.count
            if !current.isEmpty,
               currentUTF16Length + valueUTF16Length > maximumChunkUTF16Length {
                chunks.append(current)
                current = ""
                currentUTF16Length = 0
            }
            current.append(character)
            currentUTF16Length += valueUTF16Length
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }
}

struct AXValueInsertionPlan: Equatable, Sendable {
    let value: String
    let caretLocation: Int
}

enum AXValueInsertionPlanner {
    static let maximumUTF16Length = 250_000

    static func makePlan(
        original: String,
        selectionLocation: Int,
        selectionLength: Int,
        replacement: String
    ) -> AXValueInsertionPlan? {
        let utf16 = original.utf16
        guard selectionLocation >= 0,
              selectionLength >= 0,
              utf16.count <= maximumUTF16Length,
              selectionLocation <= utf16.count,
              selectionLength <= utf16.count - selectionLocation else {
            return nil
        }

        let lowerUTF16 = utf16.index(utf16.startIndex, offsetBy: selectionLocation)
        let upperUTF16 = utf16.index(lowerUTF16, offsetBy: selectionLength)
        guard let lowerBound = String.Index(lowerUTF16, within: original),
              let upperBound = String.Index(upperUTF16, within: original) else {
            return nil
        }
        let range = lowerBound..<upperBound

        return AXValueInsertionPlan(
            value: original.replacingCharacters(in: range, with: replacement),
            caretLocation: selectionLocation + replacement.utf16.count
        )
    }
}

enum AXValueMutationVerifier {
    static func confirmsSingleReplacement(
        original: String,
        updated: String,
        replacement: String
    ) -> Bool {
        guard !replacement.isEmpty,
              original != updated else {
            return false
        }

        var searchStart = updated.startIndex
        while searchStart <= updated.endIndex,
              let replacementRange = updated.range(
                of: replacement,
                range: searchStart..<updated.endIndex
              ) {
            let prefix = updated[..<replacementRange.lowerBound]
            let suffix = updated[replacementRange.upperBound...]
            if original.hasPrefix(prefix),
               original.hasSuffix(suffix),
               prefix.utf16.count + suffix.utf16.count <= original.utf16.count {
                return true
            }
            searchStart = replacementRange.upperBound
        }
        return false
    }
}

private extension String {
    func prefixString(_ maximumCharacters: Int) -> String {
        String(prefix(maximumCharacters))
    }
}
