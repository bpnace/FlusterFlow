import Foundation

struct ContextReferenceResolution: Equatable, Sendable {
    let text: String
    let usedContextTerms: [String]
}

enum ContextReferenceResolver {
    static func resolve(
        localText: String,
        proposedText: String,
        context: TextRewriteContext,
        targetFormat: TextRewriteTargetFormat
    ) -> ContextReferenceResolution {
        guard targetFormat == .message,
              context.availability == .available,
              let boundedText = context.boundedText,
              !boundedText.isEmpty else {
            return unchanged(proposedText)
        }

        for reference in references where reference.isPresent(in: localText) {
            let names = reference.uniqueNames(in: boundedText)
            guard names.count == 1, let name = names.first else { continue }
            if proposedText.range(
                of: name,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil {
                return ContextReferenceResolution(
                    text: proposedText,
                    usedContextTerms: [name]
                )
            }
            guard let resolved = reference.replacingReference(
                in: proposedText,
                with: name
            ) else {
                continue
            }
            return ContextReferenceResolution(
                text: resolved,
                usedContextTerms: [name]
            )
        }

        return unchanged(proposedText)
    }

    private static func unchanged(_ text: String) -> ContextReferenceResolution {
        ContextReferenceResolution(text: text, usedContextTerms: [])
    }

    private static let references = [
        Reference(
            localPatterns: [
                #"(?i)\b(?:das|dieses|dem|diesem|jenes)\s+projekt\b"#
            ],
            definitionPatterns: [
                #"\b(?i:(?:das\s+)?projekt\s+(?:heißt|heisst|ist|namens))\s+([A-ZÄÖÜ][\p{L}\p{M}\p{N}_-]*(?:\s+[A-ZÄÖÜ][\p{L}\p{M}\p{N}_-]*){0,2})"#,
                #"\b(?i:projekt)\s*:\s*([A-ZÄÖÜ][\p{L}\p{M}\p{N}_-]*(?:\s+[A-ZÄÖÜ][\p{L}\p{M}\p{N}_-]*){0,2})"#
            ],
            replacementPatterns: [
                #"(?i)\b(?:das|dieses|dem|diesem|jenes)\s+projekt\b"#,
                #"(?i)\bprojekt\b"#
            ]
        ),
        Reference(
            localPatterns: [
                #"(?i)\b(?:die|diese|der|dieser|jene)\s+aufgabe\b"#
            ],
            definitionPatterns: [
                #"\b(?i:(?:die\s+)?aufgabe\s+(?:heißt|heisst|ist|namens))\s+([A-ZÄÖÜ][\p{L}\p{M}\p{N}_-]*(?:\s+[A-ZÄÖÜ][\p{L}\p{M}\p{N}_-]*){0,2})"#,
                #"\b(?i:aufgabe)\s*:\s*([A-ZÄÖÜ][\p{L}\p{M}\p{N}_-]*(?:\s+[A-ZÄÖÜ][\p{L}\p{M}\p{N}_-]*){0,2})"#
            ],
            replacementPatterns: [
                #"(?i)\b(?:die|diese|der|dieser|jene)\s+aufgabe\b"#,
                #"(?i)\baufgabe\b"#
            ]
        )
    ]

    private struct Reference {
        let localPatterns: [String]
        let definitionPatterns: [String]
        let replacementPatterns: [String]

        func isPresent(in text: String) -> Bool {
            localPatterns.contains { pattern in
                text.range(of: pattern, options: .regularExpression) != nil
            }
        }

        func uniqueNames(in text: String) -> [String] {
            var seen: Set<String> = []
            var names: [String] = []
            let source = text as NSString
            for pattern in definitionPatterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                for match in regex.matches(
                    in: text,
                    range: NSRange(location: 0, length: source.length)
                ) where match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound {
                    let name = source.substring(with: match.range(at: 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let key = name.folding(
                        options: [.caseInsensitive, .diacriticInsensitive],
                        locale: nil
                    )
                    if !name.isEmpty, seen.insert(key).inserted {
                        names.append(name)
                    }
                }
            }
            return names
        }

        func replacingReference(in text: String, with name: String) -> String? {
            for pattern in replacementPatterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let source = text as NSString
                guard let match = regex.firstMatch(
                    in: text,
                    range: NSRange(location: 0, length: source.length)
                ) else {
                    continue
                }
                return source.replacingCharacters(in: match.range, with: name)
            }
            return nil
        }
    }
}
