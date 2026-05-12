import Foundation

public struct CPUBacktestExecutor: Sendable {
    public init() {}

    public func run(
        plugin: AnyFXBacktestPlugin,
        market: OhlcDataSeries,
        sweep: ParameterSweep,
        settings: BacktestRunSettings
    ) -> AsyncThrowingStream<BacktestOptimizationEvent, Error> {
        run(plugin: plugin, marketUniverse: market.universe, sweep: sweep, settings: settings)
    }

    public func run(
        plugin: AnyFXBacktestPlugin,
        marketUniverse: OhlcMarketUniverse,
        sweep: ParameterSweep,
        settings: BacktestRunSettings
    ) -> AsyncThrowingStream<BacktestOptimizationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let start = ContinuousClock.now
                var completed: UInt64 = 0
                let total = sweep.combinationCount
                continuation.yield(.started(totalPasses: total))

                do {
                    let workerCount = min(settings.maxWorkers, max(1, Int(min(total, UInt64(Int.max)))))
                    let chunkSize = max(1, settings.chunkSize)
                    var nextStart: UInt64 = 0

                    try await withThrowingTaskGroup(of: [BacktestPassResult].self) { group in
                        func enqueueNextChunk() {
                            guard nextStart < total else { return }
                            let lower = nextStart
                            let upper = lower + min(UInt64(chunkSize), total - lower)
                            nextStart = upper
                            group.addTask {
                                try Self.computeChunk(
                                    lower..<upper,
                                    plugin: plugin,
                                    marketUniverse: marketUniverse,
                                    sweep: sweep,
                                    settings: settings
                                )
                            }
                        }

                        for _ in 0..<workerCount {
                            enqueueNextChunk()
                        }

                        while let batch = try await group.next() {
                            for result in batch {
                                completed += 1
                                let elapsed = start.duration(to: ContinuousClock.now)
                                let progress = BacktestProgress(
                                    completedPasses: completed,
                                    totalPasses: total,
                                    elapsedSeconds: elapsed.fxbtSeconds
                                )
                                continuation.yield(.passCompleted(result, progress))
                            }
                            enqueueNextChunk()
                        }
                    }

                    let elapsed = start.duration(to: ContinuousClock.now)
                    continuation.yield(.completed(BacktestProgress(
                        completedPasses: completed,
                        totalPasses: total,
                        elapsedSeconds: elapsed.fxbtSeconds
                    )))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    static func computeChunk(
        _ range: Range<UInt64>,
        plugin: AnyFXBacktestPlugin,
        marketUniverse: OhlcMarketUniverse,
        sweep: ParameterSweep,
        settings: BacktestRunSettings
    ) throws -> [BacktestPassResult] {
        let market = marketUniverse.primary
        let context = BacktestContext(settings: settings, digits: market.metadata.digits)
        var results: [BacktestPassResult] = []
        results.reserveCapacity(Int(range.upperBound - range.lowerBound))

        for combinationIndex in range {
            try Task.checkCancellation()
            let vector = try sweep.parameterVector(at: combinationIndex)
            do {
                let result = try plugin
                    .runPass(marketUniverse: marketUniverse, parameters: vector, context: context)
                    .withEngine(.cpu)
                results.append(result)
            } catch {
                results.append(BacktestPassResult(
                    passIndex: combinationIndex,
                    pluginIdentifier: plugin.descriptor.id,
                    engine: .cpu,
                    parameters: vector.snapshots,
                    netProfit: 0,
                    grossProfit: 0,
                    grossLoss: 0,
                    maxDrawdown: 0,
                    totalTrades: 0,
                    winningTrades: 0,
                    losingTrades: 0,
                    winRate: 0,
                    profitFactor: 0,
                    barsProcessed: 0,
                    flags: 1,
                    errorMessage: String(describing: error)
                ))
            }
        }

        return results
    }
}
