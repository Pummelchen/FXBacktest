import Foundation

public struct HybridBacktestExecutor: Sendable {
    public init() {}

    public func run(
        plugin: AnyFXBacktestPlugin,
        marketUniverse: OhlcMarketUniverse,
        sweep: ParameterSweep,
        settings: BacktestRunSettings
    ) -> AsyncThrowingStream<BacktestOptimizationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    #if canImport(Metal)
                    guard let kernel = plugin.metalKernel else {
                        throw FXBacktestError.metalKernelMissing(plugin: plugin.descriptor.displayName)
                    }

                    let total = sweep.combinationCount
                    let start = ContinuousClock.now
                    let allocator = HybridBacktestWorkAllocator(totalPasses: total)
                    let emitter = HybridBacktestResultEmitter(
                        totalPasses: total,
                        start: start,
                        continuation: continuation
                    )
                    let cpuSettings = settings.retargeted(.cpu)
                    let metalSettings = settings.retargeted(.metal)
                    let runner = try MetalKernelRunner(kernel: kernel, market: marketUniverse.primary)
                    let cpuChunkSize = UInt64(max(1, settings.chunkSize))
                    let metalChunkSize = UInt64(max(1, min(settings.chunkSize, kernel.maxPassesPerCommandBuffer)))
                    let workerCount = min(settings.maxWorkers, max(1, Int(min(total, UInt64(Int.max)))))
                    let metalBootstrapSize = total > 1 ? min(metalChunkSize, max(1, total / 2)) : metalChunkSize
                    let firstMetalRange = await allocator.nextRange(maxSize: metalBootstrapSize)
                    let remainingAfterMetal: UInt64
                    if let firstMetalRange {
                        remainingAfterMetal = total - (firstMetalRange.upperBound - firstMetalRange.lowerBound)
                    } else {
                        remainingAfterMetal = 0
                    }
                    let cpuBootstrapSize = remainingAfterMetal > 0 ? min(cpuChunkSize, remainingAfterMetal) : cpuChunkSize
                    let firstCPURange = await allocator.nextRange(maxSize: cpuBootstrapSize)

                    continuation.yield(.started(totalPasses: total))

                    func runMetalRange(_ range: Range<UInt64>) async throws {
                        let results = try runner.runChunk(
                            range,
                            plugin: plugin,
                            sweep: sweep,
                            settings: metalSettings
                        )
                        await emitter.emit(results)
                    }

                    func runCPURange(_ range: Range<UInt64>) async throws {
                        let results = try CPUBacktestExecutor.computeChunk(
                            range,
                            plugin: plugin,
                            marketUniverse: marketUniverse,
                            sweep: sweep,
                            settings: cpuSettings
                        )
                        await emitter.emit(results)
                    }

                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            if let firstMetalRange {
                                try Task.checkCancellation()
                                try await runMetalRange(firstMetalRange)
                            }
                            while let range = await allocator.nextRange(maxSize: metalChunkSize) {
                                try Task.checkCancellation()
                                try await runMetalRange(range)
                                await Task.yield()
                            }
                        }

                        for workerIndex in 0..<workerCount {
                            group.addTask {
                                if workerIndex == 0, let firstCPURange {
                                    try Task.checkCancellation()
                                    try await runCPURange(firstCPURange)
                                }
                                while let range = await allocator.nextRange(maxSize: cpuChunkSize) {
                                    try Task.checkCancellation()
                                    try await runCPURange(range)
                                    await Task.yield()
                                }
                            }
                        }

                        try await group.waitForAll()
                    }

                    let finalProgress = await emitter.snapshot()
                    continuation.yield(.completed(finalProgress))
                    continuation.finish()
                    #else
                    throw FXBacktestError.metalUnavailable
                    #endif
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private actor HybridBacktestWorkAllocator {
    private let totalPasses: UInt64
    private var nextPass: UInt64 = 0

    init(totalPasses: UInt64) {
        self.totalPasses = totalPasses
    }

    func nextRange(maxSize: UInt64) -> Range<UInt64>? {
        guard nextPass < totalPasses else { return nil }
        let lower = nextPass
        let upper = lower + min(max(1, maxSize), totalPasses - lower)
        nextPass = upper
        return lower..<upper
    }
}

private actor HybridBacktestResultEmitter {
    private var completedPasses: UInt64 = 0
    private let totalPasses: UInt64
    private let start: ContinuousClock.Instant
    private let continuation: AsyncThrowingStream<BacktestOptimizationEvent, Error>.Continuation

    init(
        totalPasses: UInt64,
        start: ContinuousClock.Instant,
        continuation: AsyncThrowingStream<BacktestOptimizationEvent, Error>.Continuation
    ) {
        self.totalPasses = totalPasses
        self.start = start
        self.continuation = continuation
    }

    func emit(_ results: [BacktestPassResult]) {
        for result in results {
            completedPasses += 1
            continuation.yield(.passCompleted(result, snapshot()))
        }
    }

    func snapshot() -> BacktestProgress {
        let elapsed = start.duration(to: ContinuousClock.now)
        return BacktestProgress(
            completedPasses: completedPasses,
            totalPasses: totalPasses,
            elapsedSeconds: elapsed.fxbtSeconds
        )
    }
}

private extension BacktestRunSettings {
    func retargeted(_ target: BacktestExecutionTarget) -> BacktestRunSettings {
        var copy = self
        copy.target = target
        return copy
    }
}
