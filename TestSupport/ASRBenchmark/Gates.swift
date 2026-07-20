import Foundation

public enum ASRGateEvaluator {
    public static let cleanMacroWERMaximum = 0.15
    public static let noisyMixedMacroWERMaximum = 0.22
    public static let warmASRP50MaximumMilliseconds = 1_500.0
    public static let warmASRP95MaximumMilliseconds = 3_250.0
    public static let warmEndToInsertP50MaximumMilliseconds = 2_000.0
    public static let warmEndToInsertP95MaximumMilliseconds = 4_000.0
    public static let warmPeakRSSMaximumBytes: Int64 = 4_500_000_000
    public static let coldPeakRSSMaximumBytes: Int64 = 6_000_000_000
    public static let fluidWERNonInferiorityMargin = 0.01
    public static let fluidPerformanceRatioMaximum = 1.20

    private static let fluidCandidateID = "fluid-audio"
    private static let argmaxCandidateID = "argmax"

    public static func evaluateASRA(_ report: BenchmarkReport) -> GateEvaluation {
        let groupedReports = Dictionary(grouping: report.candidates, by: \.candidateID)
        let reports = groupedReports.compactMapValues(\.first)
        let requiredIDs = [fluidCandidateID, argmaxCandidateID]
        var decisions = reports.values.map { candidate in
            evaluateASRA(candidate: candidate, report: report)
        }
        for duplicateID in groupedReports.keys where groupedReports[duplicateID, default: []].count > 1 {
            decisions.removeAll { $0.candidateID == duplicateID }
            decisions.append(
                CandidateGateDecision(
                    candidateID: duplicateID,
                    status: .ineligible,
                    failedChecks: ["duplicate_candidate_id"]
                )
            )
        }
        for missingID in requiredIDs where reports[missingID] == nil {
            decisions.append(
                CandidateGateDecision(
                    candidateID: missingID,
                    status: .ineligible,
                    failedChecks: ["required_candidate_missing"]
                )
            )
        }
        decisions.sort { $0.candidateID < $1.candidateID }

        let decisionByID = Dictionary(uniqueKeysWithValues: decisions.map { ($0.candidateID, $0) })
        let bothEvaluated = requiredIDs.allSatisfy { decisionByID[$0]?.status != .ineligible }
        let passing = requiredIDs.filter { decisionByID[$0]?.status == .pass }
        var selected: String?
        if bothEvaluated && passing.count == 1 {
            selected = passing[0]
        } else if bothEvaluated,
                  passing.count == 2,
                  let fluid = reports[fluidCandidateID],
                  let argmax = reports[argmaxCandidateID] {
            selected = fluidIsNonInferior(to: argmax, fluid: fluid)
                ? fluidCandidateID
                : argmaxCandidateID
        }

        return GateEvaluation(
            schemaVersion: 1,
            gate: .asrA,
            benchmarkID: report.benchmarkID,
            decisions: decisions,
            selectedCandidateID: selected,
            stopBeforeLocalAlpha: selected == nil
        )
    }

    public static func evaluateASRB(
        _ report: BenchmarkReport,
        priorASRA: GateEvaluation
    ) -> GateEvaluation {
        let selected = priorASRA.gate == .asrA ? priorASRA.selectedCandidateID : nil
        let priorPassed = selected.flatMap { selectedID in
            priorASRA.decisions.first { $0.candidateID == selectedID }
        }?.status == .pass

        var decisions: [CandidateGateDecision] = []
        let groupedReports = Dictionary(grouping: report.candidates, by: \.candidateID)
        for candidate in groupedReports.compactMap({ $0.value.first }) {
            var ineligible: [String] = []
            var failed: [String] = []
            if groupedReports[candidate.candidateID, default: []].count > 1 {
                ineligible.append("duplicate_candidate_id")
            }
            if report.schemaVersion != 1 { ineligible.append("unsupported_report_schema") }
            if !isSHA256(report.corpusManifestSHA256) { ineligible.append("invalid_manifest_hash") }
            if report.profile != .release { ineligible.append("release_profile_required") }
            if report.phase != .fullPipeline { ineligible.append("full_pipeline_phase_required") }
            if report.corpusID != WFASR1.contract.corpusID { ineligible.append("wf_asr_1_required") }
            if !report.corpusAssetsVerified { ineligible.append("corpus_assets_not_verified") }
            if !report.randomizedEqualConditionsVerified { ineligible.append("randomized_equal_conditions_not_verified") }
            if candidate.candidateID != selected { ineligible.append("candidate_not_selected_by_asr_a") }
            if candidate.candidateID != candidate.provenance.candidateID {
                ineligible.append("candidate_id_provenance_mismatch")
            }
            if !priorPassed { ineligible.append("passing_asr_a_evaluation_required") }
            if !candidate.provenanceComplete { ineligible.append("provenance_incomplete") }
            eligibilityChecks(candidate.metrics, ineligible: &ineligible)

            qualityChecks(candidate.metrics, failed: &failed)
            if candidate.metrics.endToInsertLatency.sampleCount != 60 {
                ineligible.append("end_to_insert_sample_count_not_60")
            }
            if candidate.metrics.confirmedInsertionCount != 60
                || candidate.metrics.expectedPerformanceInsertionCount != 60 {
                failed.append("confirmed_insertion_not_60_of_60")
            }
            compare(
                candidate.metrics.endToInsertLatency.p50Milliseconds,
                maximum: warmEndToInsertP50MaximumMilliseconds,
                code: "end_to_insert_p50_over_2000ms",
                missingCode: "end_to_insert_p50_missing",
                ineligible: &ineligible,
                failed: &failed
            )
            compare(
                candidate.metrics.endToInsertLatency.p95Milliseconds,
                maximum: warmEndToInsertP95MaximumMilliseconds,
                code: "end_to_insert_p95_over_4000ms",
                missingCode: "end_to_insert_p95_missing",
                ineligible: &ineligible,
                failed: &failed
            )
            rssAndNetworkChecks(candidate.metrics, failed: &failed)

            let status: GateStatus = !ineligible.isEmpty ? .ineligible : (failed.isEmpty ? .pass : .fail)
            decisions.append(
                CandidateGateDecision(
                    candidateID: candidate.candidateID,
                    status: status,
                    failedChecks: (ineligible + failed).sorted()
                )
            )
        }
        if let selected,
           !report.candidates.contains(where: { $0.candidateID == selected }) {
            decisions.append(
                CandidateGateDecision(
                    candidateID: selected,
                    status: .ineligible,
                    failedChecks: ["selected_candidate_missing"]
                )
            )
        }
        decisions.sort { $0.candidateID < $1.candidateID }
        let passed = selected.flatMap { selectedID in
            decisions.first { $0.candidateID == selectedID }
        }?.status == .pass
        return GateEvaluation(
            schemaVersion: 1,
            gate: .asrB,
            benchmarkID: report.benchmarkID,
            decisions: decisions,
            selectedCandidateID: passed ? selected : nil,
            stopBeforeLocalAlpha: !passed
        )
    }

    private static func evaluateASRA(
        candidate: CandidateReport,
        report: BenchmarkReport
    ) -> CandidateGateDecision {
        var ineligible: [String] = []
        var failed: [String] = []
        if report.schemaVersion != 1 { ineligible.append("unsupported_report_schema") }
        if !isSHA256(report.corpusManifestSHA256) { ineligible.append("invalid_manifest_hash") }
        if report.profile != .release { ineligible.append("release_profile_required") }
        if report.phase != .asrOnly { ineligible.append("asr_only_phase_required") }
        if report.corpusID != WFASR1.contract.corpusID { ineligible.append("wf_asr_1_required") }
        if !report.corpusAssetsVerified { ineligible.append("corpus_assets_not_verified") }
        if !report.randomizedEqualConditionsVerified { ineligible.append("randomized_equal_conditions_not_verified") }
        if !candidate.provenanceComplete { ineligible.append("provenance_incomplete") }
        if candidate.candidateID != candidate.provenance.candidateID {
            ineligible.append("candidate_id_provenance_mismatch")
        }
        eligibilityChecks(candidate.metrics, ineligible: &ineligible)
        if candidate.metrics.asrLatency.sampleCount != 60 {
            ineligible.append("asr_performance_sample_count_not_60")
        }
        if candidate.metrics.coldModelReady.sampleCount != 10 {
            ineligible.append("cold_start_sample_count_not_10")
        }

        qualityChecks(candidate.metrics, failed: &failed)
        compare(
            candidate.metrics.asrLatency.p50Milliseconds,
            maximum: warmASRP50MaximumMilliseconds,
            code: "asr_p50_over_1500ms",
            missingCode: "asr_p50_missing",
            ineligible: &ineligible,
            failed: &failed
        )
        compare(
            candidate.metrics.asrLatency.p95Milliseconds,
            maximum: warmASRP95MaximumMilliseconds,
            code: "asr_p95_over_3250ms",
            missingCode: "asr_p95_missing",
            ineligible: &ineligible,
            failed: &failed
        )
        rssAndNetworkChecks(candidate.metrics, failed: &failed)

        let status: GateStatus = !ineligible.isEmpty ? .ineligible : (failed.isEmpty ? .pass : .fail)
        return CandidateGateDecision(
            candidateID: candidate.candidateID,
            status: status,
            failedChecks: (ineligible + failed).sorted()
        )
    }

    private static func eligibilityChecks(
        _ metrics: CandidateMetrics,
        ineligible: inout [String]
    ) {
        if metrics.silenceSampleCount != 20 { ineligible.append("silence_sample_count_not_20") }
        if metrics.warmPeakRSSBytes <= 0 { ineligible.append("warm_peak_rss_missing") }
        if metrics.coldPeakRSSBytes <= 0 { ineligible.append("cold_peak_rss_missing") }
        if metrics.worstThermalState == .unknown { ineligible.append("thermal_state_missing") }
        for language in BenchmarkLanguage.allCases {
            guard let overall = metrics.macroWERByLanguage[language.rawValue], overall.isFinite else {
                ineligible.append("macro_wer_\(language.rawValue)_missing")
                continue
            }
            _ = overall
            if metrics.macroCERByLanguage[language.rawValue]?.isFinite != true {
                ineligible.append("macro_cer_\(language.rawValue)_missing")
            }
            for band in QualityBand.allCases {
                guard let value = metrics.macroWERByQualityBand[band.rawValue]?[language.rawValue],
                      value.isFinite else {
                    ineligible.append("macro_wer_\(band.rawValue)_\(language.rawValue)_missing")
                    continue
                }
            }
        }
    }

    private static func qualityChecks(
        _ metrics: CandidateMetrics,
        failed: inout [String]
    ) {
        for language in BenchmarkLanguage.allCases {
            if let clean = metrics.macroWERByQualityBand[QualityBand.clean.rawValue]?[language.rawValue],
               clean > cleanMacroWERMaximum {
                failed.append("clean_macro_wer_\(language.rawValue)_over_15pct")
            }
            if let noisy = metrics.macroWERByQualityBand[QualityBand.noisyMixed.rawValue]?[language.rawValue],
               noisy > noisyMixedMacroWERMaximum {
                failed.append("noisy_mixed_macro_wer_\(language.rawValue)_over_22pct")
            }
        }
        if metrics.severeOmissions != 0 { failed.append("severe_omissions_not_zero") }
        if metrics.silenceHallucinations != 0 { failed.append("silence_hallucinations_not_zero") }
    }

    private static func rssAndNetworkChecks(
        _ metrics: CandidateMetrics,
        failed: inout [String]
    ) {
        if metrics.warmPeakRSSBytes > warmPeakRSSMaximumBytes {
            failed.append("warm_peak_rss_over_4_5gb")
        }
        if metrics.coldPeakRSSBytes > coldPeakRSSMaximumBytes {
            failed.append("cold_peak_rss_over_6gb")
        }
        if metrics.runtimeNetworkConnections != 0 {
            failed.append("runtime_network_connections_not_zero")
        }
    }

    private static func compare(
        _ value: Double?,
        maximum: Double,
        code: String,
        missingCode: String,
        ineligible: inout [String],
        failed: inout [String]
    ) {
        guard let value, value.isFinite else {
            ineligible.append(missingCode)
            return
        }
        if value > maximum { failed.append(code) }
    }

    private static func fluidIsNonInferior(
        to argmax: CandidateReport,
        fluid: CandidateReport
    ) -> Bool {
        for language in BenchmarkLanguage.allCases {
            guard let fluidWER = fluid.metrics.macroWERByLanguage[language.rawValue],
                  let argmaxWER = argmax.metrics.macroWERByLanguage[language.rawValue],
                  fluidWER <= argmaxWER + fluidWERNonInferiorityMargin else {
                return false
            }
        }
        guard let fluidP50 = fluid.metrics.asrLatency.p50Milliseconds,
              let argmaxP50 = argmax.metrics.asrLatency.p50Milliseconds,
              fluidP50 <= argmaxP50 * fluidPerformanceRatioMaximum else {
            return false
        }
        return Double(fluid.metrics.warmPeakRSSBytes)
            <= Double(argmax.metrics.warmPeakRSSBytes) * fluidPerformanceRatioMaximum
    }
}
