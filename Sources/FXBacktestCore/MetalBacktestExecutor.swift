import Foundation

#if canImport(Metal)
import Metal
#endif

public struct MetalBacktestExecutor: Sendable {
    public init() {}

    public func run(
        plugin: AnyFXBacktestPlugin,
        market: OhlcDataSeries,
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
                    let runner = try MetalKernelRunner(kernel: kernel, market: market)
                    let start = ContinuousClock.now
                    let total = sweep.combinationCount
                    var completed: UInt64 = 0
                    continuation.yield(.started(totalPasses: total))

                    var lower: UInt64 = 0
                    let chunkSize = UInt64(max(1, min(settings.chunkSize, kernel.maxPassesPerCommandBuffer)))
                    while lower < total {
                        try Task.checkCancellation()
                        let upper = lower + min(chunkSize, total - lower)
                        let results = try runner.runChunk(
                            lower..<upper,
                            plugin: plugin,
                            sweep: sweep,
                            settings: settings
                        )
                        for result in results {
                            completed += 1
                            let elapsed = start.duration(to: ContinuousClock.now)
                            continuation.yield(.passCompleted(result, BacktestProgress(
                                completedPasses: completed,
                                totalPasses: total,
                                elapsedSeconds: elapsed.fxbtSeconds
                            )))
                        }
                        lower = upper
                    }

                    let elapsed = start.duration(to: ContinuousClock.now)
                    continuation.yield(.completed(BacktestProgress(
                        completedPasses: completed,
                        totalPasses: total,
                        elapsedSeconds: elapsed.fxbtSeconds
                    )))
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

#if canImport(Metal)
private struct MetalJob: Sendable {
    var combinationIndex: UInt64
    var parameterOffset: UInt32
    var parameterCount: UInt32
}

private struct MetalResultRaw: Sendable {
    var combinationIndex: UInt64 = 0
    var netProfit: Float = 0
    var grossProfit: Float = 0
    var grossLoss: Float = 0
    var maxDrawdown: Float = 0
    var totalTrades: UInt32 = 0
    var winningTrades: UInt32 = 0
    var losingTrades: UInt32 = 0
    var winRate: Float = 0
    var profitFactor: Float = 0
    var barsProcessed: UInt32 = 0
    var flags: UInt32 = 0
}

private struct MetalRunConfig: Sendable {
    var initialDeposit: Float
    var contractLots: Float
    var priceScale: Float
    var digits: UInt32
}

final class MetalKernelRunner: @unchecked Sendable {
    private let kernel: MetalKernelV1
    private let market: OhlcDataSeries
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let utcBuffer: MTLBuffer
    private let openBuffer: MTLBuffer
    private let highBuffer: MTLBuffer
    private let lowBuffer: MTLBuffer
    private let closeBuffer: MTLBuffer

    init(kernel: MetalKernelV1, market: OhlcDataSeries) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw FXBacktestError.metalUnavailable
        }
        guard let queue = device.makeCommandQueue() else {
            throw FXBacktestError.metalFailed("Could not create command queue.")
        }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: kernel.source, options: nil)
        } catch {
            throw FXBacktestError.metalFailed("Could not compile plugin Metal source: \(error)")
        }
        guard let function = library.makeFunction(name: kernel.entryPoint) else {
            throw FXBacktestError.metalFailed("Entry point \(kernel.entryPoint) was not found.")
        }
        do {
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw FXBacktestError.metalFailed("Could not create compute pipeline: \(error)")
        }
        self.kernel = kernel
        self.market = market
        self.device = device
        self.queue = queue
        self.utcBuffer = try Self.makeBuffer(market.utcTimestamps, label: "fxbacktest.utc", device: device)
        self.openBuffer = try Self.makeBuffer(market.open, label: "fxbacktest.open", device: device)
        self.highBuffer = try Self.makeBuffer(market.high, label: "fxbacktest.high", device: device)
        self.lowBuffer = try Self.makeBuffer(market.low, label: "fxbacktest.low", device: device)
        self.closeBuffer = try Self.makeBuffer(market.close, label: "fxbacktest.close", device: device)
    }

    func runChunk(
        _ range: Range<UInt64>,
        plugin: AnyFXBacktestPlugin,
        sweep: ParameterSweep,
        settings: BacktestRunSettings
    ) throws -> [BacktestPassResult] {
        let jobCount = Int(range.upperBound - range.lowerBound)
        var jobs: [MetalJob] = []
        var flattenedParameters: [Float] = []
        var vectors: [ParameterVector] = []
        jobs.reserveCapacity(jobCount)
        vectors.reserveCapacity(jobCount)

        for combinationIndex in range {
            let vector = try sweep.parameterVector(at: combinationIndex)
            let offset = flattenedParameters.count
            flattenedParameters.append(contentsOf: vector.values.map { Float($0) })
            jobs.append(MetalJob(
                combinationIndex: combinationIndex,
                parameterOffset: UInt32(offset),
                parameterCount: UInt32(vector.values.count)
            ))
            vectors.append(vector)
        }

        var rawResults = Array(repeating: MetalResultRaw(), count: jobCount)
        var runConfig = MetalRunConfig(
            initialDeposit: Float(settings.initialDeposit),
            contractLots: Float(settings.contractSize * settings.lotSize),
            priceScale: Float(pow(10.0, Double(market.metadata.digits))),
            digits: UInt32(max(0, market.metadata.digits))
        )
        guard let jobBuffer = device.makeBuffer(bytes: jobs, length: max(1, jobs.count * MemoryLayout<MetalJob>.stride), options: [.storageModeShared]),
              let parameterBuffer = device.makeBuffer(bytes: flattenedParameters, length: max(1, flattenedParameters.count * MemoryLayout<Float>.stride), options: [.storageModeShared]),
              let resultBuffer = device.makeBuffer(length: max(1, rawResults.count * MemoryLayout<MetalResultRaw>.stride), options: [.storageModeShared]) else {
            throw FXBacktestError.metalFailed("Could not allocate job/result buffers.")
        }
        jobBuffer.label = "fxbacktest.jobs"
        parameterBuffer.label = "fxbacktest.parameters"
        resultBuffer.label = "fxbacktest.results"

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw FXBacktestError.metalFailed("Could not create command encoder.")
        }

        var barCount = UInt32(market.count)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(utcBuffer, offset: 0, index: 0)
        encoder.setBuffer(openBuffer, offset: 0, index: 1)
        encoder.setBuffer(highBuffer, offset: 0, index: 2)
        encoder.setBuffer(lowBuffer, offset: 0, index: 3)
        encoder.setBuffer(closeBuffer, offset: 0, index: 4)
        encoder.setBytes(&barCount, length: MemoryLayout<UInt32>.stride, index: 5)
        encoder.setBuffer(jobBuffer, offset: 0, index: 6)
        encoder.setBuffer(parameterBuffer, offset: 0, index: 7)
        encoder.setBuffer(resultBuffer, offset: 0, index: 8)
        encoder.setBytes(&runConfig, length: MemoryLayout<MetalRunConfig>.stride, index: 9)

        let threadgroupWidth = max(1, min(pipeline.maxTotalThreadsPerThreadgroup, max(pipeline.threadExecutionWidth, 1)))
        encoder.dispatchThreads(
            MTLSize(width: jobCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadgroupWidth, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw FXBacktestError.metalFailed("Command buffer failed: \(error)")
        }

        let resultPointer = resultBuffer.contents().bindMemory(to: MetalResultRaw.self, capacity: rawResults.count)
        rawResults = Array(UnsafeBufferPointer(start: resultPointer, count: rawResults.count))

        return rawResults.enumerated().map { index, raw in
            let vector = vectors[index]
            return BacktestPassResult(
                passIndex: raw.combinationIndex,
                pluginIdentifier: plugin.descriptor.id,
                engine: .metal,
                parameters: vector.snapshots,
                netProfit: Double(raw.netProfit),
                grossProfit: Double(raw.grossProfit),
                grossLoss: Double(raw.grossLoss),
                maxDrawdown: Double(raw.maxDrawdown),
                totalTrades: Int(raw.totalTrades),
                winningTrades: Int(raw.winningTrades),
                losingTrades: Int(raw.losingTrades),
                winRate: Double(raw.winRate),
                profitFactor: Double(raw.profitFactor),
                barsProcessed: Int(raw.barsProcessed),
                flags: raw.flags,
                errorMessage: nil
            )
        }
    }

    private static func makeBuffer(_ values: ContiguousArray<Int64>, label: String, device: MTLDevice) throws -> MTLBuffer {
        let byteCount = max(1, values.count * MemoryLayout<Int64>.stride)
        guard let buffer = device.makeBuffer(length: byteCount, options: [.storageModeShared]) else {
            throw FXBacktestError.metalFailed("Could not allocate \(label).")
        }
        buffer.label = label
        if !values.isEmpty {
            try values.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    throw FXBacktestError.metalFailed("Could not read \(label) source bytes.")
                }
                buffer.contents().copyMemory(from: baseAddress, byteCount: bytes.count)
            }
        }
        return buffer
    }
}
#endif
