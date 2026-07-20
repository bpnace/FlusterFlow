import Foundation

enum FinalTextSanitizationAction: String, Equatable, Sendable {
    case trimOuterWhitespace
    case unwrapMarkdownFence
    case unwrapJSONEnvelope
    case stripMarkdownWrapper
    case normalizeLineEndings
    case normalizeHorizontalWhitespace
    case removeSpaceBeforePunctuation
    case collapseBlankLines
    case collapseDuplicatePunctuation
}

struct SanitizedText: Equatable, Sendable {
    let text: String
    let actions: [FinalTextSanitizationAction]

    init(
        text: String,
        actions: [FinalTextSanitizationAction] = []
    ) {
        self.text = text
        self.actions = actions
    }

    var actionCount: Int { actions.count }
}

struct FinalTextSanitizer: Sendable {
    static func sanitize(_ rawText: String) -> SanitizedText {
        Self().sanitize(rawText)
    }

    func sanitize(_ rawText: String) -> SanitizedText {
        var text = rawText
        var actions: [FinalTextSanitizationAction] = []

        apply(.trimOuterWhitespace, to: &text, actions: &actions) {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        apply(.unwrapMarkdownFence, to: &text, actions: &actions, transform: unwrapMarkdownFence)
        apply(.unwrapJSONEnvelope, to: &text, actions: &actions, transform: unwrapJSONTextEnvelope)
        apply(.unwrapMarkdownFence, to: &text, actions: &actions, transform: unwrapMarkdownFence)
        apply(.stripMarkdownWrapper, to: &text, actions: &actions, transform: stripMarkdownWrapper)
        apply(.normalizeLineEndings, to: &text, actions: &actions, transform: normalizeLineEndings)
        apply(
            .normalizeHorizontalWhitespace,
            to: &text,
            actions: &actions,
            transform: normalizeHorizontalWhitespace
        )
        apply(
            .removeSpaceBeforePunctuation,
            to: &text,
            actions: &actions,
            transform: removeSpaceBeforePunctuation
        )
        apply(.collapseBlankLines, to: &text, actions: &actions, transform: collapseBlankLines)
        apply(
            .collapseDuplicatePunctuation,
            to: &text,
            actions: &actions,
            transform: collapseDuplicateSentencePunctuation
        )
        apply(.trimOuterWhitespace, to: &text, actions: &actions) {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return SanitizedText(text: text, actions: actions)
    }

    private func apply(
        _ action: FinalTextSanitizationAction,
        to text: inout String,
        actions: inout [FinalTextSanitizationAction],
        transform: (String) -> String
    ) {
        let transformed = transform(text)
        guard transformed != text else { return }
        text = transformed
        if !actions.contains(action) {
            actions.append(action)
        }
    }

    private func unwrapJSONTextEnvelope(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              dictionary.count == 1,
              let value = dictionary["text"] as? String else {
            return text
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func unwrapMarkdownFence(_ text: String) -> String {
        let pattern = #"(?s)^```(?:json|markdown|md|text)?\s*(.*?)\s*```$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(location: 0, length: (text as NSString).length)
              ),
              match.numberOfRanges == 2 else {
            return text
        }
        return (text as NSString).substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripMarkdownWrapper(_ text: String) -> String {
        var result = text
        for marker in ["**", "__"] {
            if result.hasPrefix(marker), result.hasSuffix(marker), result.count > marker.count * 2 {
                result.removeFirst(marker.count)
                result.removeLast(marker.count)
            }
        }
        return result
    }

    private func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private func normalizeHorizontalWhitespace(_ text: String) -> String {
        let pattern = #"[\t\p{Zs}]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return text.components(separatedBy: "\n").map { line in
            regex.stringByReplacingMatches(
                in: line,
                range: NSRange(location: 0, length: (line as NSString).length),
                withTemplate: " "
            ).trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    private func removeSpaceBeforePunctuation(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"[\t\p{Zs}]+([,.;:!?])"#) else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: "$1"
        )
    }

    private func collapseBlankLines(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\n{3,}"#) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: "\n\n"
        )
    }

    private func collapseDuplicateSentencePunctuation(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"([.!?])\1+"#) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: "$1"
        )
    }
}
