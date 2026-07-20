import Foundation

public enum ASRTextMetrics {
    public static func normalized(_ text: String, language: BenchmarkLanguage) -> String {
        let canonical = text.precomposedStringWithCanonicalMapping.lowercased(with: language.locale)
        var scalars = String.UnicodeScalarView()
        var previousWasSeparator = true
        for scalar in canonical.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                scalars.append(" ")
                previousWasSeparator = true
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    public static func wordErrorRate(
        reference: String,
        hypothesis: String,
        language: BenchmarkLanguage
    ) -> Double {
        let referenceWords = normalized(reference, language: language).split(separator: " ").map(String.init)
        let hypothesisWords = normalized(hypothesis, language: language).split(separator: " ").map(String.init)
        return errorRate(reference: referenceWords, hypothesis: hypothesisWords)
    }

    public static func characterErrorRate(
        reference: String,
        hypothesis: String,
        language: BenchmarkLanguage
    ) -> Double {
        let referenceCharacters = Array(normalized(reference, language: language))
        let hypothesisCharacters = Array(normalized(hypothesis, language: language))
        return errorRate(reference: referenceCharacters, hypothesis: hypothesisCharacters)
    }

    public static func contains(
        span: String,
        in hypothesis: String,
        language: BenchmarkLanguage
    ) -> Bool {
        let needle = normalized(span, language: language).split(separator: " ").map(String.init)
        let haystack = normalized(hypothesis, language: language).split(separator: " ").map(String.init)
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        if needle.count == 1 {
            return haystack.contains(needle[0])
        }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle {
                return true
            }
        }
        return false
    }

    private static func errorRate<Element: Equatable>(
        reference: [Element],
        hypothesis: [Element]
    ) -> Double {
        guard !reference.isEmpty else { return hypothesis.isEmpty ? 0 : 1 }
        return Double(levenshtein(reference, hypothesis)) / Double(reference.count)
    }

    private static func levenshtein<Element: Equatable>(_ lhs: [Element], _ rhs: [Element]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        for (lhsIndex, lhsElement) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = lhsIndex + 1
            for (rhsIndex, rhsElement) in rhs.enumerated() {
                let substitution = previous[rhsIndex] + (lhsElement == rhsElement ? 0 : 1)
                current[rhsIndex + 1] = min(
                    previous[rhsIndex + 1] + 1,
                    current[rhsIndex] + 1,
                    substitution
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }
}

public enum DistributionMetrics {
    public static func summarize(_ values: [Double]) -> LatencySummary {
        let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !sorted.isEmpty else {
            return LatencySummary(
                sampleCount: 0,
                p50Milliseconds: nil,
                p95Milliseconds: nil,
                maximumMilliseconds: nil
            )
        }
        return LatencySummary(
            sampleCount: sorted.count,
            p50Milliseconds: nearestRank(0.50, values: sorted),
            p95Milliseconds: nearestRank(0.95, values: sorted),
            maximumMilliseconds: sorted.last
        )
    }

    private static func nearestRank(_ percentile: Double, values: [Double]) -> Double {
        let rank = max(1, Int(ceil(percentile * Double(values.count))))
        return values[rank - 1]
    }
}

public enum BenchmarkReporter {
    public static func makeReport(
        contract: CorpusContract,
        manifest: CorpusManifest,
        manifestData: Data,
        evidence: BenchmarkEvidence,
        corpusAssetsVerified: Bool
    ) throws -> BenchmarkReport {
        let contractIssues = CorpusValidator.validateContract(contract)
        guard contractIssues.isEmpty else {
            throw BenchmarkValidationError.invalidContract(contractIssues)
        }
        let manifestResult = CorpusValidator.validateManifest(manifest, against: contract)
        guard manifestResult.valid else {
            throw BenchmarkValidationError.invalidManifest(manifestResult.issues)
        }
        let evidenceIssues = EvidenceValidator.validate(
            evidence,
            manifest: manifest,
            contract: contract,
            manifestData: manifestData
        )
        guard evidenceIssues.isEmpty else {
            throw BenchmarkValidationError.invalidEvidence(evidenceIssues)
        }

        let clips = Dictionary(uniqueKeysWithValues: manifest.clips.map { ($0.id, $0) })
        let reports = evidence.candidates.map { candidate in
            CandidateReport(
                candidateID: candidate.provenance.candidateID,
                provenance: candidate.provenance,
                provenanceComplete: provenanceIsComplete(candidate.provenance),
                metrics: metrics(for: candidate, clips: clips, contract: contract)
            )
        }.sorted { $0.candidateID < $1.candidateID }

        return BenchmarkReport(
            schemaVersion: 1,
            benchmarkID: evidence.benchmarkID,
            phase: evidence.phase,
            profile: evidence.profile,
            corpusID: evidence.corpusID,
            corpusManifestSHA256: evidence.corpusManifestSHA256,
            corpusAssetsVerified: corpusAssetsVerified,
            randomizedEqualConditionsVerified: true,
            candidates: reports
        )
    }

    private static func metrics(
        for candidate: CandidateEvidence,
        clips: [String: ASRClip],
        contract: CorpusContract
    ) -> CandidateMetrics {
        let measured = candidate.observations.filter { $0.phase == .measured }
        let speech = measured.compactMap { observation -> (TrialObservation, ASRClip)? in
            guard let clip = clips[observation.clipID], clip.kind == .speech else { return nil }
            return (observation, clip)
        }
        let silence = measured.compactMap { observation -> (TrialObservation, ASRClip)? in
            guard let clip = clips[observation.clipID], clip.kind == .silence else { return nil }
            return (observation, clip)
        }

        var werByLanguage: [String: Double] = [:]
        var cerByLanguage: [String: Double] = [:]
        var werByBand: [String: [String: Double]] = [:]
        for language in BenchmarkLanguage.allCases {
            let languageSamples = speech.filter { $0.1.language == language }
            werByLanguage[language.rawValue] = macroRate(languageSamples) { observation, clip in
                ASRTextMetrics.wordErrorRate(
                    reference: clip.goldTranscript,
                    hypothesis: observation.hypothesis,
                    language: language
                )
            }
            cerByLanguage[language.rawValue] = macroRate(languageSamples) { observation, clip in
                ASRTextMetrics.characterErrorRate(
                    reference: clip.goldTranscript,
                    hypothesis: observation.hypothesis,
                    language: language
                )
            }
            for band in QualityBand.allCases {
                let bandSamples = languageSamples.filter { $0.1.qualityBand == band }
                var values = werByBand[band.rawValue] ?? [:]
                values[language.rawValue] = macroRate(bandSamples) { observation, clip in
                    ASRTextMetrics.wordErrorRate(
                        reference: clip.goldTranscript,
                        hypothesis: observation.hypothesis,
                        language: language
                    )
                }
                werByBand[band.rawValue] = values
            }
        }

        let severeOmissions = speech.reduce(into: 0) { total, sample in
            let (observation, clip) = sample
            guard let language = clip.language else { return }
            let automatic = clip.substantialSpans.compactMap { span in
                ASRTextMetrics.contains(span: span.text, in: observation.hypothesis, language: language)
                    ? nil
                    : span.id
            }
            total += Set(automatic + observation.reviewedSevereOmissionSpanIDs).count
        }
        let silenceHallucinations = silence.filter { observation, _ in
            guard observation.confirmedMutation else { return false }
            return !(observation.insertedText ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }.count

        let performance = speech.filter { $0.1.isPerformanceSample }
        let asrLatency = DistributionMetrics.summarize(performance.map { $0.0.asrLatencyMilliseconds })
        let endToInsert = DistributionMetrics.summarize(
            performance.compactMap { sample in
                sample.0.confirmedMutation ? sample.0.endToInsertMilliseconds : nil
            }
        )
        let fallback = DistributionMetrics.summarize(
            performance.compactMap { sample in
                sample.0.usedSafeFallback ? sample.0.timeToSafeFallbackMilliseconds : nil
            }
        )
        let coldModelReady = DistributionMetrics.summarize(candidate.coldStarts.map(\.modelReadyMilliseconds))
        let warmPeakRSS = performance.map { $0.0.peakRSSBytes }.max() ?? 0
        let coldPeakRSS = candidate.coldStarts.map(\.peakRSSBytes).max() ?? 0
        let thermalStates = measured.map(\.thermalState) + candidate.coldStarts.map(\.thermalState)
        let worstThermal = thermalStates.max { $0.severity < $1.severity } ?? .unknown

        return CandidateMetrics(
            macroWERByLanguage: werByLanguage,
            macroCERByLanguage: cerByLanguage,
            macroWERByQualityBand: werByBand,
            severeOmissions: severeOmissions,
            silenceSampleCount: silence.count,
            silenceHallucinations: silenceHallucinations,
            asrLatency: asrLatency,
            endToInsertLatency: endToInsert,
            timeToSafeFallback: fallback,
            confirmedInsertionCount: performance.filter { $0.0.confirmedMutation }.count,
            expectedPerformanceInsertionCount:
                contract.performanceSample.countByLanguage.de
                    + contract.performanceSample.countByLanguage.en,
            warmPeakRSSBytes: warmPeakRSS,
            coldPeakRSSBytes: coldPeakRSS,
            coldModelReady: coldModelReady,
            worstThermalState: worstThermal,
            runtimeNetworkConnections: candidate.runtimeNetworkConnections
        )
    }

    private static func macroRate(
        _ samples: [(TrialObservation, ASRClip)],
        metric: (TrialObservation, ASRClip) -> Double
    ) -> Double {
        guard !samples.isEmpty else { return .nan }
        return samples.reduce(0) { $0 + metric($1.0, $1.1) } / Double(samples.count)
    }

    private static func provenanceIsComplete(_ provenance: CandidateProvenance) -> Bool {
        [provenance.runtime, provenance.model, provenance.adapter].allSatisfy { component in
            !component.name.isEmpty
                && !component.version.isEmpty
                && !component.revision.isEmpty
                && component.repositoryURL.hasPrefix("https://")
                && !component.licenseSPDX.isEmpty
                && !component.attribution.isEmpty
                && !component.artifacts.isEmpty
                && component.artifacts.allSatisfy {
                    isSafeRelativePath($0.path) && $0.byteCount > 0 && isSHA256($0.sha256)
                }
        }
    }
}
