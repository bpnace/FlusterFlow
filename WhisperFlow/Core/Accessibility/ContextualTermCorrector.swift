import Foundation

struct ContextualTermCorrector: Sendable {
    func correct(_ transcript: String, terms: [String]) -> String {
        let candidates = uniqueCandidates(terms)
        guard !candidates.isEmpty else { return transcript }

        let tokens = wordTokens(in: transcript)
        guard !tokens.isEmpty else { return transcript }

        var replacements: [(range: NSRange, term: String)] = []
        var index = 0
        while index < tokens.count {
            var selected: (end: Int, range: NSRange, term: String)?
            for count in stride(from: min(3, tokens.count - index), through: 1, by: -1) {
                let end = index + count - 1
                let spanRange = NSRange(
                    location: tokens[index].location,
                    length: NSMaxRange(tokens[end]) - tokens[index].location
                )
                let spoken = (transcript as NSString).substring(with: spanRange)
                guard let term = unambiguousMatch(
                    for: spoken,
                    tokenCount: count,
                    candidates: candidates
                ) else { continue }
                selected = (end, spanRange, term)
                break
            }

            if let selected {
                let current = (transcript as NSString).substring(with: selected.range)
                if current != selected.term {
                    replacements.append((selected.range, selected.term))
                }
                index = selected.end + 1
            } else {
                index += 1
            }
        }

        var result = transcript
        for replacement in replacements.reversed() {
            result = (result as NSString).replacingCharacters(
                in: replacement.range,
                with: replacement.term
            )
        }
        return result
    }

    private func uniqueCandidates(_ terms: [String]) -> [(term: String, normalized: String)] {
        var seen: Set<String> = []
        return terms.prefix(ContextTermExtractor.maximumTerms).compactMap { term in
            let normalized = normalize(term)
            guard normalized.count >= 4, seen.insert(normalized).inserted else { return nil }
            return (term, normalized)
        }
    }

    private func wordTokens(in text: String) -> [NSRange] {
        let pattern = #"[\p{L}\p{N}]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length)
        ).map(\.range)
    }

    private func unambiguousMatch(
        for spoken: String,
        tokenCount: Int,
        candidates: [(term: String, normalized: String)]
    ) -> String? {
        let normalized = normalize(spoken)
        guard normalized.count >= 4 else { return nil }
        let threshold = normalized.count >= 8 ? 2 : 1
        let spokenPhonetic = phoneticKey(normalized)
        let nearby = candidates.filter {
            if tokenCount > 1 {
                let spokenTokens = spoken
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .map { normalize(String($0)) }
                if spokenTokens.contains($0.normalized) { return false }
                guard candidateComponentCount($0.term) == tokenCount else { return false }
            }
            let editNearby = abs($0.normalized.count - normalized.count) <= threshold
                && editDistance(normalized, $0.normalized, limit: threshold) <= threshold
            let candidatePhonetic = phoneticKey($0.normalized)
            let phoneticNearby = normalized.count >= 6
                && spokenPhonetic.count >= 5
                && spokenPhonetic == candidatePhonetic
            return editNearby || phoneticNearby
        }
        return nearby.count == 1 ? nearby[0].term : nil
    }

    private func candidateComponentCount(_ term: String) -> Int {
        let spaced = term.replacingOccurrences(
            of: #"(?<=[\p{Ll}\p{N}])(?=\p{Lu})"#,
            with: " ",
            options: .regularExpression
        )
        return max(1, spaced.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count)
    }

    private func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard abs(left.count - right.count) <= limit else { return limit + 1 }
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: right.count)
            for (rightIndex, rightCharacter) in right.enumerated() {
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            if current.min() ?? 0 > limit { return limit + 1 }
            previous = current
        }
        return previous[right.count]
    }

    private func phoneticKey(_ normalized: String) -> String {
        var value = normalized
        for (source, replacement) in [
            ("sch", "s"), ("ph", "f"), ("th", "t"), ("ck", "k"),
            ("qu", "k"), ("x", "ks"), ("z", "s"), ("c", "k")
        ] {
            value = value.replacingOccurrences(of: source, with: replacement)
        }
        var result = ""
        for character in value where result.last != character {
            result.append(character)
        }
        return result
    }
}
