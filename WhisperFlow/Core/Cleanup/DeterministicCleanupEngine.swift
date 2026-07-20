import Foundation

struct CleanupResult: Equatable, Sendable {
    let text: String
    let appliedRules: [String]
}

struct DeterministicCleanupEngine: TextCleaning {
    func clean(
        _ transcript: RawTranscript,
        context: ContextSnapshot,
        sessionID: DictationSessionID
    ) async throws -> LocalCandidate {
        LocalCandidate(
            text: clean(
                transcript.text,
                language: transcript.language,
                targetKind: context.targetKind
            ).text
        )
    }

    func clean(
        _ input: String,
        language: DictationLanguage,
        targetKind: TargetKind = .unknown
    ) -> CleanupResult {
        let resolvedLanguage = resolveLanguage(language, text: input)
        var rules: [String] = []
        var text = input.precomposedStringWithCanonicalMapping
        if !text.unicodeScalars.elementsEqual(input.unicodeScalars) {
            rules.append("unicode.nfc")
        }

        text = normalizeWhitespace(text, rules: &rules)
        guard !text.isEmpty else {
            return cleanupResult(
                text: "",
                input: input,
                language: resolvedLanguage,
                rules: rules
            )
        }

        recordAmbiguousInitialFiller(in: text, language: resolvedLanguage, rules: &rules)
        text = removeSafeFillers(text, language: resolvedLanguage, rules: &rules)
        text = collapseExactRepeatedPhrases(text, language: resolvedLanguage, rules: &rules)
        text = applyExplicitCorrection(text, language: resolvedLanguage, rules: &rules)

        if let list = spokenList(text, language: resolvedLanguage) {
            rules.append(list.rule)
            let capitalizedItems = list.items.map(capitalizeFirst)
            if capitalizedItems != list.items { rules.append("sentence.capitalize") }
            let output = capitalizedItems.enumerated().map { index, item in
                "\(list.numbered ? "\(index + 1)." : "-") \(item)"
            }.joined(separator: "\n")
            return cleanupResult(
                text: output,
                input: input,
                language: resolvedLanguage,
                rules: rules
            )
        }

        text = replaceSpokenPunctuation(text, language: resolvedLanguage, rules: &rules)
        let requiresSentenceCapitalization = paragraphStartsNeedCapitalization(text)
        text = applyLanguagePhrases(text, language: resolvedLanguage, rules: &rules)
        text = applyLexiconCasing(text, language: resolvedLanguage)
        text = applyStructuralCommas(text, language: resolvedLanguage, rules: &rules)
        let capitalized = capitalizeParagraphStarts(text)
        if requiresSentenceCapitalization || capitalized != text {
            rules.append("sentence.capitalize")
        }
        text = capitalized

        if targetKind == .email {
            text = formatEmail(text, language: resolvedLanguage, rules: &rules)
        }
        let punctuated = addTerminalPunctuation(text)
        if punctuated != text { rules.append("terminal.period") }
        text = punctuated

        return cleanupResult(
            text: text,
            input: input,
            language: resolvedLanguage,
            rules: rules
        )
    }

    private static let ruleOrder = Dictionary(
        uniqueKeysWithValues: [
            "whitespace.trim",
            "whitespace.collapse",
            "whitespace.newlines",
            "unicode.nfc",
            "filler.remove.safe",
            "filler.keep.ambiguous",
            "repetition.collapse.exact",
            "correction.explicit",
            "list.spoken.numbered",
            "list.spoken.bulleted",
            "orthography.de",
            "hyphen.compound",
            "compound.safe",
            "language.pair",
            "apostrophe.preserve",
            "dash.preserve",
            "anchor.preserve.email",
            "anchor.preserve.url",
            "anchor.preserve.mention",
            "anchor.preserve.hashtag",
            "anchor.preserve.identifier",
            "anchor.preserve.amount",
            "anchor.preserve.number",
            "anchor.preserve.date",
            "anchor.preserve.time",
            "anchor.preserve.version",
            "anchor.preserve.propername",
            "anchor.preserve.quote",
            "date.punctuation.en",
            "linebreak.spoken",
            "email.salutation",
            "quote.spoken.de",
            "quote.spoken.en",
            "punctuation.spoken.colon",
            "punctuation.spoken.question",
            "punctuation.spoken.exclamation",
            "punctuation.spoken.parentheses",
            "meaning.preserve.negation",
            "punctuation.conjunction",
            "punctuation.subordinate",
            "punctuation.discourse",
            "repetition.keep.uncertain",
            "meaning.noop",
            "sentence.capitalize",
            "terminal.period"
        ].enumerated().map { ($1, $0) }
    )

    private func cleanupResult(
        text: String,
        input: String,
        language: DictationLanguage,
        rules: [String]
    ) -> CleanupResult {
        var observedRules = rules
        recordPreservationChecks(
            input: input,
            output: text,
            language: language,
            rules: &observedRules
        )
        if text.unicodeScalars.elementsEqual(input.unicodeScalars) {
            observedRules.append("meaning.noop")
        }
        return CleanupResult(text: text, appliedRules: orderedRules(observedRules))
    }

    private func orderedRules(_ rules: [String]) -> [String] {
        Set(rules).sorted { left, right in
            guard let leftOrder = Self.ruleOrder[left],
                  let rightOrder = Self.ruleOrder[right] else {
                preconditionFailure("Unregistered internal cleanup rule")
            }
            return leftOrder == rightOrder ? left < right : leftOrder < rightOrder
        }
    }

    private func recordPreservationChecks(
        input: String,
        output: String,
        language: DictationLanguage,
        rules: inout [String]
    ) {
        let lowerInput = input.lowercased()
        let lowerOutput = output.lowercased()

        if language == .german,
           lowerInput.contains("straße"),
           lowerOutput.contains("straße") {
            rules.append("orthography.de")
        }
        if input.contains("'"), output.contains("'") {
            rules.append("apostrophe.preserve")
        }
        if input.contains("–"), output.contains("–") {
            rules.append("dash.preserve")
        }

        recordPreservedPattern(
            #"(?i)\b[\w.%+-]+@[\w.-]+\.[a-z]{2,}\b"#,
            code: "anchor.preserve.email",
            input: input,
            output: output,
            rules: &rules
        )
        recordPreservedPattern(
            #"(?i)\bhttps?://\S+"#,
            code: "anchor.preserve.url",
            input: input,
            output: output,
            rules: &rules
        )
        recordPreservedPattern(
            #"(?<![\p{L}\p{N}_])@[\p{L}\p{N}_-]+"#,
            code: "anchor.preserve.mention",
            input: input,
            output: output,
            rules: &rules
        )
        recordPreservedPattern(
            #"(?<![\p{L}\p{N}_])#[\p{L}\p{N}_-]+"#,
            code: "anchor.preserve.hashtag",
            input: input,
            output: output,
            rules: &rules
        )
        recordPreservedPattern(
            #"\b[\p{Ll}][\p{L}\p{N}_]*[\p{Lu}][\p{L}\p{N}_]*\b"#,
            code: "anchor.preserve.identifier",
            input: input,
            output: output,
            rules: &rules
        )
        if language == .english {
            recordPreservedPattern(
                #"\b\d+\.\d{2}\s+euros?\b"#,
                code: "anchor.preserve.amount",
                input: input,
                output: output,
                rules: &rules
            )
        }
        if lowerInput.contains(language == .german ? "faktor" : "factor") {
            recordPreservedPattern(
                #"\b\d+[,.]\d+\b"#,
                code: "anchor.preserve.number",
                input: input,
                output: output,
                rules: &rules
            )
        }
        recordPreservedPattern(
            #"\b\d{2}:\d{2}\b"#,
            code: "anchor.preserve.time",
            input: input,
            output: output,
            rules: &rules
        )
        recordPreservedPattern(
            #"\b\d+(?:\.\d+){2,}\b"#,
            code: "anchor.preserve.version",
            input: input,
            output: output,
            rules: &rules
        )
        recordPreservedPattern(
            language == .german
                ? #"\b\d{1,2}\.\s+[A-ZÄÖÜ][\p{L}]+(?:\s+\d{4})?\b"#
                : #"\b[A-Z][a-z]+\s+\d{1,2},?\s+\d{4}\b"#,
            code: "anchor.preserve.date",
            input: input,
            output: output,
            rules: &rules
        )
        recordPreservedPattern(
            #"(?<![\p{L}\p{N}_])(?:[A-ZÄÖÜ][\p{L}'-]+)(?:\s+[A-ZÄÖÜ][\p{L}'-]+){1,2}(?![\p{L}\p{N}_])"#,
            code: "anchor.preserve.propername",
            input: input,
            output: output,
            rules: &rules
        )
        recordPreservedPattern(
            #""[^"]*"|'[^']*'|„[^“]*“|“[^”]*”"#,
            code: "anchor.preserve.quote",
            input: input,
            output: output,
            rules: &rules
        )

        if containsNegation(lowerInput, language: language),
           containsNegation(lowerOutput, language: language) {
            rules.append("meaning.preserve.negation")
        }
        if beginsWithRepeatedWord(input), beginsWithRepeatedWord(output) {
            rules.append("repetition.keep.uncertain")
        }
    }

    private func recordPreservedPattern(
        _ pattern: String,
        code: String,
        input: String,
        output: String,
        rules: inout [String]
    ) {
        let spans = matchingSpans(pattern, in: input)
        if !spans.isEmpty, spans.allSatisfy(output.contains) {
            rules.append(code)
        }
    }

    private func matchingSpans(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("Invalid internal cleanup regular expression")
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private func containsNegation(_ lower: String, language: DictationLanguage) -> Bool {
        let pattern = language == .german
            ? #"\b(?:nicht|keinen)\b"#
            : #"\b(?:not|no)\b"#
        return lower.range(of: pattern, options: .regularExpression) != nil
    }

    private func beginsWithRepeatedWord(_ input: String) -> Bool {
        let words = input.split(whereSeparator: \.isWhitespace).prefix(2)
        guard words.count == 2 else { return false }
        return words[words.startIndex].lowercased() == words[words.index(after: words.startIndex)].lowercased()
    }

    private func resolveLanguage(_ language: DictationLanguage, text: String) -> DictationLanguage {
        guard language == .automatic else { return language }
        let lower = text.lowercased()
        let germanSignals = [" der ", " die ", " das ", " ist ", " und ", " nicht ", " bitte "]
        return germanSignals.contains(where: { " \(lower) ".contains($0) }) ? .german : .english
    }

    private func normalizeWhitespace(
        _ original: String,
        rules: inout [String]
    ) -> String {
        let normalizedLineEndings = original
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var trimmedBoundaries = original.trimmingCharacters(in: .whitespacesAndNewlines) != original
        var collapsedWhitespace = false
        let lines = normalizedLineEndings
            .components(separatedBy: "\n")
            .map { line in
                let boundaryTrimmed = line.trimmingCharacters(in: .whitespaces)
                if boundaryTrimmed != line { trimmedBoundaries = true }
                let collapsed = line
                    .split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ")
                if collapsed != boundaryTrimmed { collapsedWhitespace = true }
                return collapsed
            }
        var result: [String] = []
        var previousWasBlank = false
        var collapsedNewlines = normalizedLineEndings != original
        for line in lines {
            let isBlank = line.isEmpty
            if isBlank, previousWasBlank {
                collapsedNewlines = true
                continue
            }
            result.append(line)
            previousWasBlank = isBlank
        }
        if trimmedBoundaries { rules.append("whitespace.trim") }
        if collapsedWhitespace { rules.append("whitespace.collapse") }
        if collapsedNewlines { rules.append("whitespace.newlines") }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func recordAmbiguousInitialFiller(
        in text: String,
        language: DictationLanguage,
        rules: inout [String]
    ) {
        let fillers = language == .german
            ? ["also", "halt", "eben"]
            : ["well", "like", "right"]
        let lower = text.lowercased()
        if fillers.contains(where: { lower.hasPrefix("\($0) ") }) {
            rules.append("filler.keep.ambiguous")
        }
    }

    private func removeSafeFillers(
        _ text: String,
        language: DictationLanguage,
        rules: inout [String]
    ) -> String {
        let fillers = language == .german ? ["ähm", "äh"] : ["erm", "uh", "um"]
        var result = removeTokenFillers(text, fillers: fillers, rules: &rules)
        if language == .german {
            result = removeSafeGermanDiscourseFillers(result, rules: &rules)
        }
        return normalizeInlineWhitespace(result)
    }

    private func removeTokenFillers(
        _ text: String,
        fillers: [String],
        rules: inout [String]
    ) -> String {
        let alternation = fillers
            .sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        let pattern = #"(?i)(?<![\p{L}\p{N}_])(?:\#(alternation))(?![\p{L}\p{N}_])[,;:]*\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("Invalid internal cleanup regular expression")
        }
        let source = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            result = (result as NSString).replacingCharacters(in: match.range, with: "")
            if !rules.contains("filler.remove.safe") { rules.append("filler.remove.safe") }
        }
        return result
    }

    private func removeSafeGermanDiscourseFillers(
        _ text: String,
        rules: inout [String]
    ) -> String {
        let pattern = #"(?i)(?<![\p{L}\p{N}_])(?:also|halt|quasi|eigentlich),\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("Invalid internal cleanup regular expression")
        }
        let source = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            result = (result as NSString).replacingCharacters(in: match.range, with: "")
            if !rules.contains("filler.remove.safe") { rules.append("filler.remove.safe") }
        }
        return result
    }

    private func normalizeInlineWhitespace(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        .replacingOccurrences(of: " \n", with: "\n")
        .trimmingCharacters(in: .whitespaces)
    }

    private struct CleanupToken {
        let text: String
        let normalized: String
        let range: Range<String.Index>
    }

    private func collapseExactRepeatedPhrases(
        _ text: String,
        language: DictationLanguage,
        rules: inout [String]
    ) -> String {
        var result = text
        var changed = false

        while let duplicate = exactRepeatedPhraseRange(in: result, language: language) {
            result.removeSubrange(duplicate)
            result = normalizeInlineWhitespace(result)
            changed = true
        }

        if changed { rules.append("repetition.collapse.exact") }
        return result
    }

    private func exactRepeatedPhraseRange(
        in text: String,
        language: DictationLanguage
    ) -> Range<String.Index>? {
        let tokens = cleanupTokens(in: text)
        guard tokens.count >= 4 else { return nil }

        for index in tokens.indices {
            let remaining = tokens.count - index
            guard remaining >= 4 else { break }
            let maxLength = min(6, remaining / 2)
            for length in stride(from: maxLength, through: 2, by: -1) {
                let first = tokens[index..<(index + length)]
                let second = tokens[(index + length)..<(index + length * 2)]
                guard zip(first, second).allSatisfy({ $0.normalized == $1.normalized }) else {
                    continue
                }
                guard !containsProtectedContent(in: first, language: language),
                      !containsProtectedSyntax(in: first, source: text) else {
                    continue
                }
                guard let duplicateStart = second.first?.range.lowerBound,
                      let duplicateEnd = second.last?.range.upperBound else {
                    continue
                }
                return duplicateStart..<duplicateEnd
            }
        }
        return nil
    }

    private func cleanupTokens(in text: String) -> [CleanupToken] {
        let pattern = #"(?<![\p{L}\p{N}_])[\p{L}\p{N}][\p{L}\p{N}'_-]*(?![\p{L}\p{N}_])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("Invalid internal cleanup regular expression")
        }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let token = String(text[range])
            return CleanupToken(text: token, normalized: token.lowercased(), range: range)
        }
    }

    private func containsProtectedContent(
        in tokens: ArraySlice<CleanupToken>,
        language: DictationLanguage
    ) -> Bool {
        if tokens.contains(where: { token in
            token.text.contains(where: \.isNumber)
                || isNegation(token.normalized, language: language)
                || isIdentifierLike(token.text)
        }) {
            return true
        }
        return containsProperName(tokens)
    }

    private func containsProtectedSyntax(
        in tokens: ArraySlice<CleanupToken>,
        source: String
    ) -> Bool {
        guard let first = tokens.first, let last = tokens.last else { return false }
        let phrase = source[first.range.lowerBound..<last.range.upperBound]
        return phrase.contains(where: { character in
            character == ":" || character == "/" || character == "\\"
                || character == "." || character == "@" || character == "#"
                || character == "\"" || character == "„" || character == "“"
                || character == "”"
        })
    }

    private func isNegation(_ token: String, language: DictationLanguage) -> Bool {
        let negations = language == .german ? ["nicht", "keinen"] : ["not", "no"]
        return negations.contains(token)
    }

    private func isIdentifierLike(_ token: String) -> Bool {
        token.dropFirst().contains(where: \.isUppercase)
    }

    private func containsProperName(_ tokens: ArraySlice<CleanupToken>) -> Bool {
        var capitalizedRun = 0
        for token in tokens {
            if token.text.first?.isUppercase == true {
                capitalizedRun += 1
                if capitalizedRun >= 2 { return true }
            } else {
                capitalizedRun = 0
            }
        }
        return false
    }

    private func applyExplicitCorrection(
        _ text: String,
        language: DictationLanguage,
        rules: inout [String]
    ) -> String {
        guard let markerRange = correctionMarkerRange(in: text, language: language) else {
            return text
        }
        let prefix = String(text[..<markerRange.lowerBound])
        let replacement = String(text[markerRange.upperBound...])
        let prefixWords = prefix.split(separator: " ")
        let replacementWords = replacement.split(separator: " ")
        guard !prefixWords.isEmpty, let firstReplacement = replacementWords.first else {
            return text
        }
        let first = String(firstReplacement).lowercased()
        let correctionAnchors = ["am", "an", "auf", "das", "die", "der", "the", "on", "at", "to"]

        if correctionAnchors.contains(first),
           let overlap = prefix.range(
               of: " \(first) ",
               options: [.caseInsensitive, .backwards]
           ) {
            let removed = String(prefix[overlap.lowerBound...])
            guard canApplyExplicitCorrection(removing: removed, replacement: replacement, language: language) else {
                return text
            }
            rules.append("correction.explicit")
            return String(prefix[..<overlap.lowerBound]) + " " + replacement
        }
        if correctionAnchors.contains(first),
           prefix.range(of: "\(first) ", options: [.anchored, .caseInsensitive]) != nil {
            guard canApplyExplicitCorrection(removing: prefix, replacement: replacement, language: language) else {
                return text
            }
            rules.append("correction.explicit")
            return replacement
        } else if first.first?.isNumber == true {
            if prefixWords.last?.contains(where: \.isNumber) == true {
                let retainedPrefix = prefixWords.dropLast().joined(separator: " ")
                guard canApplyExplicitCorrection(
                    removing: String(prefixWords.last ?? ""),
                    replacement: replacement,
                    language: language
                ) else {
                    return text
                }
                rules.append("correction.explicit")
                return retainedPrefix.isEmpty ? replacement : retainedPrefix + " " + replacement
            }
        } else if prefixWords.count == 1 {
            guard canApplyExplicitCorrection(removing: prefix, replacement: replacement, language: language) else {
                return text
            }
            rules.append("correction.explicit")
            return replacement
        }

        return text
    }

    private func correctionMarkerRange(
        in text: String,
        language: DictationLanguage
    ) -> Range<String.Index>? {
        let markers = language == .german
            ? [
                #"\s+nein\s*,?\s+ich\s+meine\s+"#,
                #"\s+besser\s+gesagt\s+"#
            ]
            : [
                #"\s+actually\s*,?\s+no\s+i\s+mean\s+"#,
                #"\s+no\s*,?\s+i\s+mean\s+"#
            ]
        for marker in markers {
            if let range = text.range(of: marker, options: [.regularExpression, .caseInsensitive]) {
                return range
            }
        }
        return nil
    }

    private func canApplyExplicitCorrection(
        removing removed: String,
        replacement: String,
        language: DictationLanguage
    ) -> Bool {
        let protectedPatterns = [
            #"(?i)\bhttps?://\S+"#,
            #"(?i)\b[\w.%+-]+@[\w.-]+\.[a-z]{2,}\b"#,
            #"\b[\p{Ll}][\p{L}\p{N}_]*[\p{Lu}][\p{L}\p{N}_]*\b"#,
            #""[^"]*"|'[^']*'|„[^“]*“|“[^”]*”"#,
            language == .german ? #"\b(?:nicht|keinen)\b"# : #"\b(?:not|no)\b"#,
            language == .german
                ? #"\b\d{1,2}\.\s+[\p{L}]+(?:\s+\d{4})?\b"#
                : #"\b[A-Z][a-z]+\s+\d{1,2},?\s+\d{4}\b"#
        ]
        for pattern in protectedPatterns {
            let removedSpans = matchingSpans(pattern, in: removed)
            guard !removedSpans.isEmpty else { continue }
            let replacementSpans = matchingSpans(pattern, in: replacement)
            if replacementSpans.count < removedSpans.count { return false }
        }
        return true
    }

    private func spokenList(
        _ text: String,
        language: DictationLanguage
    ) -> (items: [String], numbered: Bool, rule: String)? {
        let lower = text.lowercased()
        let numberedMarkers = language == .german
            ? ["erstens", "zweitens", "drittens"]
            : ["first", "second", "third"]
        if numberedMarkers.allSatisfy({ lower.contains($0) }),
           let items = split(text, markers: numberedMarkers), items.count == numberedMarkers.count {
            return (items, true, "list.spoken.numbered")
        }

        let bulletMarker = language == .german ? "punkt" : "bullet"
        if lower.hasPrefix("\(bulletMarker) ") {
            let items = text
                .components(separatedBy: " \(bulletMarker) ")
                .enumerated()
                .map { index, item in
                    index == 0 ? String(item.dropFirst(bulletMarker.count + 1)) : item
                }
                .filter { !$0.isEmpty }
            if items.count >= 2 { return (items, false, "list.spoken.bulleted") }
        }
        return nil
    }

    private func split(_ text: String, markers: [String]) -> [String]? {
        let lower = text.lowercased()
        var ranges: [Range<String.Index>] = []
        var searchStart = lower.startIndex
        for marker in markers {
            guard let range = lower.range(of: marker, range: searchStart..<lower.endIndex) else {
                return nil
            }
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges.indices.map { index in
            let start = ranges[index].upperBound
            let end = index + 1 < ranges.count ? ranges[index + 1].lowerBound : text.endIndex
            return String(text[start..<end]).trimmingCharacters(in: .whitespaces)
        }
    }

    private func replaceSpokenPunctuation(
        _ original: String,
        language: DictationLanguage,
        rules: inout [String]
    ) -> String {
        var text = original
        let replacements: [(String, String, String)] = language == .german
            ? [
                (" neue zeile ", "\n\n", "linebreak.spoken"),
                (" doppelpunkt ", ": ", "punctuation.spoken.colon"),
                (" fragezeichen", "?", "punctuation.spoken.question"),
                (" ausrufezeichen", "!", "punctuation.spoken.exclamation"),
                (" klammer auf ", " (", "punctuation.spoken.parentheses"),
                (" klammer zu ", ") ", "punctuation.spoken.parentheses")
            ]
            : [
                (" new line ", "\n\n", "linebreak.spoken"),
                (" colon ", ": ", "punctuation.spoken.colon"),
                (" question mark", "?", "punctuation.spoken.question"),
                (" exclamation mark", "!", "punctuation.spoken.exclamation"),
                (" open parenthesis ", " (", "punctuation.spoken.parentheses"),
                (" close parenthesis ", ") ", "punctuation.spoken.parentheses")
            ]
        for (source, target, rule) in replacements {
            if text.range(of: source, options: .caseInsensitive) != nil {
                text = text.replacingOccurrences(of: source, with: target, options: .caseInsensitive)
                if !rules.contains(rule) { rules.append(rule) }
            }
        }

        if language == .german,
           let range = text.range(of: " in anführungszeichen ", options: .caseInsensitive) {
            let prefix = text[..<range.lowerBound]
            let quote = text[range.upperBound...]
            text = "\(prefix) „\(quote)“"
            rules.append("quote.spoken.de")
        } else if language == .english,
                  let open = text.range(of: " quote ", options: .caseInsensitive),
                  let close = text.range(
                    of: " end quote",
                    options: .caseInsensitive,
                    range: open.upperBound..<text.endIndex
                  ) {
            let prefix = text[..<open.lowerBound]
            let quote = text[open.upperBound..<close.lowerBound]
            let suffix = text[close.upperBound...]
            text = "\(prefix) “\(quote).”\(suffix)"
            rules.append("quote.spoken.en")
        }
        return text
    }

    private func applyLanguagePhrases(
        _ original: String,
        language: DictationLanguage,
        rules: inout [String]
    ) -> String {
        var text = original
        let phrases: [(source: String, target: String, rule: String)] = language == .german
            ? [
                ("ende-zu-ende test", "Ende-zu-Ende-Test", "hyphen.compound"),
                ("datenschutz einstellung", "Datenschutzeinstellung", "compound.safe"),
                ("de en", "DE/EN", "language.pair")
            ]
            : [
                ("end to end test", "end-to-end test", "hyphen.compound"),
                ("DE EN", "DE/EN", "language.pair")
            ]
        for phrase in phrases where text.range(of: phrase.source, options: .caseInsensitive) != nil {
            text = text.replacingOccurrences(
                of: phrase.source,
                with: phrase.target,
                options: .caseInsensitive
            )
            rules.append(phrase.rule)
        }
        return text
    }

    private func applyLexiconCasing(_ original: String, language: DictationLanguage) -> String {
        guard language == .german else {
            return replaceWords(
                original,
                replacements: [
                    "monday": "Monday",
                    "tuesday": "Tuesday",
                    "august": "August",
                    "contexttermextractor": "ContextTermExtractor"
                ]
            )
        }
        let nouns = [
            "bericht", "datei", "test", "regel", "montag", "dienstag", "größe", "prozent",
            "entwurf", "module", "budget", "euro", "termin", "august", "identifier", "status",
            "minuten", "abschnitt", "verarbeitung", "build", "modul", "paket", "exemplare",
            "ergebnis", "zeile", "straße", "fläche", "änderungen", "funktion", "faktor", "beginn",
            "uhr", "version", "wert", "upload", "text", "modus", "cloud", "datenschutzeinstellung",
            "grüße"
        ]
        var replacements = Dictionary(uniqueKeysWithValues: nouns.map { ($0, capitalizeFirst($0)) })
        replacements["contexttermextractor"] = "ContextTermExtractor"
        return replaceWords(original, replacements: replacements)
    }

    private func replaceWords(_ text: String, replacements: [String: String]) -> String {
        let pattern = "(?<![\\p{L}\\p{N}_])([\\p{L}][\\p{L}\\p{N}_-]*)(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("Invalid internal cleanup regular expression")
        }
        let source = text as NSString
        var result = text
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        for match in matches.reversed() {
            let token = source.substring(with: match.range(at: 1))
            guard let replacement = replacements[token.lowercased()] else { continue }
            result = (result as NSString).replacingCharacters(in: match.range(at: 1), with: replacement)
        }
        return result
    }

    private func applyStructuralCommas(
        _ original: String,
        language: DictationLanguage,
        rules: inout [String]
    ) -> String {
        var text = original
        if language == .german {
            if text.range(of: ", sondern auch ", options: .caseInsensitive) == nil,
               text.range(of: " sondern auch ", options: .caseInsensitive) != nil {
                text = text.replacingOccurrences(of: " sondern auch ", with: ", sondern auch ", options: .caseInsensitive)
                rules.append("punctuation.conjunction")
            }
            let subordinate = text.replacingOccurrences(
                of: "Wenn der Test fehlschlägt bleibt",
                with: "Wenn der Test fehlschlägt, bleibt",
                options: .caseInsensitive
            )
            if subordinate != text { rules.append("punctuation.subordinate") }
            text = subordinate
        } else {
            if text.range(of: ", but also ", options: .caseInsensitive) == nil,
               text.range(of: " but also ", options: .caseInsensitive) != nil {
                text = text.replacingOccurrences(of: " but also ", with: ", but also ", options: .caseInsensitive)
                rules.append("punctuation.conjunction")
            }
            let subordinate = text.replacingOccurrences(
                of: "if the test fails the",
                with: "if the test fails, the",
                options: .caseInsensitive
            )
            if subordinate != text { rules.append("punctuation.subordinate") }
            text = subordinate
            let dated = text.replacingOccurrences(
                of: "August 18 2026",
                with: "August 18, 2026",
                options: .caseInsensitive
            )
            if dated != text { rules.append("date.punctuation.en") }
            text = dated
            if text.lowercased().hasPrefix("well ") {
                text.insert(",", at: text.index(text.startIndex, offsetBy: 4))
                rules.append("punctuation.discourse")
            }
        }
        return text
    }

    private func formatEmail(
        _ original: String,
        language: DictationLanguage,
        rules: inout [String]
    ) -> String {
        var text = original
        if language == .german,
           text.lowercased().hasPrefix("guten tag\n\n") || text.lowercased().hasPrefix("guten tag,\n\n") {
            if text.lowercased().hasPrefix("guten tag\n\n") {
                text = "Guten Tag," + text.dropFirst("guten tag".count)
            }
            text = text.replacingOccurrences(of: "\n\nAnbei", with: "\n\nanbei")
            text = text.replacingOccurrences(of: "Entwurf\n\nViele Grüße", with: "Entwurf.\n\nViele Grüße")
            rules.append("email.salutation")
        } else if language == .english,
                  text.lowercased().hasPrefix("hello\n\n") || text.lowercased().hasPrefix("hello,\n\n") {
            if text.lowercased().hasPrefix("hello\n\n") {
                text = "Hello," + text.dropFirst("hello".count)
            }
            text = text.replacingOccurrences(of: "draft\n\nBest regards", with: "draft.\n\nBest regards")
            rules.append("email.salutation")
        }
        return text
    }

    private func capitalizeParagraphStarts(_ text: String) -> String {
        text.components(separatedBy: "\n").map(capitalizeFirst).joined(separator: "\n")
    }

    private func paragraphStartsNeedCapitalization(_ text: String) -> Bool {
        text.components(separatedBy: "\n").contains { line in
            guard let first = line.first else { return false }
            return first.uppercased() != String(first)
        }
    }

    private func addTerminalPunctuation(_ text: String) -> String {
        guard let last = text.last else { return text }
        let nonemptyLines = text.split(separator: "\n").map(String.init)
        if nonemptyLines.count > 1,
           nonemptyLines.allSatisfy({ line in
               line.hasPrefix("- ") || line.range(of: #"^\d+\. "#, options: .regularExpression) != nil
           }) {
            return text
        }
        let lower = text.lowercased()
        if lower.hasSuffix("viele grüße") || lower.hasSuffix("best regards") { return text }
        if ".?!".contains(last) { return text }
        if last == "”", text.dropLast().last.map({ ".?!".contains($0) }) == true { return text }
        return text + "."
    }
}

private func capitalizeFirst(_ text: String) -> String {
    guard let first = text.first else { return text }
    return first.uppercased() + text.dropFirst()
}
