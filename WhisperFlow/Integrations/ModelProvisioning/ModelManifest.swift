import Foundation

struct ModelSHA256: Codable, Equatable, Sendable {
    let rawValue: String

    init?(_ rawValue: String) {
        let normalized = rawValue.lowercased()
        guard normalized.count == 64,
              normalized.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        self.rawValue = normalized
    }
}

struct ModelArtifact: Codable, Equatable, Sendable {
    let relativePath: String
    let byteCount: Int64
    let sha256: ModelSHA256
}

enum ModelDerivedArtifactKind: String, Codable, Equatable, Sendable {
    case qwenTokenizerJSONV1
}

struct ModelDerivedArtifact: Codable, Equatable, Sendable {
    let artifact: ModelArtifact
    let kind: ModelDerivedArtifactKind
}

struct ModelManifest: Codable, Equatable, Sendable {
    let identifier: String
    let runtimeName: String
    let runtimeVersion: String
    let runtimeRevision: String
    let runtimeDirectoryName: String
    let repository: String
    let modelRevision: String
    let sourcePathPrefix: String?
    let precision: String
    let license: String
    let expectedByteCount: Int64
    let treeSHA256: ModelSHA256
    let requiredTopLevelPaths: [String]
    let artifacts: [ModelArtifact]
    let derivedArtifacts: [ModelDerivedArtifact]

    init(
        identifier: String,
        runtimeName: String,
        runtimeVersion: String,
        runtimeRevision: String,
        runtimeDirectoryName: String? = nil,
        repository: String,
        modelRevision: String,
        sourcePathPrefix: String? = nil,
        precision: String,
        license: String,
        expectedByteCount: Int64,
        treeSHA256: ModelSHA256,
        requiredTopLevelPaths: [String],
        artifacts: [ModelArtifact] = [],
        derivedArtifacts: [ModelDerivedArtifact] = []
    ) {
        self.identifier = identifier
        self.runtimeName = runtimeName
        self.runtimeVersion = runtimeVersion
        self.runtimeRevision = runtimeRevision
        self.runtimeDirectoryName = runtimeDirectoryName ?? identifier
        self.repository = repository
        self.modelRevision = modelRevision
        self.sourcePathPrefix = sourcePathPrefix
        self.precision = precision
        self.license = license
        self.expectedByteCount = expectedByteCount
        self.treeSHA256 = treeSHA256
        self.requiredTopLevelPaths = requiredTopLevelPaths
        self.artifacts = artifacts
        self.derivedArtifacts = derivedArtifacts
    }

    var allArtifacts: [ModelArtifact] {
        artifacts + derivedArtifacts.map(\.artifact)
    }

    static let parakeetV3Int8 = ModelManifest(
        identifier: "parakeet-tdt-0.6b-v3-coreml-int8",
        runtimeName: "FluidAudio",
        runtimeVersion: "0.15.5",
        runtimeRevision: "19600a485baa4998812e4654b70d2bab8f2c9949",
        runtimeDirectoryName: "parakeet-tdt-0.6b-v3",
        repository: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        modelRevision: "aed02740059203c4a87495924f685de3722ae9ce",
        precision: "int8",
        license: "CC-BY-4.0",
        expectedByteCount: 483_105_645,
        treeSHA256: ModelSHA256(
            "5295efba3d7f2fc7ba2ffd883ca0c3326eef33425bf6e029a69dd8ac0c58a79d"
        )!,
        requiredTopLevelPaths: [
            "Decoder.mlmodelc",
            "Encoder.mlmodelc",
            "JointDecisionv3.mlmodelc",
            "Preprocessor.mlmodelc",
            "parakeet_vocab.json"
        ],
        artifacts: [
            artifact("Decoder.mlmodelc/analytics/coremldata.bin", 243, "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
            artifact("Decoder.mlmodelc/coremldata.bin", 554, "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
            artifact("Decoder.mlmodelc/metadata.json", 3_427, "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9"),
            artifact("Decoder.mlmodelc/model.mil", 13_110, "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"),
            artifact("Decoder.mlmodelc/weights/weight.bin", 23_604_992, "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
            artifact("Encoder.mlmodelc/analytics/coremldata.bin", 243, "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
            artifact("Encoder.mlmodelc/coremldata.bin", 485, "d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86"),
            artifact("Encoder.mlmodelc/metadata.json", 2_921, "da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9"),
            artifact("Encoder.mlmodelc/model.mil", 959_769, "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
            artifact("Encoder.mlmodelc/weights/weight.bin", 445_187_200, "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421"),
            artifact("JointDecisionv3.mlmodelc/analytics/coremldata.bin", 243, "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
            artifact("JointDecisionv3.mlmodelc/coremldata.bin", 521, "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
            artifact("JointDecisionv3.mlmodelc/metadata.json", 3_453, "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f"),
            artifact("JointDecisionv3.mlmodelc/model.mil", 11_775, "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"),
            artifact("JointDecisionv3.mlmodelc/weights/weight.bin", 12_642_764, "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
            artifact("Preprocessor.mlmodelc/analytics/coremldata.bin", 243, "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
            artifact("Preprocessor.mlmodelc/coremldata.bin", 486, "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
            artifact("Preprocessor.mlmodelc/metadata.json", 2_841, "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
            artifact("Preprocessor.mlmodelc/model.mil", 28_181, "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
            artifact("Preprocessor.mlmodelc/weights/weight.bin", 491_072, "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
            artifact("parakeet_vocab.json", 151_122, "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735")
        ]
    )

    static let qwen3ASR06B8Bit = ModelManifest(
        identifier: "qwen3-asr-0.6b-8bit",
        runtimeName: "MLXAudioSTT",
        runtimeVersion: "0.1.3",
        runtimeRevision: "d302a5c6080d2bb97bae38c7418f82abb76013b6",
        runtimeDirectoryName: "qwen3-asr-0.6b-8bit",
        repository: "mlx-community/Qwen3-ASR-0.6B-8bit",
        modelRevision: "89e96d92ba34aca20b3e29fb10cc284097d1219f",
        precision: "8-bit MLX",
        license: "Apache-2.0",
        expectedByteCount: 1_015_531_573,
        treeSHA256: ModelSHA256(
            "b6695aef111b3eb009887f39d4c373dd147b7799b01d27e9051106faffc911a3"
        )!,
        requiredTopLevelPaths: [
            "config.json",
            "model.safetensors",
            "tokenizer.json",
            "tokenizer_config.json"
        ],
        artifacts: [
            artifact("chat_template.json", 1_161, "75a8cfca24f00de72d796fbfed6858fc9614ef3dabd8696684cc3bc03a9c58ff"),
            artifact("config.json", 7_187, "5d104a945fed08728ab010f12bf3ce5ab4d0794bba276d81bff5bd83ae9d2be0"),
            artifact("generation_config.json", 142, "1da527824d81e07118facff437e03f2e24a23311e3bdeb2368973fe77e5f275c"),
            artifact("merges.txt", 1_671_853, "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
            artifact("model.safetensors", 1_006_229_426, "b5bfe4abc1b4c6e58b633096682ec2b6297298add1527119936107d211adf0e8"),
            artifact("model.safetensors.index.json", 71_815, "caa32ece76c395ba241533eb4aceb0efbc72488ef3d8d2fd3c677ce068dad57d"),
            artifact("preprocessor_config.json", 330, "45e120a4eda2c20c5d7f2ea9354e63536bf35e27aa573fb7cdf78017b378770d"),
            artifact("tokenizer_config.json", 12_487, "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
            artifact("vocab.json", 2_776_833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910")
        ],
        derivedArtifacts: [
            ModelDerivedArtifact(
                artifact: artifact(
                    "tokenizer.json",
                    4_760_339,
                    "1c98aeb375d2cb5b386bad460bc2a87bf39b9debbda44d49115377d1de8cb2ed"
                ),
                kind: .qwenTokenizerJSONV1
            )
        ]
    )

    static let whisperLargeV3 = ModelManifest(
        identifier: "openai-whisper-large-v3-v20240930-626mb",
        runtimeName: "WhisperKit",
        runtimeVersion: "1.0.0",
        runtimeRevision: "25c62997041c134b03ca82731ce2f6fd2cae1eb9",
        runtimeDirectoryName: "whisper-large-v3-v20240930-626mb",
        repository: "argmaxinc/whisperkit-coreml",
        modelRevision: "97a5bf9bbc74c7d9c12c755d04dea59e672e3808",
        sourcePathPrefix: "openai_whisper-large-v3-v20240930_626MB",
        precision: "mixed Core ML",
        license: "upstream Apache-2.0; conversion unspecified",
        expectedByteCount: 626_718_238,
        treeSHA256: ModelSHA256(
            "13d1ce901ca6bb5084a2a48db1d1a0c4fbd13687ce78f845fa89c8016e677287"
        )!,
        requiredTopLevelPaths: [
            "AudioEncoder.mlmodelc",
            "MelSpectrogram.mlmodelc",
            "TextDecoder.mlmodelc",
            "config.json",
            "generation_config.json"
        ],
        artifacts: [
            artifact("AudioEncoder.mlmodelc/analytics/coremldata.bin", 243, "56793886ab1adb9ca8a4e335efbe8af6640f40d958ab2d29c3ad2d7d6f712e95"),
            artifact("AudioEncoder.mlmodelc/coremldata.bin", 348, "ffa9eb76e8e9d9be75a4d527e5249e61d67fd43081c5aa110fd24efa6c8c5ea3"),
            artifact("AudioEncoder.mlmodelc/metadata.json", 1_922, "a87a3375afe79e88e27af30247e234e706b98679dedfd1b021a74f7ee108c669"),
            artifact("AudioEncoder.mlmodelc/model.mil", 934_263, "3cec2580fb07b12a88087f0e1586c6ba2982980eb36499561e1ffca2b0950442"),
            artifact("AudioEncoder.mlmodelc/weights/weight.bin", 421_968_768, "e4740fa28ed65907af754af893dfce98473fafb84dd8d718ad346985fe7678c1"),
            artifact("MelSpectrogram.mlmodelc/analytics/coremldata.bin", 243, "c5be419f8622083ac7046306400643539f0e7577c843448c36defc090d41e7ce"),
            artifact("MelSpectrogram.mlmodelc/coremldata.bin", 329, "2bfc12cffc2e45e039c7a18f384f09adffb72c182fcd93f9413d405d1a6c1130"),
            artifact("MelSpectrogram.mlmodelc/metadata.json", 1_850, "2bc552e09a6f124d9e6c178dd1a6979e010206acb26308b2224887c9dcbeb35f"),
            artifact("MelSpectrogram.mlmodelc/model.mil", 10_143, "c270b95b5f81d7f7d0b8a3e8f991d4e5812a37cad29349868a35b91f3a6a4463"),
            artifact("MelSpectrogram.mlmodelc/weights/weight.bin", 373_376, "009d9fb8f6b589accfa08cebf1c712ef07c3405229ce3cfb3a57ee033c9d8a49"),
            artifact("TextDecoder.mlmodelc/analytics/coremldata.bin", 243, "3913b8c9716b284a917cf3744f4d415f2a05e2b910594a14c6cc10092284d3f8"),
            artifact("TextDecoder.mlmodelc/coremldata.bin", 633, "3faabaf66930e66956d8291d0ff485fb382496e30a91a7185548b9b898ce90a9"),
            artifact("TextDecoder.mlmodelc/metadata.json", 4_924, "994f6030d7b1a8be999940444c3cf5d6a57d40ddd4423cf1d1fc93520aa1b052"),
            artifact("TextDecoder.mlmodelc/model.mil", 217_177, "dbe833be9e64348c95b7fa598d0ae4309a91aedce4e82fa500a714b0e4b5d754"),
            artifact("TextDecoder.mlmodelc/weights/weight.bin", 203_199_860, "d69700903d518ada33170ab77faaaf464496fb9ff65752c6d5a6109aa2fb02db"),
            artifact("config.json", 1_149, "f01d83dd891791d6f12421c05d3ed8ebbe70866f10d6c9a7a7e80b558ce5a0f1"),
            artifact("generation_config.json", 2_767, "7fbb053a023be11fbeccd8421811610308143daa93d9617c52aab4a0fa1491c6")
        ]
    )

    static let whisperLargeV3Turbo = ModelManifest(
        identifier: "openai-whisper-large-v3-v20240930-turbo-632mb",
        runtimeName: "WhisperKit",
        runtimeVersion: "1.0.0",
        runtimeRevision: "25c62997041c134b03ca82731ce2f6fd2cae1eb9",
        runtimeDirectoryName: "whisper-large-v3-v20240930-turbo-632mb",
        repository: "argmaxinc/whisperkit-coreml",
        modelRevision: "97a5bf9bbc74c7d9c12c755d04dea59e672e3808",
        sourcePathPrefix: "openai_whisper-large-v3-v20240930_turbo_632MB",
        precision: "mixed Core ML",
        license: "upstream Apache-2.0; conversion unspecified",
        expectedByteCount: 645_668_913,
        treeSHA256: ModelSHA256(
            "20106c1584f2c63c6ee8f51fabd562fe85b29e2116ae6facbf7ca826c1f21c05"
        )!,
        requiredTopLevelPaths: [
            "AudioEncoder.mlmodelc",
            "MelSpectrogram.mlmodelc",
            "TextDecoder.mlmodelc",
            "TextDecoderContextPrefill.mlmodelc",
            "config.json",
            "generation_config.json"
        ],
        artifacts: [
            artifact("AudioEncoder.mlmodelc/analytics/coremldata.bin", 243, "0dd9f529c744ed3c6be67f699588f7aadc4f366b5b7301dc31bd3f199944fbcc"),
            artifact("AudioEncoder.mlmodelc/coremldata.bin", 348, "ffa9eb76e8e9d9be75a4d527e5249e61d67fd43081c5aa110fd24efa6c8c5ea3"),
            artifact("AudioEncoder.mlmodelc/metadata.json", 1_974, "2cd0538f90a012de3f07d38669026d527490eff1dcfd2479a81c48206a90f0a2"),
            artifact("AudioEncoder.mlmodelc/model.mil", 7_589_739, "ef5a252831e61bb91d6547fe1add3d0658895b518d47d70004322b40a2192668"),
            artifact("AudioEncoder.mlmodelc/weights/weight.bin", 421_968_768, "e4740fa28ed65907af754af893dfce98473fafb84dd8d718ad346985fe7678c1"),
            artifact("MelSpectrogram.mlmodelc/analytics/coremldata.bin", 243, "c5be419f8622083ac7046306400643539f0e7577c843448c36defc090d41e7ce"),
            artifact("MelSpectrogram.mlmodelc/coremldata.bin", 329, "98efa1e351b759e078c4044668926d32bee886caf7596ae897e08e21da45565a"),
            artifact("MelSpectrogram.mlmodelc/metadata.json", 1_850, "2bc552e09a6f124d9e6c178dd1a6979e010206acb26308b2224887c9dcbeb35f"),
            artifact("MelSpectrogram.mlmodelc/model.mil", 10_143, "c270b95b5f81d7f7d0b8a3e8f991d4e5812a37cad29349868a35b91f3a6a4463"),
            artifact("MelSpectrogram.mlmodelc/weights/weight.bin", 373_376, "009d9fb8f6b589accfa08cebf1c712ef07c3405229ce3cfb3a57ee033c9d8a49"),
            artifact("TextDecoder.mlmodelc/analytics/coremldata.bin", 243, "4b5119bdc621c3c494f63846dc3ed43852e88826fc3b6345d42272d4b7e67724"),
            artifact("TextDecoder.mlmodelc/coremldata.bin", 633, "605dad4099a82cf2c7afe93e6d8e322f1c16d4160ab27bd017ec2517b81c1bdd"),
            artifact("TextDecoder.mlmodelc/metadata.json", 4_924, "e3ce6d83884552ffcc2c34799e8e1211dcda59f1aaea5a79bf988c6cd16abbf0"),
            artifact("TextDecoder.mlmodelc/model.mil", 217_177, "ebaf8566f367b6465276c3ed57bb99063888fa955b67828585bf19db24c85f56"),
            artifact("TextDecoder.mlmodelc/weights/weight.bin", 203_199_860, "d69700903d518ada33170ab77faaaf464496fb9ff65752c6d5a6109aa2fb02db"),
            artifact("TextDecoderContextPrefill.mlmodelc/analytics/coremldata.bin", 243, "97639d36c7b137ea51c3c39b175911788f4d4a601ab03cd67a4b14164c3145e1"),
            artifact("TextDecoderContextPrefill.mlmodelc/coremldata.bin", 380, "2c159f5c862ec187092ea58e755d8c0b298952e22f3d75da023d7693c1c7389e"),
            artifact("TextDecoderContextPrefill.mlmodelc/metadata.json", 2_240, "eb88dc350fa6748a8bc3fa5fb10958152c138752ebbbac1824d2f99b4c9fc068"),
            artifact("TextDecoderContextPrefill.mlmodelc/model.mil", 4_092, "990ff5052fd817e28ba7c34d9d06d324c69c7c0630b6eaac9cfdf08329dbcb34"),
            artifact("TextDecoderContextPrefill.mlmodelc/weights/weight.bin", 12_288_192, "1310070082639173e9d81508c5f220692d489e85655aa6883cc1c7506da7fcfd"),
            artifact("config.json", 1_149, "f01d83dd891791d6f12421c05d3ed8ebbe70866f10d6c9a7a7e80b558ce5a0f1"),
            artifact("generation_config.json", 2_767, "7fbb053a023be11fbeccd8421811610308143daa93d9617c52aab4a0fa1491c6")
        ]
    )

    static let whisperLargeV3Tokenizer = ModelManifest(
        identifier: "openai-whisper-large-v3-tokenizer",
        runtimeName: "WhisperKit",
        runtimeVersion: "1.0.0",
        runtimeRevision: "25c62997041c134b03ca82731ce2f6fd2cae1eb9",
        runtimeDirectoryName: "whisper-large-v3-tokenizer",
        repository: "openai/whisper-large-v3",
        modelRevision: "06f233fe06e710322aca913c1bc4249a0d71fce1",
        precision: "tokenizer",
        license: "Apache-2.0",
        expectedByteCount: 2_764_732,
        treeSHA256: ModelSHA256(
            "6e9e4fdf297e47536de698f87dd7e037561212cdce927e37826f5064c9e45052"
        )!,
        requiredTopLevelPaths: [
            "config.json",
            "tokenizer.json",
            "tokenizer_config.json"
        ],
        artifacts: [
            artifact("config.json", 1_272, "ad0e8d1e46f4d01f7861a21509e5d0f977d6cc1f367a370603c92541d819807b"),
            artifact("tokenizer.json", 2_480_617, "6d8cbd7cd0d8d5815e478dac67b85a26bbe77c1f5e0c6d76d1ce2abc0e5f21ca"),
            artifact("tokenizer_config.json", 282_843, "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389")
        ]
    )

    func downloadURL(for artifact: ModelArtifact) -> URL? {
        guard artifacts.contains(artifact),
              !repository.isEmpty,
              !modelRevision.isEmpty else {
            return nil
        }

        let sourcePrefix = sourcePathPrefix?
            .split(separator: "/")
            .map(String.init) ?? []
        let components = repository.split(separator: "/").map(String.init)
            + ["resolve", modelRevision]
            + sourcePrefix
            + artifact.relativePath.split(separator: "/").map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }

        return components.reduce(URL(string: "https://huggingface.co")!) { url, component in
            url.appendingPathComponent(component, isDirectory: false)
        }
    }

    func installationDirectory(in parentDirectory: URL) -> URL {
        parentDirectory.standardizedFileURL.appendingPathComponent(
            runtimeDirectoryName,
            isDirectory: true
        )
    }

    private static func artifact(_ path: String, _ byteCount: Int64, _ sha256: String) -> ModelArtifact {
        ModelArtifact(relativePath: path, byteCount: byteCount, sha256: ModelSHA256(sha256)!)
    }
}

/// Network-capable provisioning stays behind this user-initiated boundary.
/// The type is intentionally absent from the local dictation object graph.
struct UserInitiatedModelProvisioningRequest: Sendable {
    let manifest: ModelManifest
    let destinationDirectory: URL
    let initiatedAt: Date
    let authorizationID: UUID
}

struct ModelArtifactDownloadRequest: Sendable {
    let sourceURL: URL
    let destinationURL: URL
    let artifact: ModelArtifact
}

protocol ModelProvisioningTransport: Sendable {
    func download(_ request: ModelArtifactDownloadRequest) async throws
}
