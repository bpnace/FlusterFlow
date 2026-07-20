import Foundation

struct MeaningPreservationRuleResult: Equatable, Sendable {
    let accepts: Bool
    let issues: [TextRewriteValidationIssue]
}

struct ContextSupportedMeaningPreservationRules: Sendable {
    func evaluate(
        localText: String,
        proposedText: String,
        protectedContextTerms: [String]
    ) -> MeaningPreservationRuleResult {
        let local = localText.precomposedStringWithCanonicalMapping
        let proposed = proposedText.precomposedStringWithCanonicalMapping
        guard !local.isEmpty, !proposed.isEmpty else {
            return result(local == proposed ? [] : [.excessiveDeviation])
        }

        var issues: [TextRewriteValidationIssue] = []
        if protectedAnchors(in: local) != protectedAnchors(in: proposed) {
            issues.append(.lostProtectedAnchor)
        }
        if hasChangedProtectedName(
            local: local,
            proposed: proposed,
            protectedContextTerms: protectedContextTerms
        ) {
            issues.append(.lostProtectedAnchor)
        }
        if hasLostContextTerm(
            protectedContextTerms,
            local: local,
            proposed: proposed
        ) {
            issues.append(.lostProtectedContextTerm)
        }
        if hasInventedNamedEntity(
            local: local,
            proposed: proposed,
            protectedContextTerms: protectedContextTerms
        ) {
            issues.append(.inventedClaim)
        }
        if hasUnsupportedClaim(
            local: local,
            proposed: proposed,
            protectedContextTerms: protectedContextTerms
        ) {
            issues.append(.inventedClaim)
        }
        let hasSourceLoss = hasSubstantialSourceLoss(
            local: local,
            proposed: proposed,
            protectedContextTerms: protectedContextTerms
        )
        if hasSourceLoss {
            issues.append(.excessiveDeviation)
        }
        let hasUnsafeClause = clauseSupportIsUnsafe(
            local: local,
            proposed: proposed,
            protectedContextTerms: protectedContextTerms
        )
        if hasUnsafeClause {
            issues.append(.excessiveDeviation)
        }

        return result(issues)
    }

    private func result(_ issues: [TextRewriteValidationIssue]) -> MeaningPreservationRuleResult {
        let uniqueIssues = Array(Set(issues)).sorted { "\($0)" < "\($1)" }
        return MeaningPreservationRuleResult(
            accepts: uniqueIssues.isEmpty,
            issues: uniqueIssues
        )
    }

    private func protectedAnchors(in text: String) -> [String: Int] {
        let patterns = [
            #"(?i)\b(?:https?|ftp)://[^\s]+"#,
            #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            #"(?<![\p{L}\p{N}_])(?:@|#)[\p{L}\p{N}_-]+"#,
            #"(?<![\p{L}\p{N}])\d+(?:[.,:/-]\d+)*(?![\p{L}\p{N}])"#,
            #"[„“”\"]([^„“”\"]+)[„“”\"]"#,
            #"(?<![\p{L}\p{N}_])[\p{Ll}]+[\p{Lu}][\p{L}\p{N}_]*(?![\p{L}\p{N}_])"#
        ]
        var anchors: [String: Int] = [:]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let source = text as NSString
            for match in regex.matches(
                in: text,
                range: NSRange(location: 0, length: source.length)
            ) {
                let capture = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound
                    ? match.range(at: 1)
                    : match.range
                anchors[canonicalAnchor(source.substring(with: capture)), default: 0] += 1
            }
        }

        for word in lexicalTokens(in: text) where Self.anchorWords.contains(word) {
            anchors["word:\(word)", default: 0] += 1
        }
        return anchors
    }

    private func hasLostContextTerm(
        _ terms: [String],
        local: String,
        proposed: String
    ) -> Bool {
        let canonicalLocal = canonicalAnchor(local)
        let canonicalProposed = canonicalAnchor(proposed)
        for term in Set(terms.map(canonicalAnchor)) where !term.isEmpty {
            if canonicalLocal.contains(term), !canonicalProposed.contains(term) {
                return true
            }
        }
        return false
    }

    private func hasInventedNamedEntity(
        local: String,
        proposed: String,
        protectedContextTerms: [String]
    ) -> Bool {
        let localEntities = namedEntities(in: local)
        let contextEntities = Set(protectedContextTerms.map(canonicalAnchor))
        let localTokens = lexicalTokens(in: local)
        let supportedEntityTokens = localTokens
            + protectedContextTerms.flatMap { lexicalTokens(in: $0) }
        for entity in namedEntities(in: proposed).subtracting(localEntities) {
            if contextEntities.contains(entity) { continue }
            let entityTokens = lexicalTokens(in: entity)
            if entityTokens.allSatisfy({ isSupported($0, by: supportedEntityTokens) }) { continue }
            return true
        }
        let supportedTokens = localTokens + protectedContextTerms.flatMap { lexicalTokens(in: $0) }
        for token in capitalizedTokens(in: proposed) {
            if isSupported(token, by: supportedTokens) { continue }
            return true
        }
        return false
    }

    private func capitalizedTokens(in text: String) -> [String] {
        let pattern = #"(?<![\p{L}\p{N}_])(?:[\p{Lu}][\p{Ll}\p{M}-]{2,}|[\p{Lu}][\p{Lu}\p{N}_-]{1,})(?![\p{L}\p{N}_])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        ).compactMap { match in
            let prefix = source.substring(to: match.range.location)
                .trimmingCharacters(in: .whitespaces)
            if prefix.isEmpty || prefix.last.map({ ".!?\n".contains($0) }) == true {
                return nil
            }
            return lexicalTokens(in: source.substring(with: match.range)).first
        }
    }

    private func hasChangedProtectedName(
        local: String,
        proposed: String,
        protectedContextTerms: [String]
    ) -> Bool {
        let localNames = protectedNames(in: local)
        let proposedNames = protectedNames(in: proposed)
        var removed = Array(localNames.subtracting(proposedNames))
        var added = Array(proposedNames.subtracting(localNames))
        guard !removed.isEmpty || !added.isEmpty else { return false }

        let contextTerms = Set(protectedContextTerms.map(canonicalAnchor))
        while let localName = removed.popLast() {
            guard let replacementIndex = added.firstIndex(where: { proposedName in
                contextTerms.contains(proposedName)
                    && namesAreNear(localName, proposedName)
            }) else {
                return true
            }
            added.remove(at: replacementIndex)
        }
        let supportedTokens = lexicalTokens(in: local)
            + protectedContextTerms.flatMap { lexicalTokens(in: $0) }
        return added.contains { entity in
            let entityTokens = lexicalTokens(in: entity)
            return entityTokens.isEmpty
                || !entityTokens.allSatisfy { isSupported($0, by: supportedTokens) }
        }
    }

    private func protectedNames(in text: String) -> Set<String> {
        var names = namedEntities(in: text)
        let cuePattern = #"(?:^|\b)(?i:an|bei|dear|for|für|hallo|hi|liebe|lieber|mit|to|von|with)\s+([\p{Lu}][\p{L}\p{M}-]{2,})(?![\p{L}\p{N}])"#
        guard let regex = try? NSRegularExpression(pattern: cuePattern) else { return names }
        let source = text as NSString
        for match in regex.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        ) where match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound {
            names.insert(canonicalAnchor(source.substring(with: match.range(at: 1))))
        }
        return names
    }

    private func namesAreNear(_ local: String, _ proposed: String) -> Bool {
        let localTokens = lexicalTokens(in: local)
        let proposedTokens = lexicalTokens(in: proposed)
        guard localTokens.count == proposedTokens.count else { return false }
        return zip(localTokens, proposedTokens).allSatisfy { left, right in
            left == right || (
                min(left.count, right.count) >= 3
                    && abs(left.count - right.count) <= 2
                    && editDistance(left, right) <= max(1, min(left.count, right.count) / 4)
            )
        }
    }

    private func namedEntities(in text: String) -> Set<String> {
        let pattern = #"(?<![\p{L}\p{N}])(?:[\p{Lu}][\p{Ll}\p{M}]+)(?:\s+[\p{Lu}][\p{Ll}\p{M}]+)+(?![\p{L}\p{N}])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return Set(regex.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        ).map { canonicalAnchor(source.substring(with: $0.range)) })
    }

    private func hasUnsupportedClaim(
        local: String,
        proposed: String,
        protectedContextTerms: [String]
    ) -> Bool {
        let localTokens = contentTokens(in: local)
        let supportTokens = localTokens + protectedContextTerms.flatMap { lexicalTokens(in: $0) }
        var unsupported = 0
        for token in contentTokens(in: proposed) {
            if isSupported(token, by: supportTokens) { continue }
            unsupported += 1
        }
        return unsupported >= 2
    }

    private func hasSubstantialSourceLoss(
        local: String,
        proposed: String,
        protectedContextTerms: [String]
    ) -> Bool {
        let localTokens = contentTokens(in: local)
        guard localTokens.count >= 4 else { return false }
        let proposedTokens = contentTokens(in: proposed) + protectedContextTerms.flatMap {
            lexicalTokens(in: $0)
        }
        let supportedLocal = localTokens.filter { isSupported($0, by: proposedTokens) }.count
        let coverage = Double(supportedLocal) / Double(localTokens.count)
        return coverage < 0.45
    }

    private func clauseSupportIsUnsafe(
        local: String,
        proposed: String,
        protectedContextTerms: [String]
    ) -> Bool {
        let localTokens = contentTokens(in: local)
        let supportTokens = localTokens + protectedContextTerms.flatMap { lexicalTokens(in: $0) }
        guard !localTokens.isEmpty else { return false }

        let proposedClauses = clauses(in: proposed).map { contentTokens(in: $0) }.filter { !$0.isEmpty }
        guard !proposedClauses.isEmpty else { return false }

        for clause in proposedClauses {
            let supported = clause.filter { isSupported($0, by: supportTokens) }.count
            let coverage = Double(supported) / Double(clause.count)
            if coverage < 0.55, clause.count >= 3 {
                return true
            }
        }
        return false
    }

    private func clauses(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"[.!?;:]+|\s+(?:and|but|oder|aber)\s+"#) else {
            return [text]
        }
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        var clauses: [String] = []
        var start = 0
        for match in regex.matches(in: text, range: range) {
            let length = match.range.location - start
            if length > 0 {
                clauses.append(source.substring(with: NSRange(location: start, length: length)))
            }
            start = match.range.location + match.range.length
        }
        if start < source.length {
            clauses.append(source.substring(from: start))
        }
        return clauses
    }

    private func isSupported(_ token: String, by supportTokens: [String]) -> Bool {
        supportTokens.contains(token)
            || Self.synonyms[token]?.contains(where: { supportTokens.contains($0) }) == true
            || isNearSupported(token, by: supportTokens)
    }

    private func isNearSupported(_ token: String, by supportTokens: [String]) -> Bool {
        guard token.count >= 5 else { return false }
        return supportTokens.contains { candidate in
            candidate.count >= 5
                && abs(candidate.count - token.count) <= 2
                && editDistance(candidate, token) <= max(1, min(candidate.count, token.count) / 4)
        }
    }

    private func contentTokens(in text: String) -> [String] {
        lexicalTokens(in: normalizedSemanticPhrases(in: text)).filter {
            !Self.stopWords.contains($0) && !Self.fillerWords.contains($0)
        }
    }

    private func normalizedSemanticPhrases(in text: String) -> String {
        [
            (#"(?i)\blass(?:e)?\s+mich\s+wissen\b"#, "sag"),
            (#"(?i)\bgib\s+mir\s+bescheid\b"#, "sag")
        ].reduce(text) { value, replacement in
            value.replacingOccurrences(
                of: replacement.0,
                with: replacement.1,
                options: .regularExpression
            )
        }
    }

    private func lexicalTokens(in text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let pattern = #"[\p{L}\p{N}]+(?:-[\p{L}\p{N}]+)*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = folded as NSString
        return regex.matches(
            in: folded,
            range: NSRange(location: 0, length: source.length)
        ).map { source.substring(with: $0.range) }
    }

    private func canonicalAnchor(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}<>"))
    }

    private func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }

        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)
        for leftIndex in 1...left.count {
            current[0] = leftIndex
            for rightIndex in 1...right.count {
                let substitution = previous[rightIndex - 1]
                    + (left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1)
                current[rightIndex] = min(
                    previous[rightIndex] + 1,
                    current[rightIndex - 1] + 1,
                    substitution
                )
            }
            previous = current
        }
        return previous[right.count]
    }

    private static let anchorWords = Set([
        "kein", "keine", "keinen", "keiner", "keines", "nicht", "never", "no", "not",
        "null", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty",
        "sixty", "seventy", "eighty", "ninety", "zero", "eins", "eine", "einen",
        "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn",
        "elf", "zwölf", "dreizehn", "vierzehn", "fünfzehn", "sechzehn", "siebzehn",
        "achtzehn", "neunzehn", "zwanzig", "dreißig", "vierzig", "fünfzig",
        "sechzig", "siebzig", "achtzig", "neunzig"
    ])

    private static let stopWords = Set([
        "a", "am", "an", "and", "are", "as", "at", "be", "by", "das", "der", "die",
        "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "er", "es", "etwas",
        "for", "für", "ihr", "im", "in", "is", "ist", "it", "mit", "of", "on", "or",
        "auf", "hin", "sie", "the", "to", "und", "von", "was", "we", "werden", "wird", "zu", "zur", "zum",
        "wenn", "wir", "then", "dann"
    ])

    private static let fillerWords = Set([
        "ah", "ahm", "äh", "ähm", "eh", "hm", "okay", "also", "quasi", "halt", "so",
        "basically", "um", "uh", "like"
    ])

    private static let synonyms: [String: Set<String>] = [
        "bericht": ["report"],
        "report": ["bericht"],
        "sende": ["send", "schick", "schicke"],
        "send": ["sende", "schick", "schicke"],
        "schick": ["send", "sende", "schicke"],
        "schicke": ["send", "sende", "schick"],
        "meeting": ["termin", "besprechung"],
        "termin": ["meeting", "besprechung"],
        "besprechung": ["meeting", "termin"],
        "auch": ["gleichzeitig", "gleich"],
        "gleich": ["auch", "gleichzeitig"],
        "gleichzeitig": ["auch", "gleich"],
        "gucken": ["prufen", "kontrollieren", "ansehen"],
        "prufen": ["gucken", "kontrollieren", "ansehen"],
        "pruf": ["prufe", "prufen", "kontrolliere", "kontrollieren"],
        "prufe": ["pruf", "prufen", "kontrolliere", "kontrollieren"],
        "kontrollieren": ["gucken", "prufen", "ansehen"],
        "ansehen": ["gucken", "prufen", "kontrollieren"],
        "alle": ["alles"],
        "alles": ["alle"],
        "auffalligkeiten": ["auffallig", "komisch", "seltsam"],
        "auffallig": ["auffalligkeiten", "komisch", "seltsam"],
        "komisch": ["auffalligkeiten", "auffallig", "seltsam"],
        "seltsam": ["auffalligkeiten", "auffallig", "komisch"],
        "hinweisen": ["rausgerufen", "herausgerufen", "anmerken", "benennen", "melden", "melde", "sag", "sage", "weise"],
        "melde": ["hinweisen", "weise", "sag", "sage"],
        "weise": ["hinweisen", "melde", "sag", "sage"],
        "sag": ["hinweisen", "melde", "weise", "sage"],
        "sage": ["hinweisen", "melde", "weise", "sag"],
        "erneut": ["noch", "nochmal", "wieder"],
        "noch": ["erneut", "nochmal", "wieder"],
        "mal": ["erneut", "nochmal", "wieder"],
        "nochmal": ["erneut", "wieder"],
        "wieder": ["erneut", "nochmal"],
        "rausgerufen": ["hinweisen", "herausgerufen", "anmerken", "benennen", "melden"],
        "herausgerufen": ["hinweisen", "rausgerufen", "anmerken", "benennen", "melden"],
        "anmerken": ["hinweisen", "rausgerufen", "herausgerufen", "benennen", "melden"],
        "benennen": ["hinweisen", "rausgerufen", "herausgerufen", "anmerken", "melden"],
        "melden": ["hinweisen", "rausgerufen", "herausgerufen", "anmerken", "benennen"]
    ]
}
