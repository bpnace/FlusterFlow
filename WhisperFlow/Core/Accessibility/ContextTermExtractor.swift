import Foundation

struct ContextTermExtractor: Sendable {
    static let maximumContextCharacters = 1_500
    static let maximumTerms = 32

    func extract(from context: String) -> [String] {
        extract(selection: nil, nearbyContext: context)
    }

    func extract(selection: String?, nearbyContext: String) -> [String] {
        let selected = String((selection ?? "").prefix(Self.maximumContextCharacters))
        let remaining = max(0, Self.maximumContextCharacters - selected.count)
        let nearby = String(nearbyContext.prefix(remaining))
        var seen: Set<String> = []
        var result: [String] = []

        func append(_ candidate: String) {
            guard result.count < Self.maximumTerms else { return }
            let key = normalized(candidate)
            guard key.count >= 2, seen.insert(key).inserted else { return }
            result.append(candidate)
        }

        if !selected.isEmpty {
            candidates(in: selected, selection: true).forEach(append)
        }
        candidates(in: nearby, selection: false).forEach(append)
        return result
    }

    private func candidates(in text: String, selection: Bool) -> [String] {
        let scrubbed = scrubSensitiveContent(in: text)
        let tokens = wordTokens(in: scrubbed).filter { isBasicCandidate($0.text) }
        guard !tokens.isEmpty else { return [] }

        let frequencies = Dictionary(grouping: tokens, by: { normalized($0.text) })
            .mapValues(\.count)
        let strong = tokens.filter { isStrongSignal($0.text) }
        let repeatedLowercase = tokens.filter {
            $0.text.allSatisfy(\.isLowercase)
                && $0.text.filter(\.isLetter).count >= 5
                && frequencies[normalized($0.text), default: 0] >= 2
        }
        let titlecase = tokens.filter { isTitlecase($0.text) }
        let phrases = shortPhrases(
            in: scrubbed,
            tokens: tokens,
            selection: selection
        )

        var seen: Set<String> = []
        return (strong.map(\.text) + phrases + repeatedLowercase.map(\.text) + titlecase.map(\.text))
            .filter { seen.insert(normalized($0)).inserted }
    }

    private func wordTokens(in text: String) -> [Token] {
        let pattern = #"[\p{L}][\p{L}\p{M}\p{N}_]{1,63}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        ).map { Token(text: source.substring(with: $0.range), range: $0.range) }
    }

    private func shortPhrases(
        in source: String,
        tokens: [Token],
        selection: Bool
    ) -> [String] {
        guard tokens.count >= 2 else { return [] }
        let nsSource = source as NSString
        var phrases: [String] = []
        for start in tokens.indices {
            let maximumCount = min(3, tokens.count - start)
            guard maximumCount >= 2 else { continue }
            for count in 2...maximumCount {
                let slice = Array(tokens[start..<(start + count)])
                guard slice.dropFirst().enumerated().allSatisfy({ offset, token in
                    let previous = slice[offset]
                    let gap = NSRange(
                        location: NSMaxRange(previous.range),
                        length: token.range.location - NSMaxRange(previous.range)
                    )
                    return nsSource.substring(with: gap).allSatisfy { $0.isWhitespace || $0 == "-" }
                }) else { continue }

                let words = slice.map(\.text)
                let phraseKey = words.map(normalized)
                let repeated = tokens.indices.filter { candidateStart in
                    candidateStart + count <= tokens.count
                        && Array(tokens[candidateStart..<(candidateStart + count)]).map {
                            normalized($0.text)
                        } == phraseKey
                }.count >= 2
                let allTitlecase = words.allSatisfy(isTitlecase)
                guard selection || repeated || allTitlecase else { continue }
                let phrase = words.joined(separator: " ")
                if phrase.count <= 48 { phrases.append(phrase) }
            }
        }
        return phrases
    }

    private func scrubSensitiveContent(in text: String) -> String {
        let patterns = [
            #"(?i)\b(?:https?|ftp)://[^\s]+"#,
            #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            #"\b(?:sk|pk|api)[-_][A-Za-z0-9_-]{12,}\b"#,
            #"\b\d(?:[ -]?\d){11,}\b"#,
            #"(?<![\p{L}\p{N}_])[@#][\p{L}\p{N}_-]+"#
        ]
        return patterns.reduce(text) { result, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
            let range = NSRange(location: 0, length: (result as NSString).length)
            return regex.stringByReplacingMatches(in: result, range: range, withTemplate: " ")
        }
    }

    private func isBasicCandidate(_ token: String) -> Bool {
        let key = normalized(token)
        return key.count >= 2 && !Self.commonWords.contains(key)
    }

    private func isStrongSignal(_ token: String) -> Bool {
        let letters = token.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        let internalUppercase = letters.dropFirst().contains(where: \.isUppercase)
        let identifier = token.contains("_") || token.contains(where: \.isNumber)
        let acronym = letters.allSatisfy(\.isUppercase)
        return internalUppercase || identifier || acronym
    }

    private func isTitlecase(_ token: String) -> Bool {
        let letters = token.filter(\.isLetter)
        guard letters.count >= 3, letters.first?.isUppercase == true else { return false }
        return letters.dropFirst().allSatisfy(\.isLowercase)
    }

    private func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private struct Token {
        let text: String
        let range: NSRange
    }

    private static let commonWords: Set<String> = [
        "about", "adapter", "after", "all", "also", "am", "an", "and", "anlage", "architecture",
        "architektur", "attachment", "aus", "available", "bei", "bericht", "berichte", "betreff",
        "bleibt", "build", "component", "context", "das", "date", "dem", "den", "der", "die",
        "document", "draft", "eine", "einen", "einer", "eingaben", "email", "entwurf", "error",
        "errors", "for", "friday", "fur", "gegen", "has", "hat", "historie", "im", "in", "input",
        "ist", "jetzt", "keine", "keinen", "komponente", "local", "lokal", "meeting", "mit", "mode",
        "module", "modules", "morgen", "nach", "network", "netzwerktransport", "next", "nicht", "no",
        "dienstag", "freitag", "lauf", "modul", "montag", "ohne", "on", "one", "optionen", "options",
        "plan", "please", "ready", "report", "reports", "revision", "run", "send", "start", "status",
        "subject", "termin", "test", "testing", "testmodus", "the", "this", "to", "today", "transport",
        "tuesday", "und", "verfugbar", "without", "wurde"
    ]
}
