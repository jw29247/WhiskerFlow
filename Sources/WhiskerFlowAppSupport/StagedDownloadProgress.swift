import Foundation

/// Folds a sequence of per-operation progress reports into one monotonic
/// overall fraction.
///
/// FluidAudio reports each model file's download-and-compile as its own
/// operation that restarts at 0, so a raw progress bar would fill four times.
/// Each operation is a stage with a weight (roughly its share of the bytes and
/// time); a report that restarts marks the next stage.
public struct StagedDownloadProgress: Equatable, Sendable {
    public let stageWeights: [Double]
    public private(set) var stage = 0
    private var stageFraction: Double = 0
    public private(set) var overall: Double = 0
    public private(set) var isFinished = false

    /// Below this the overall value never reads "done" until `finish()`: the
    /// last stage can report 1.0 before the model is actually usable.
    public static let unfinishedCeiling = 0.99

    public init(stageWeights: [Double]) {
        let positive = stageWeights.map { max(0, $0) }
        let total = positive.reduce(0, +)
        self.stageWeights = total > 0 ? positive.map { $0 / total } : [1]
    }

    /// Parakeet TDT v3 (int8) on first run: four files are downloaded and
    /// compiled (weighted by their on-disk size: preprocessor 0.5 MB, encoder
    /// 425 MB, decoder 23 MB, joint 12 MB), then the four are loaded.
    public static let parakeetFirstDownload = StagedDownloadProgress(
        stageWeights: [0.5, 425, 23, 12, 10, 10, 10, 10]
    )
    /// Already on disk: only the four loads report.
    public static let parakeetCachedLoad = StagedDownloadProgress(stageWeights: [1, 1, 1, 1])

    /// Approximate first-run download size, for the setup screen.
    public static let parakeetDownloadBytes: Int64 = 483_000_000

    /// - Parameter startsNewOperation: the report opens a new operation
    ///   (FluidAudio's listing phase). A fraction that drops is also a restart.
    public mutating func ingest(fraction rawFraction: Double, startsNewOperation: Bool = false) {
        guard !isFinished else { return }
        let fraction = min(max(rawFraction, 0), 1)
        let restarted = startsNewOperation ? stageFraction > 0 : fraction + 0.05 < stageFraction
        if restarted, stage < stageWeights.count - 1 {
            stage += 1
            stageFraction = 0
        }
        stageFraction = max(stageFraction, fraction)
        let completed = stageWeights.prefix(stage).reduce(0, +)
        let value = completed + stageWeights[stage] * stageFraction
        overall = max(overall, min(value, Self.unfinishedCeiling))
    }

    public mutating func finish() {
        isFinished = true
        overall = 1
    }
}
