import Foundation

struct PersonalLexiconCorrector: Sendable {
    func correct(
        _ text: String,
        entries: [PersonalLexiconEntry],
        language: DictationLanguage
    ) -> String {
        guard !text.isEmpty else { return text }
        let applicable = entries
            .filter {
                $0.language == .automatic || language == .automatic || $0.language == language
            }
            .flatMap { entry in
                entry.misspellings.map { misspelling in
                    (misspelling: misspelling, canonical: entry.canonical, priority: entry.priority)
                }
            }
            .sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                return $0.misspelling.count > $1.misspelling.count
            }

        var corrected = text
        for rule in applicable where !rule.misspelling.isEmpty {
            corrected = replaceWholeTerm(
                rule.misspelling,
                with: rule.canonical,
                in: corrected
            )
        }
        return corrected
    }

    private func replaceWholeTerm(
        _ term: String,
        with replacement: String,
        in text: String
    ) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: term)
        guard let expression = try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}_])\(escaped)(?![\\p{L}\\p{N}_])",
            options: [.caseInsensitive]
        ) else {
            return text
        }

        let protectedRanges = protectedRanges(in: text)
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: fullRange).reversed()
        var result = text
        for match in matches where !protectedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private func protectedRanges(in text: String) -> [NSRange] {
        let patterns = [
            #"https?://[^\s]+"#,
            #"\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b"#,
            #"`[^`]+`"#,
            #"\b[\p{L}\p{N}]+_[\p{L}\p{N}_]+\b"#
        ]
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return patterns.flatMap { pattern in
            (try? NSRegularExpression(pattern: pattern))?
                .matches(in: text, range: fullRange)
                .map(\.range) ?? []
        }
    }
}
