import Foundation

@MainActor
final class PersonalLexiconStore: ObservableObject {
    private static let applicationPreferencesDomain = "com.flusterflow.private"

    private enum Key {
        static let entries = "flusterflow.personal-lexicon.entries"
    }

    @Published private(set) var entries: [PersonalLexiconEntry]
    @Published private(set) var suggestions: [PersonalLexiconSuggestion] = []

    private let defaults: UserDefaults
    private var undoStack: [[PersonalLexiconEntry]] = []

    var canUndo: Bool {
        !undoStack.isEmpty
    }

    var canReset: Bool {
        !entries.isEmpty || !suggestions.isEmpty
    }

    func entries(for language: DictationLanguage) -> [PersonalLexiconEntry] {
        entries.filter {
            $0.language == .automatic || language == .automatic || $0.language == language
        }
    }

    func prioritizedDecoderTerms(for language: DictationLanguage) -> [String] {
        entries(for: language)
            .filter { Self.isSafeDecoderTerm($0.canonical) }
            .sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                return $0.updatedAt > $1.updatedAt
            }
            .prefix(32)
            .map(\.canonical)
    }

    init(defaults suppliedDefaults: UserDefaults? = nil) {
        let defaults = suppliedDefaults ?? Self.applicationDefaults()
        self.defaults = defaults
        entries = Self.loadEntries(from: defaults)
    }

    @discardableResult
    func add(
        canonical: String,
        misspellings: [String] = [],
        language: DictationLanguage = .automatic,
        priority: Int = 0,
        now: Date = Date()
    ) -> PersonalLexiconEntry? {
        guard let normalizedCanonical = Self.normalizedTerm(canonical) else { return nil }
        pushUndoState()
        let entry = PersonalLexiconEntry(
            id: UUID(),
            canonical: normalizedCanonical,
            misspellings: Self.normalizedTerms(misspellings),
            language: language,
            priority: Self.clampedPriority(priority),
            source: .manual,
            createdAt: now,
            updatedAt: now
        )
        entries.append(entry)
        sortAndPersist()
        return entry
    }

    @discardableResult
    func update(
        id: UUID,
        canonical: String,
        misspellings: [String],
        language: DictationLanguage,
        priority: Int? = nil,
        now: Date = Date()
    ) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              let normalizedCanonical = Self.normalizedTerm(canonical) else {
            return false
        }
        pushUndoState()
        entries[index].canonical = normalizedCanonical
        entries[index].misspellings = Self.normalizedTerms(misspellings)
        entries[index].language = language
        if let priority {
            entries[index].priority = Self.clampedPriority(priority)
        }
        entries[index].updatedAt = now
        sortAndPersist()
        return true
    }

    @discardableResult
    func prioritize(id: UUID, now: Date = Date()) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        pushUndoState()
        let nextPriority = (entries.map(\.priority).max() ?? 0) + 1
        entries[index].priority = Self.clampedPriority(nextPriority)
        entries[index].updatedAt = now
        sortAndPersist()
        return true
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        pushUndoState()
        entries.remove(at: index)
        persist()
        return true
    }

    @discardableResult
    func reset() -> Bool {
        guard canReset else { return false }
        if !entries.isEmpty {
            pushUndoState()
        }
        entries = []
        suggestions = []
        persist()
        return true
    }

    func applyLearningResult(_ result: PersonalLexiconLearningResult) {
        switch result {
        case .learned(let learnedEntry):
            pushUndoState()
            if let index = entries.firstIndex(where: { $0.id == learnedEntry.id }) {
                entries[index] = learnedEntry
            } else {
                entries.append(learnedEntry)
            }
            sortAndPersist()
        case .suggested(let suggestion):
            guard !suggestions.contains(where: {
                $0.canonical.caseInsensitiveCompare(suggestion.canonical) == .orderedSame
                    && $0.misspellings.map { $0.lowercased() }
                        == suggestion.misspellings.map { $0.lowercased() }
            }) else {
                return
            }
            suggestions.append(suggestion)
            suggestions.sort {
                $0.canonical.localizedStandardCompare($1.canonical) == .orderedAscending
            }
        case .ignored:
            break
        }
    }

    @discardableResult
    func acceptSuggestion(id: UUID, now: Date = Date()) -> PersonalLexiconEntry? {
        guard let index = suggestions.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let suggestion = suggestions.remove(at: index)
        pushUndoState()
        let entry = PersonalLexiconEntry(
            id: UUID(),
            canonical: suggestion.canonical,
            misspellings: suggestion.misspellings,
            language: suggestion.language,
            priority: 1,
            source: .oneWordCorrection,
            createdAt: now,
            updatedAt: now
        )
        entries.append(entry)
        sortAndPersist()
        return entry
    }

    @discardableResult
    func dismissSuggestion(id: UUID) -> Bool {
        guard let index = suggestions.firstIndex(where: { $0.id == id }) else {
            return false
        }
        suggestions.remove(at: index)
        return true
    }

    @discardableResult
    func undoLastChange() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        entries = previous
        persist()
        return true
    }

    private func pushUndoState() {
        undoStack.append(entries)
        if undoStack.count > 20 {
            undoStack.removeFirst(undoStack.count - 20)
        }
        objectWillChange.send()
    }

    private func sortAndPersist() {
        entries.sort {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.canonical.localizedStandardCompare($1.canonical) == .orderedAscending
        }
        persist()
    }

    private func persist() {
        defaults.set(
            try? JSONEncoder().encode(entries.map(PersistentPersonalLexiconEntry.init)),
            forKey: Key.entries
        )
    }

    private static func loadEntries(from defaults: UserDefaults) -> [PersonalLexiconEntry] {
        guard let data = defaults.data(forKey: Key.entries),
              let decoded = try? JSONDecoder().decode([PersistentPersonalLexiconEntry].self, from: data) else {
            return []
        }
        return decoded.map(\.entry).sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.canonical.localizedStandardCompare($1.canonical) == .orderedAscending
        }
    }

    private static func normalizedTerms(_ terms: [String]) -> [String] {
        terms.compactMap(normalizedTerm)
            .removingDuplicates()
            .prefix(12)
            .map { $0 }
    }

    private static func normalizedTerm(_ term: String) -> String? {
        let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty,
              normalized.count <= 80,
              normalized.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        return normalized
    }

    private static func clampedPriority(_ priority: Int) -> Int {
        min(max(priority, 0), 999)
    }

    private static func isSafeDecoderTerm(_ term: String) -> Bool {
        let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = normalized.lowercased()
        let excludedGeneralTerms: Set<String> = [
            "also", "halt", "quasi", "eigentlich", "und", "oder", "aber",
            "the", "and", "or", "but"
        ]
        guard normalized.count >= 2,
              normalized.count <= 80,
              !excludedGeneralTerms.contains(lowercased),
              !lowercased.contains("password"),
              !lowercased.contains("passwort"),
              !lowercased.contains("secret"),
              normalized.range(of: #"\S+@\S+\.\S+"#, options: .regularExpression) == nil,
              normalized.range(of: #"https?://"#, options: .regularExpression) == nil else {
            return false
        }
        return true
    }

    private static func applicationDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: applicationPreferencesDomain) else {
            return .standard
        }
        return defaults
    }
}

private struct PersistentPersonalLexiconEntry: Codable {
    let id: UUID
    let canonical: String
    let misspellings: [String]
    let language: String
    let priority: Int
    let source: String
    let createdAt: Date
    let updatedAt: Date

    init(_ entry: PersonalLexiconEntry) {
        id = entry.id
        canonical = entry.canonical
        misspellings = entry.misspellings
        language = entry.language.storageValue
        priority = entry.priority
        source = entry.source.storageValue
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
    }

    var entry: PersonalLexiconEntry {
        PersonalLexiconEntry(
            id: id,
            canonical: canonical,
            misspellings: misspellings,
            language: DictationLanguage(storageValue: language),
            priority: priority,
            source: PersonalLexiconSource(storageValue: source),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private extension PersonalLexiconSource {
    var storageValue: String {
        switch self {
        case .oneWordCorrection: "oneWordCorrection"
        case .manual: "manual"
        case .importList: "importList"
        }
    }

    init(storageValue: String) {
        switch storageValue {
        case "oneWordCorrection": self = .oneWordCorrection
        case "importList": self = .importList
        default: self = .manual
        }
    }
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
