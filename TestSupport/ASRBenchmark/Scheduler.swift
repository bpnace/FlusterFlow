import Foundation

public enum RunScheduler {
    public static let algorithm = "splitmix64-fisher-yates-v1"

    public static func make(
        manifest: CorpusManifest,
        candidateIDs: [String],
        seed: UInt64,
        warmupRunsPerCandidate: Int
    ) -> RandomizedSchedule {
        let candidates = candidateIDs.sorted()
        let measuredClips = manifest.clips.map(\.id).sorted()
        let performanceClips = manifest.clips
            .filter { $0.kind == .speech && $0.isPerformanceSample }
            .map(\.id)
            .sorted()

        var random = SplitMix64(seed: seed)
        var warmup: [(String, String, TrialPhase)] = []
        for candidate in candidates {
            var pool = performanceClips
            pool.deterministicShuffle(using: &random)
            guard !pool.isEmpty else { continue }
            for index in 0..<warmupRunsPerCandidate {
                warmup.append((candidate, pool[index % pool.count], .warmup))
            }
        }
        warmup.deterministicShuffle(using: &random)

        var measured: [(String, String, TrialPhase)] = candidates.flatMap { candidate in
            measuredClips.map { (candidate, $0, TrialPhase.measured) }
        }
        measured.deterministicShuffle(using: &random)

        let trials = (warmup + measured).enumerated().map { offset, trial in
            ScheduledTrial(
                ordinal: offset,
                candidateID: trial.0,
                clipID: trial.1,
                phase: trial.2
            )
        }
        return RandomizedSchedule(
            algorithm: algorithm,
            seed: seed,
            warmupRunsPerCandidate: warmupRunsPerCandidate,
            trials: trials
        )
    }
}

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}

private extension Array {
    mutating func deterministicShuffle<R: RandomNumberGenerator>(using generator: inout R) {
        guard count > 1 else { return }
        for index in stride(from: count - 1, through: 1, by: -1) {
            let offset = Int(generator.next() % UInt64(index + 1))
            if index != offset {
                swapAt(index, offset)
            }
        }
    }
}
