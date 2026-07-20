import Foundation

protocol ModelDerivedArtifactMaterializing: Sendable {
    func materialize(_ artifact: ModelDerivedArtifact, in directory: URL) throws
}

struct DefaultModelDerivedArtifactMaterializer: ModelDerivedArtifactMaterializing {
    func materialize(_ artifact: ModelDerivedArtifact, in directory: URL) throws {
        switch artifact.kind {
        case .qwenTokenizerJSONV1:
            try QwenTokenizerArtifactGenerator.generate(in: directory)
        }
    }
}

enum QwenTokenizerArtifactGenerator {
    static func generate(in modelDirectory: URL) throws {
        let outputURL = modelDirectory.appendingPathComponent("tokenizer.json")
        let vocabURL = modelDirectory.appendingPathComponent("vocab.json")
        let mergesURL = modelDirectory.appendingPathComponent("merges.txt")
        let tokenizerConfigURL = modelDirectory.appendingPathComponent(
            "tokenizer_config.json"
        )

        let vocabData = try Data(contentsOf: vocabURL)
        let mergesText = try String(contentsOf: mergesURL, encoding: .utf8)
        let mergesJSON = mergesText
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { line in
                let escaped = line
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\""
            }
            .joined(separator: ",")

        let addedTokensJSON = try addedTokensJSON(from: tokenizerConfigURL)
        let pattern = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+"
        let escapedPattern = pattern
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let vocabJSON = String(data: vocabData, encoding: .utf8) ?? "{}"

        let tokenizerJSON = """
        {
          "version": "1.0",
          "truncation": null,
          "padding": null,
          "added_tokens": \(addedTokensJSON),
          "normalizer": {"type": "NFC"},
          "pre_tokenizer": {
            "type": "Sequence",
            "pretokenizers": [
              {
                "type": "Split",
                "pattern": {"Regex": "\(escapedPattern)"},
                "behavior": "Isolated",
                "invert": false
              },
              {
                "type": "ByteLevel",
                "add_prefix_space": false,
                "trim_offsets": true,
                "use_regex": false
              }
            ]
          },
          "post_processor": null,
          "decoder": {
            "type": "ByteLevel",
            "add_prefix_space": true,
            "trim_offsets": true,
            "use_regex": true
          },
          "model": {
            "type": "BPE",
            "dropout": null,
            "unk_token": null,
            "continuing_subword_prefix": "",
            "end_of_word_suffix": "",
            "fuse_unk": false,
            "byte_fallback": false,
            "vocab": \(vocabJSON),
            "merges": [\(mergesJSON)]
          }
        }
        """

        try tokenizerJSON.write(
            to: outputURL,
            atomically: true,
            encoding: .utf8
        )
    }

    private static func addedTokensJSON(from configURL: URL) throws -> String {
        let data = try Data(contentsOf: configURL)
        guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let decoder = config["added_tokens_decoder"] as? [String: Any] else {
            return "[]"
        }

        let tokens: [[String: Any]] = decoder.compactMap { idString, value in
            guard let id = Int(idString),
                  let token = value as? [String: Any] else { return nil }
            return [
                "id": id,
                "content": token["content"] ?? "",
                "single_word": token["single_word"] ?? false,
                "lstrip": token["lstrip"] ?? false,
                "rstrip": token["rstrip"] ?? false,
                "normalized": token["normalized"] ?? false,
                "special": token["special"] ?? false
            ]
        }.sorted {
            ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0)
        }
        let tokenData = try JSONSerialization.data(
            withJSONObject: tokens,
            options: [.sortedKeys]
        )
        return String(data: tokenData, encoding: .utf8) ?? "[]"
    }
}
