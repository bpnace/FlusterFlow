import CryptoKit
import Foundation

public enum BenchmarkValidationError: Error, Equatable, Sendable {
    case invalidContract([ValidationIssue])
    case invalidManifest([ValidationIssue])
    case invalidEvidence([ValidationIssue])
}

public enum SHA256Digest {
    public static func hex(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hex(fileAt url: URL) throws -> String {
        try hex(data: Data(contentsOf: url, options: [.mappedIfSafe]))
    }
}

public enum CorpusValidator {
    public static func validateContract(_ contract: CorpusContract) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        require(contract.schemaVersion == 1, "unsupported_schema", "contract.schemaVersion", &issues)
        require(!contract.corpusID.isEmpty, "missing_value", "contract.corpusID", &issues)
        require(!contract.corpusVersion.isEmpty, "missing_value", "contract.corpusVersion", &issues)
        require(contract.speechClipCount > 0, "invalid_count", "contract.speechClipCount", &issues)
        require(contract.silenceClipCount >= 0, "invalid_count", "contract.silenceClipCount", &issues)
        require(
            contract.speechCountByLanguage.de + contract.speechCountByLanguage.en == contract.speechClipCount,
            "language_count_mismatch",
            "contract.speechCountByLanguage",
            &issues
        )
        require(
            contract.minimumSpeechDurationSeconds > 0
                && contract.maximumSpeechDurationSeconds >= contract.minimumSpeechDurationSeconds,
            "invalid_duration_range",
            "contract.duration",
            &issues
        )
        require(
            Set(contract.stratumRequirements.map(\.stratum)).count == contract.stratumRequirements.count,
            "duplicate_stratum",
            "contract.stratumRequirements",
            &issues
        )
        for language in BenchmarkLanguage.allCases {
            let total = contract.stratumRequirements.reduce(0) { $0 + $1.perLanguage }
            require(
                total == contract.speechCountByLanguage[language],
                "stratum_count_mismatch",
                "contract.stratumRequirements.\(language.rawValue)",
                &issues
            )
        }
        require(
            contract.performanceSample.minimumDurationSeconds >= contract.minimumSpeechDurationSeconds
                && contract.performanceSample.maximumDurationSeconds <= contract.maximumSpeechDurationSeconds
                && contract.performanceSample.maximumDurationSeconds
                    >= contract.performanceSample.minimumDurationSeconds,
            "invalid_performance_duration_range",
            "contract.performanceSample",
            &issues
        )
        require(
            contract.performanceSample.countByLanguage.de <= contract.speechCountByLanguage.de
                && contract.performanceSample.countByLanguage.en <= contract.speechCountByLanguage.en,
            "invalid_performance_count",
            "contract.performanceSample.countByLanguage",
            &issues
        )
        require(
            contract.performanceSample.warmupRunsPerCandidate >= 0,
            "invalid_count",
            "contract.performanceSample.warmupRunsPerCandidate",
            &issues
        )
        require(
            contract.performanceSample.coldStartsPerCandidate >= 0,
            "invalid_count",
            "contract.performanceSample.coldStartsPerCandidate",
            &issues
        )
        require(
            Set(contract.allowedSourceKinds).count == contract.allowedSourceKinds.count
                && !contract.allowedSourceKinds.isEmpty,
            "invalid_source_allowlist",
            "contract.allowedSourceKinds",
            &issues
        )

        if contract.corpusID == WFASR1.contract.corpusID || contract.profile == .release {
            require(
                contract == WFASR1.contract,
                "release_contract_not_canonical_wf_asr_1",
                "contract",
                &issues
            )
        }
        return issues
    }

    public static func validateManifest(
        _ manifest: CorpusManifest,
        against contract: CorpusContract,
        assetRoot: URL? = nil
    ) -> ValidationResult {
        var issues = validateContract(contract)
        require(manifest.schemaVersion == 1, "unsupported_schema", "manifest.schemaVersion", &issues)
        require(manifest.corpusID == contract.corpusID, "corpus_id_mismatch", "manifest.corpusID", &issues)
        require(
            manifest.corpusVersion == contract.corpusVersion,
            "corpus_version_mismatch",
            "manifest.corpusVersion",
            &issues
        )
        require(manifest.profile == contract.profile, "profile_mismatch", "manifest.profile", &issues)
        require(!manifest.provenance.producer.isEmpty, "missing_value", "manifest.provenance.producer", &issues)
        require(
            !manifest.provenance.repositoryRevision.isEmpty,
            "missing_value",
            "manifest.provenance.repositoryRevision",
            &issues
        )
        require(
            !manifest.provenance.declaration.isEmpty,
            "missing_value",
            "manifest.provenance.declaration",
            &issues
        )

        let ids = manifest.clips.map(\.id)
        require(Set(ids).count == ids.count, "duplicate_clip_id", "manifest.clips", &issues)
        let paths = manifest.clips.map(\.assetPath)
        require(Set(paths).count == paths.count, "duplicate_asset_path", "manifest.clips", &issues)

        let speech = manifest.clips.filter { $0.kind == .speech }
        let silence = manifest.clips.filter { $0.kind == .silence }
        require(speech.count == contract.speechClipCount, "speech_count_mismatch", "manifest.clips", &issues)
        require(silence.count == contract.silenceClipCount, "silence_count_mismatch", "manifest.clips", &issues)

        for language in BenchmarkLanguage.allCases {
            let languageClips = speech.filter { $0.language == language }
            require(
                languageClips.count == contract.speechCountByLanguage[language],
                "language_count_mismatch",
                "manifest.clips.\(language.rawValue)",
                &issues
            )
            for requirement in contract.stratumRequirements {
                require(
                    languageClips.filter { $0.stratum == requirement.stratum }.count
                        == requirement.perLanguage,
                    "stratum_count_mismatch",
                    "manifest.clips.\(language.rawValue).\(requirement.stratum.rawValue)",
                    &issues
                )
            }
            for band in QualityBand.allCases {
                require(
                    languageClips.contains { $0.qualityBand == band },
                    "quality_band_missing",
                    "manifest.clips.\(language.rawValue).\(band.rawValue)",
                    &issues
                )
            }
            let performance = languageClips.filter(\.isPerformanceSample)
            require(
                performance.count == contract.performanceSample.countByLanguage[language],
                "performance_count_mismatch",
                "manifest.performance.\(language.rawValue)",
                &issues
            )
            for clip in performance {
                require(
                    clip.durationSeconds >= contract.performanceSample.minimumDurationSeconds
                        && clip.durationSeconds <= contract.performanceSample.maximumDurationSeconds,
                    "performance_duration_out_of_range",
                    "manifest.clips.\(clip.id).durationSeconds",
                    &issues
                )
            }
        }

        for clip in manifest.clips {
            validate(clip: clip, contract: contract, issues: &issues)
        }

        var assetsVerified = false
        if let assetRoot {
            let assetIssues = validateAssets(manifest.clips, root: assetRoot)
            issues.append(contentsOf: assetIssues)
            assetsVerified = assetIssues.isEmpty && manifest.clips.allSatisfy { $0.assetState == .provisioned }
        }

        let valid = issues.isEmpty
        let releaseEligible = valid
            && contract.profile == .release
            && contract == WFASR1.contract
            && assetsVerified
        return ValidationResult(
            valid: valid,
            releaseEligible: releaseEligible,
            corpusAssetsVerified: assetsVerified,
            issues: issues.sorted(by: issueOrder)
        )
    }

    private static func validate(
        clip: ASRClip,
        contract: CorpusContract,
        issues: inout [ValidationIssue]
    ) {
        let path = "manifest.clips.\(clip.id)"
        require(!clip.id.isEmpty, "missing_value", "\(path).id", &issues)
        require(isSafeRelativePath(clip.assetPath), "unsafe_asset_path", "\(path).assetPath", &issues)
        require(isSHA256(clip.assetSHA256), "invalid_sha256", "\(path).assetSHA256", &issues)
        require(clip.durationSeconds.isFinite && clip.durationSeconds > 0, "invalid_duration", "\(path).durationSeconds", &issues)
        require(
            contract.allowedSourceKinds.contains(clip.provenance.sourceKind),
            "source_kind_not_allowed",
            "\(path).provenance.sourceKind",
            &issues
        )
        require(
            !clip.provenance.sourceReference.isEmpty,
            "missing_value",
            "\(path).provenance.sourceReference",
            &issues
        )
        validate(provenance: clip.provenance, path: "\(path).provenance", issues: &issues)

        let spanIDs = clip.substantialSpans.map(\.id)
        require(Set(spanIDs).count == spanIDs.count, "duplicate_span_id", "\(path).substantialSpans", &issues)
        for span in clip.substantialSpans {
            require(!span.id.isEmpty && !span.text.isEmpty, "invalid_span", "\(path).substantialSpans", &issues)
        }

        switch clip.kind {
        case .speech:
            require(clip.language != nil, "missing_language", "\(path).language", &issues)
            require(clip.stratum != nil, "missing_stratum", "\(path).stratum", &issues)
            require(clip.qualityBand != nil, "missing_quality_band", "\(path).qualityBand", &issues)
            require(!clip.goldTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "missing_gold", "\(path).goldTranscript", &issues)
            require(!clip.substantialSpans.isEmpty, "missing_substantial_spans", "\(path).substantialSpans", &issues)
            if let language = clip.language {
                for span in clip.substantialSpans {
                    require(
                        ASRTextMetrics.contains(
                            span: span.text,
                            in: clip.goldTranscript,
                            language: language
                        ),
                        "span_not_in_gold",
                        "\(path).substantialSpans.\(span.id)",
                        &issues
                    )
                }
            }
            require(
                clip.durationSeconds >= contract.minimumSpeechDurationSeconds
                    && clip.durationSeconds <= contract.maximumSpeechDurationSeconds,
                "speech_duration_out_of_range",
                "\(path).durationSeconds",
                &issues
            )
        case .silence:
            require(clip.language == nil, "silence_has_language", "\(path).language", &issues)
            require(clip.stratum == nil, "silence_has_stratum", "\(path).stratum", &issues)
            require(clip.qualityBand == nil, "silence_has_quality_band", "\(path).qualityBand", &issues)
            require(!clip.isPerformanceSample, "silence_is_performance_sample", "\(path).isPerformanceSample", &issues)
            require(clip.goldTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "silence_has_gold", "\(path).goldTranscript", &issues)
            require(clip.substantialSpans.isEmpty, "silence_has_spans", "\(path).substantialSpans", &issues)
        }

        if contract.profile == .release {
            require(clip.assetState == .provisioned, "release_asset_unprovisioned", "\(path).assetState", &issues)
        }
    }

    private static func validate(
        provenance: ClipProvenance,
        path: String,
        issues: inout [ValidationIssue]
    ) {
        switch provenance.sourceKind {
        case .synthetic:
            require(
                !(provenance.generator ?? "").isEmpty && !(provenance.generatorVersion ?? "").isEmpty,
                "synthetic_generator_missing",
                path,
                &issues
            )
        case .publicLicensed:
            require(
                !(provenance.licenseSPDX ?? "").isEmpty && !(provenance.attribution ?? "").isEmpty,
                "public_license_provenance_missing",
                path,
                &issues
            )
        case .consented:
            require(
                !(provenance.consentRecordID ?? "").isEmpty,
                "consent_record_missing",
                path,
                &issues
            )
        }
    }

    private static func validateAssets(_ clips: [ASRClip], root: URL) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        for clip in clips {
            let path = "manifest.clips.\(clip.id).asset"
            guard clip.assetState == .provisioned else {
                issues.append(ValidationIssue(code: "asset_unprovisioned", path: path))
                continue
            }
            let asset = canonicalRoot.appendingPathComponent(clip.assetPath).standardizedFileURL
            let resolved = asset.resolvingSymlinksInPath()
            guard isDescendant(resolved, of: canonicalRoot) else {
                issues.append(ValidationIssue(code: "asset_outside_root", path: path))
                continue
            }
            guard FileManager.default.fileExists(atPath: resolved.path) else {
                issues.append(ValidationIssue(code: "asset_missing", path: path))
                continue
            }
            do {
                if try SHA256Digest.hex(fileAt: resolved) != clip.assetSHA256 {
                    issues.append(ValidationIssue(code: "asset_hash_mismatch", path: path))
                }
            } catch {
                issues.append(ValidationIssue(code: "asset_unreadable", path: path))
            }
        }
        return issues
    }
}

public enum PersonalCorpusValidator {
    public static func validateContract(_ contract: PersonalCorpusContract) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        require(contract.schemaVersion == 1, "unsupported_schema", "contract.schemaVersion", &issues)
        require(contract.corpusID == "WF-PERSONAL-DE-1", "corpus_id_mismatch", "contract.corpusID", &issues)
        require(contract.language == .german, "language_mismatch", "contract.language", &issues)
        require(contract.clipCount == 40, "clip_count_mismatch", "contract.clipCount", &issues)
        require(
            contract.minimumDurationSeconds > 0
                && contract.maximumDurationSeconds >= contract.minimumDurationSeconds,
            "invalid_duration_range",
            "contract.duration",
            &issues
        )
        require(
            Set(contract.categories.map(\.category)).count == contract.categories.count,
            "duplicate_category",
            "contract.categories",
            &issues
        )
        require(
            contract.categories.reduce(0) { $0 + $1.count } == contract.clipCount,
            "category_count_mismatch",
            "contract.categories",
            &issues
        )
        require(
            contract == WFPersonalDE1.contract,
            "personal_contract_not_canonical_wf_personal_de_1",
            "contract",
            &issues
        )
        return issues.sorted(by: issueOrder)
    }
}

public enum EvidenceValidator {
    public static func validate(
        _ evidence: BenchmarkEvidence,
        manifest: CorpusManifest,
        contract: CorpusContract,
        manifestData: Data
    ) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        require(evidence.schemaVersion == 1, "unsupported_schema", "evidence.schemaVersion", &issues)
        require(!evidence.benchmarkID.isEmpty, "missing_value", "evidence.benchmarkID", &issues)
        require(evidence.profile == manifest.profile, "profile_mismatch", "evidence.profile", &issues)
        require(evidence.corpusID == manifest.corpusID, "corpus_id_mismatch", "evidence.corpusID", &issues)
        require(
            evidence.corpusManifestSHA256 == SHA256Digest.hex(data: manifestData),
            "manifest_hash_mismatch",
            "evidence.corpusManifestSHA256",
            &issues
        )
        require(!evidence.candidates.isEmpty, "missing_candidates", "evidence.candidates", &issues)
        let candidateIDs = evidence.candidates.map { $0.provenance.candidateID }
        require(Set(candidateIDs).count == candidateIDs.count, "duplicate_candidate_id", "evidence.candidates", &issues)

        let expected = RunScheduler.make(
            manifest: manifest,
            candidateIDs: candidateIDs,
            seed: evidence.schedule.seed,
            warmupRunsPerCandidate: evidence.schedule.warmupRunsPerCandidate
        )
        require(evidence.schedule.algorithm == RunScheduler.algorithm, "unsupported_schedule_algorithm", "evidence.schedule.algorithm", &issues)
        require(evidence.schedule == expected, "schedule_not_reproducible", "evidence.schedule", &issues)
        require(
            evidence.schedule.warmupRunsPerCandidate == contract.performanceSample.warmupRunsPerCandidate,
            "warmup_count_mismatch",
            "evidence.schedule.warmupRunsPerCandidate",
            &issues
        )

        let firstPreprocessing = evidence.candidates.first?.provenance.audioPreprocessing
        let firstToolchain = evidence.candidates.first?.provenance.toolchain
        for candidate in evidence.candidates {
            let id = candidate.provenance.candidateID
            let path = "evidence.candidates.\(id)"
            require(!id.isEmpty, "missing_candidate_id", "\(path).provenance", &issues)
            require(
                candidate.provenance.audioPreprocessing == firstPreprocessing,
                "unequal_audio_preprocessing",
                "\(path).audioPreprocessing",
                &issues
            )
            require(
                candidate.provenance.toolchain == firstToolchain,
                "unequal_toolchain",
                "\(path).toolchain",
                &issues
            )
            if evidence.profile == .release {
                require(
                    candidate.provenance.toolchain.buildConfiguration.lowercased() == "release",
                    "release_build_required",
                    "\(path).toolchain.buildConfiguration",
                    &issues
                )
            }
            validate(provenance: candidate.provenance, path: "\(path).provenance", issues: &issues)
            require(candidate.runtimeNetworkConnections >= 0, "invalid_count", "\(path).runtimeNetworkConnections", &issues)
            require(
                candidate.coldStarts.count == contract.performanceSample.coldStartsPerCandidate,
                "cold_start_count_mismatch",
                "\(path).coldStarts",
                &issues
            )
            validateObservations(
                candidate,
                schedule: evidence.schedule,
                manifest: manifest,
                evidencePhase: evidence.phase,
                issues: &issues
            )
        }
        return issues.sorted(by: issueOrder)
    }

    private static func validate(
        provenance: CandidateProvenance,
        path: String,
        issues: inout [ValidationIssue]
    ) {
        validate(component: provenance.runtime, path: "\(path).runtime", issues: &issues)
        validate(component: provenance.model, path: "\(path).model", issues: &issues)
        validate(component: provenance.adapter, path: "\(path).adapter", issues: &issues)
        require(provenance.toolchain.memoryBytes > 0, "invalid_memory", "\(path).toolchain.memoryBytes", &issues)
        require(provenance.audioPreprocessing.sampleRateHz > 0, "invalid_sample_rate", "\(path).audioPreprocessing.sampleRateHz", &issues)
        require(provenance.audioPreprocessing.channelCount > 0, "invalid_channel_count", "\(path).audioPreprocessing.channelCount", &issues)
    }

    private static func validate(
        component: ComponentProvenance,
        path: String,
        issues: inout [ValidationIssue]
    ) {
        require(!component.name.isEmpty, "missing_value", "\(path).name", &issues)
        require(!component.version.isEmpty, "missing_value", "\(path).version", &issues)
        require(!component.revision.isEmpty, "missing_value", "\(path).revision", &issues)
        require(component.repositoryURL.hasPrefix("https://"), "invalid_repository_url", "\(path).repositoryURL", &issues)
        require(!component.licenseSPDX.isEmpty, "missing_value", "\(path).licenseSPDX", &issues)
        require(!component.attribution.isEmpty, "missing_value", "\(path).attribution", &issues)
        require(!component.artifacts.isEmpty, "missing_artifacts", "\(path).artifacts", &issues)
        let artifactPaths = component.artifacts.map(\.path)
        require(Set(artifactPaths).count == artifactPaths.count, "duplicate_artifact", "\(path).artifacts", &issues)
        for artifact in component.artifacts {
            require(isSafeRelativePath(artifact.path), "unsafe_artifact_path", "\(path).artifacts", &issues)
            require(artifact.byteCount > 0, "invalid_byte_count", "\(path).artifacts", &issues)
            require(isSHA256(artifact.sha256), "invalid_sha256", "\(path).artifacts", &issues)
        }
    }

    private static func validateObservations(
        _ candidate: CandidateEvidence,
        schedule: RandomizedSchedule,
        manifest: CorpusManifest,
        evidencePhase: BenchmarkPhase,
        issues: inout [ValidationIssue]
    ) {
        let candidateID = candidate.provenance.candidateID
        let expectedTrials = schedule.trials.filter { $0.candidateID == candidateID }
        let observationsByOrdinal = Dictionary(
            grouping: candidate.observations,
            by: \.scheduleOrdinal
        )
        require(
            observationsByOrdinal.values.allSatisfy { $0.count == 1 },
            "duplicate_observation_ordinal",
            "evidence.candidates.\(candidateID).observations",
            &issues
        )
        require(
            candidate.observations.count == expectedTrials.count,
            "observation_count_mismatch",
            "evidence.candidates.\(candidateID).observations",
            &issues
        )
        let clips = Dictionary(uniqueKeysWithValues: manifest.clips.map { ($0.id, $0) })
        for trial in expectedTrials {
            let path = "evidence.candidates.\(candidateID).observations.\(trial.ordinal)"
            guard let observation = observationsByOrdinal[trial.ordinal]?.first else {
                issues.append(ValidationIssue(code: "observation_missing", path: path))
                continue
            }
            require(observation.clipID == trial.clipID, "observation_clip_mismatch", "\(path).clipID", &issues)
            require(observation.phase == trial.phase, "observation_phase_mismatch", "\(path).phase", &issues)
            require(
                observation.asrLatencyMilliseconds.isFinite && observation.asrLatencyMilliseconds >= 0,
                "invalid_latency",
                "\(path).asrLatencyMilliseconds",
                &issues
            )
            require(observation.peakRSSBytes >= 0, "invalid_rss", "\(path).peakRSSBytes", &issues)
            require(
                !(observation.confirmedMutation && observation.usedSafeFallback),
                "mutation_and_fallback_conflict",
                path,
                &issues
            )
            if observation.confirmedMutation {
                require(
                    !(observation.insertedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || clips[trial.clipID]?.kind == .silence,
                    "confirmed_mutation_without_text",
                    "\(path).insertedText",
                    &issues
                )
                if evidencePhase == .fullPipeline {
                    require(observation.endToInsertMilliseconds != nil, "missing_end_to_insert", "\(path).endToInsertMilliseconds", &issues)
                }
            } else {
                require(observation.endToInsertMilliseconds == nil, "unconfirmed_end_to_insert", "\(path).endToInsertMilliseconds", &issues)
                require(
                    (observation.insertedText ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty,
                    "unconfirmed_inserted_text",
                    "\(path).insertedText",
                    &issues
                )
            }
            if observation.usedSafeFallback {
                require(observation.timeToSafeFallbackMilliseconds != nil, "missing_fallback_latency", "\(path).timeToSafeFallbackMilliseconds", &issues)
            }
            if let value = observation.endToInsertMilliseconds {
                require(value.isFinite && value >= 0, "invalid_latency", "\(path).endToInsertMilliseconds", &issues)
            }
            if let value = observation.timeToSafeFallbackMilliseconds {
                require(value.isFinite && value >= 0, "invalid_latency", "\(path).timeToSafeFallbackMilliseconds", &issues)
            }
            if let clip = clips[trial.clipID] {
                let validSpanIDs = Set(clip.substantialSpans.map(\.id))
                require(
                    Set(observation.reviewedSevereOmissionSpanIDs).isSubset(of: validSpanIDs),
                    "unknown_reviewed_span",
                    "\(path).reviewedSevereOmissionSpanIDs",
                    &issues
                )
            }
        }
        for cold in candidate.coldStarts {
            let path = "evidence.candidates.\(candidateID).coldStarts.\(cold.ordinal)"
            require(
                cold.modelReadyMilliseconds.isFinite && cold.modelReadyMilliseconds >= 0,
                "invalid_latency",
                "\(path).modelReadyMilliseconds",
                &issues
            )
            require(cold.peakRSSBytes >= 0, "invalid_rss", "\(path).peakRSSBytes", &issues)
        }
        let coldOrdinals = candidate.coldStarts.map(\.ordinal)
        require(
            Set(coldOrdinals).count == coldOrdinals.count,
            "duplicate_cold_start_ordinal",
            "evidence.candidates.\(candidateID).coldStarts",
            &issues
        )
    }
}

func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...102).contains(byte)
    }
}

func isSafeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
}

func isDescendant(_ candidate: URL, of root: URL) -> Bool {
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    return candidate.path.hasPrefix(rootPath)
}

func require(
    _ condition: @autoclosure () -> Bool,
    _ code: String,
    _ path: String,
    _ issues: inout [ValidationIssue]
) {
    if !condition() {
        issues.append(ValidationIssue(code: code, path: path))
    }
}

func issueOrder(_ lhs: ValidationIssue, _ rhs: ValidationIssue) -> Bool {
    lhs.path == rhs.path ? lhs.code < rhs.code : lhs.path < rhs.path
}
