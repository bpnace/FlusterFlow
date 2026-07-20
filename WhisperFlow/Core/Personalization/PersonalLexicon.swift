import Foundation

struct PersonalLexiconEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var canonical: String
    var misspellings: [String]
    var language: DictationLanguage
    var priority: Int
    var source: PersonalLexiconSource
    var createdAt: Date
    var updatedAt: Date
}

enum PersonalLexiconSource: String, Codable, Equatable, Sendable {
    case oneWordCorrection
    case manual
    case importList
}

struct PersonalLexiconReplacementRule: Codable, Equatable, Sendable {
    let entryID: UUID
    let misspelling: String
    let canonical: String
    let language: DictationLanguage
    let priority: Int
}

struct PersonalLexiconSuggestion: Codable, Equatable, Identifiable, Sendable {
    enum Reason: String, Codable, Equatable, Sendable {
        case correctionWindowExpired
        case multiTokenCorrection
        case ambiguousMisspelling
    }

    let id: UUID
    let canonical: String
    let misspellings: [String]
    let language: DictationLanguage
    let reason: Reason
}

struct PersonalLexiconCorrection: Equatable, Sendable {
    let heard: String
    let corrected: String
    let language: DictationLanguage
    let secondsSinceInsertion: TimeInterval
}

enum PersonalLexiconLearningResult: Equatable, Sendable {
    case learned(PersonalLexiconEntry)
    case suggested(PersonalLexiconSuggestion)
    case ignored
}

actor LocalPersonalLexiconStore {
    private var entriesByID: [UUID: PersonalLexiconEntry] = [:]
    private var order: [UUID] = []
    private var pendingSuggestions: [UUID: PersonalLexiconSuggestion] = [:]
    private var undoStack: [UndoAction] = []

    init(entries: [PersonalLexiconEntry] = []) {
        for entry in entries {
            entriesByID[entry.id] = entry
            order.append(entry.id)
        }
    }

    func learn(from correction: PersonalLexiconCorrection, now: Date = Date()) -> PersonalLexiconLearningResult {
        let heard = normalizedToken(correction.heard)
        let corrected = normalizedToken(correction.corrected)
        guard !heard.isEmpty, !corrected.isEmpty, heard != corrected else {
            return .ignored
        }

        if !isSingleToken(correction.heard) || !isSingleToken(correction.corrected) {
            return suggest(
                canonical: corrected,
                misspellings: [heard],
                language: correction.language,
                reason: .multiTokenCorrection
            )
        }
        guard correction.secondsSinceInsertion <= 10 else {
            return suggest(
                canonical: corrected,
                misspellings: [heard],
                language: correction.language,
                reason: .correctionWindowExpired
            )
        }
        guard !isAmbiguous(misspelling: heard, canonical: corrected, language: correction.language) else {
            return suggest(
                canonical: corrected,
                misspellings: [heard],
                language: correction.language,
                reason: .ambiguousMisspelling
            )
        }

        if let id = entryID(canonical: corrected, language: correction.language),
           var entry = entriesByID[id] {
            let previous = entry
            entry.canonical = corrected
            if !entry.misspellings.contains(where: { $0.caseInsensitiveCompare(heard) == .orderedSame }) {
                entry.misspellings.append(heard)
            }
            entry.priority += 1
            entry.updatedAt = now
            entriesByID[id] = entry
            undoStack.append(.replace(previous))
            return .learned(entry)
        }

        let entry = PersonalLexiconEntry(
            id: UUID(),
            canonical: corrected,
            misspellings: [heard],
            language: correction.language,
            priority: 1,
            source: .oneWordCorrection,
            createdAt: now,
            updatedAt: now
        )
        entriesByID[entry.id] = entry
        order.append(entry.id)
        undoStack.append(.delete(entry.id))
        return .learned(entry)
    }

    func replacementRules(
        for token: String,
        language: DictationLanguage
    ) -> [PersonalLexiconReplacementRule] {
        let normalized = normalizedToken(token)
        return order.compactMap { id -> PersonalLexiconReplacementRule? in
            guard let entry = entriesByID[id],
                  entry.language == language || entry.language == .automatic,
                  entry.misspellings.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) else {
                return nil
            }
            return PersonalLexiconReplacementRule(
                entryID: entry.id,
                misspelling: normalized,
                canonical: entry.canonical,
                language: entry.language,
                priority: entry.priority
            )
        }
        .sorted { left, right in
            left.priority == right.priority
                ? left.canonical < right.canonical
                : left.priority > right.priority
        }
    }

    func suggestions() -> [PersonalLexiconSuggestion] {
        pendingSuggestions.values.sorted { $0.canonical < $1.canonical }
    }

    func entries() -> [PersonalLexiconEntry] {
        order.compactMap { entriesByID[$0] }
    }

    @discardableResult
    func addManualEntry(
        canonical: String,
        misspellings: [String],
        language: DictationLanguage,
        priority: Int = 0,
        now: Date = Date()
    ) -> PersonalLexiconEntry? {
        let canonical = normalizedToken(canonical)
        let misspellings = normalizedMisspellings(misspellings, excluding: canonical)
        guard !canonical.isEmpty, !misspellings.isEmpty else { return nil }
        let entry = PersonalLexiconEntry(
            id: UUID(),
            canonical: canonical,
            misspellings: misspellings,
            language: language,
            priority: clampedPriority(priority),
            source: .manual,
            createdAt: now,
            updatedAt: now
        )
        entriesByID[entry.id] = entry
        order.append(entry.id)
        undoStack.append(.delete(entry.id))
        return entry
    }

    @discardableResult
    func updateEntry(
        id: UUID,
        canonical: String,
        misspellings: [String],
        language: DictationLanguage,
        priority: Int? = nil,
        source: PersonalLexiconSource? = nil,
        now: Date = Date()
    ) -> PersonalLexiconEntry? {
        guard var entry = entriesByID[id] else { return nil }
        let canonical = normalizedToken(canonical)
        let misspellings = normalizedMisspellings(misspellings, excluding: canonical)
        guard !canonical.isEmpty, !misspellings.isEmpty else { return nil }
        let previous = entry
        entry.canonical = canonical
        entry.misspellings = misspellings
        entry.language = language
        if let priority { entry.priority = clampedPriority(priority) }
        if let source { entry.source = source }
        entry.updatedAt = now
        entriesByID[id] = entry
        undoStack.append(.replace(previous))
        return entry
    }

    @discardableResult
    func prioritize(entryID: UUID, priority: Int? = nil, now: Date = Date()) -> PersonalLexiconEntry? {
        guard var entry = entriesByID[entryID] else { return nil }
        let previous = entry
        entry.priority = priority.map(clampedPriority) ?? clampedPriority((entries().map(\.priority).max() ?? 0) + 1)
        entry.updatedAt = now
        entriesByID[entryID] = entry
        undoStack.append(.replace(previous))
        return entry
    }

    @discardableResult
    func delete(entryID: UUID) -> PersonalLexiconEntry? {
        guard let removed = entriesByID.removeValue(forKey: entryID) else { return nil }
        order.removeAll { $0 == entryID }
        undoStack.append(.insert(removed))
        return removed
    }

    func reset() {
        let snapshot = entries()
        entriesByID.removeAll()
        order.removeAll()
        pendingSuggestions.removeAll()
        undoStack.append(.reset(snapshot))
    }

    @discardableResult
    func applySuggestion(_ id: UUID, priority: Int = 1, now: Date = Date()) -> PersonalLexiconEntry? {
        guard let suggestion = pendingSuggestions.removeValue(forKey: id) else { return nil }
        let entry = PersonalLexiconEntry(
            id: UUID(),
            canonical: suggestion.canonical,
            misspellings: suggestion.misspellings,
            language: suggestion.language,
            priority: clampedPriority(priority),
            source: .oneWordCorrection,
            createdAt: now,
            updatedAt: now
        )
        entriesByID[entry.id] = entry
        order.append(entry.id)
        undoStack.append(.delete(entry.id))
        return entry
    }

    @discardableResult
    func dismissSuggestion(_ id: UUID) -> PersonalLexiconSuggestion? {
        pendingSuggestions.removeValue(forKey: id)
    }

    @discardableResult
    func undoLastChange() -> Bool {
        guard let action = undoStack.popLast() else { return false }
        switch action {
        case .delete(let id):
            entriesByID.removeValue(forKey: id)
            order.removeAll { $0 == id }
        case .insert(let entry):
            entriesByID[entry.id] = entry
            if !order.contains(entry.id) { order.append(entry.id) }
        case .replace(let entry):
            entriesByID[entry.id] = entry
            if !order.contains(entry.id) { order.append(entry.id) }
        case .reset(let entries):
            entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            order = entries.map(\.id)
        }
        return true
    }

    private func suggest(
        canonical: String,
        misspellings: [String],
        language: DictationLanguage,
        reason: PersonalLexiconSuggestion.Reason
    ) -> PersonalLexiconLearningResult {
        let suggestion = PersonalLexiconSuggestion(
            id: UUID(),
            canonical: canonical,
            misspellings: misspellings,
            language: language,
            reason: reason
        )
        pendingSuggestions[suggestion.id] = suggestion
        return .suggested(suggestion)
    }

    private func entryID(canonical: String, language: DictationLanguage) -> UUID? {
        order.first { id in
            guard let entry = entriesByID[id] else { return false }
            return entry.language == language
                && entry.canonical.caseInsensitiveCompare(canonical) == .orderedSame
        }
    }

    private func isAmbiguous(
        misspelling: String,
        canonical: String,
        language: DictationLanguage
    ) -> Bool {
        let matching = entries().filter { entry in
            entry.language == language
                && entry.misspellings.contains {
                    $0.caseInsensitiveCompare(misspelling) == .orderedSame
                }
                && entry.canonical.caseInsensitiveCompare(canonical) != .orderedSame
        }
        return !matching.isEmpty
    }

    private func normalizedToken(_ token: String) -> String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'„“”"))
            .precomposedStringWithCanonicalMapping
    }

    private func normalizedMisspellings(_ misspellings: [String], excluding canonical: String) -> [String] {
        var result: [String] = []
        for misspelling in misspellings.map(normalizedToken) {
            guard !misspelling.isEmpty,
                  misspelling.caseInsensitiveCompare(canonical) != .orderedSame,
                  !result.contains(where: { $0.caseInsensitiveCompare(misspelling) == .orderedSame }) else {
                continue
            }
            result.append(misspelling)
        }
        return result
    }

    private func clampedPriority(_ priority: Int) -> Int {
        min(max(priority, 0), 999)
    }

    private func isSingleToken(_ text: String) -> Bool {
        let normalized = normalizedToken(text)
        guard !normalized.isEmpty else { return false }
        return normalized.range(
            of: #"^[\p{L}\p{N}_][\p{L}\p{N}_'-]*$"#,
            options: .regularExpression
        ) != nil
    }
}

enum RecentCorrectionDetector {
    private static let protectedTerms: Set<String> = [
        "kein", "keine", "keinen", "keinem", "keiner", "keines", "nicht", "nie", "niemals",
        "no", "none", "nor", "not", "never", "without", "weder"
    ]
    private static let forbiddenCharacters = CharacterSet(charactersIn: "@/\\_`\"„“”")
    private static let tokenExpression = try! NSRegularExpression(
        pattern: #"[\p{L}\p{N}_][\p{L}\p{N}_'-]*"#
    )

    static func correction(
        from insertedText: String,
        to currentText: String,
        language: DictationLanguage,
        secondsSinceInsertion: TimeInterval
    ) -> PersonalLexiconCorrection? {
        guard insertedText != currentText,
              insertedText.utf16.count <= 1_500,
              currentText.utf16.count <= 1_660 else {
            return nil
        }

        let heardTokens = tokens(in: insertedText)
        let correctedTokens = tokens(in: currentText)
        guard !heardTokens.isEmpty, !correctedTokens.isEmpty else { return nil }

        var commonPrefixCount = 0
        while commonPrefixCount < heardTokens.count,
              commonPrefixCount < correctedTokens.count,
              heardTokens[commonPrefixCount] == correctedTokens[commonPrefixCount] {
            commonPrefixCount += 1
        }

        var commonSuffixCount = 0
        while commonSuffixCount < heardTokens.count - commonPrefixCount,
              commonSuffixCount < correctedTokens.count - commonPrefixCount,
              heardTokens[heardTokens.count - commonSuffixCount - 1]
                == correctedTokens[correctedTokens.count - commonSuffixCount - 1] {
            commonSuffixCount += 1
        }

        let heardEnd = heardTokens.count - commonSuffixCount
        let correctedEnd = correctedTokens.count - commonSuffixCount
        let heardChange = Array(heardTokens[commonPrefixCount..<heardEnd])
        let correctedChange = Array(correctedTokens[commonPrefixCount..<correctedEnd])
        guard !heardChange.isEmpty,
              !correctedChange.isEmpty,
              heardChange.count <= 4,
              correctedChange.count <= 4 else {
            return nil
        }

        let heard = heardChange.joined(separator: " ")
        let corrected = correctedChange.joined(separator: " ")
        guard heard.count <= 80,
              corrected.count <= 80,
              !isProtected(heard),
              !isProtected(corrected) else {
            return nil
        }

        return PersonalLexiconCorrection(
            heard: heard,
            corrected: corrected,
            language: language,
            secondsSinceInsertion: secondsSinceInsertion
        )
    }

    private static func tokens(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return tokenExpression.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range]).precomposedStringWithCanonicalMapping
        }
    }

    private static func isProtected(_ term: String) -> Bool {
        let normalized = term.lowercased()
        return protectedTerms.contains(normalized)
            || term.rangeOfCharacter(from: .decimalDigits) != nil
            || term.rangeOfCharacter(from: forbiddenCharacters) != nil
            || term.contains("://")
            || term.range(of: #"\S+@\S+\.\S+"#, options: .regularExpression) != nil
    }
}

private enum UndoAction: Sendable {
    case delete(UUID)
    case insert(PersonalLexiconEntry)
    case replace(PersonalLexiconEntry)
    case reset([PersonalLexiconEntry])
}

extension DictationLanguage: Codable {
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "german": self = .german
        case "english": self = .english
        case "automatic": self = .automatic
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unsupported dictation language: \(value)"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .automatic: try container.encode("automatic")
        case .german: try container.encode("german")
        case .english: try container.encode("english")
        }
    }
}
