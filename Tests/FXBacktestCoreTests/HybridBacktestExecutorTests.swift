import FXBacktestCore
import FXBacktestPlugins
import XCTest

#if canImport(Metal)
import Metal
#endif

final class HybridBacktestExecutorTests: XCTestCase {
    func testHybridExecutorRunsEachPassOnceAcrossCPUAndMetal() async throws {
        #if canImport(Metal)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this machine.")
        }

        let market = try OhlcDataSeries.demoEURUSD(barCount: 500)
        let plugin = AnyFXBacktestPlugin(MovingAverageCrossPlugin())
        let sweep = try ParameterSweep(dimensions: plugin.parameterDefinitions.map {
            try ParameterSweepDimension(
                definition: $0,
                input: $0.defaultValue,
                minimum: $0.defaultMinimum,
                step: $0.defaultStep,
                maximum: $0.defaultMaximum
            )
        })
        let settings = BacktestRunSettings(target: .both, maxWorkers: 2, chunkSize: 8)

        var passResults: [BacktestPassResult] = []
        var completed: BacktestProgress?
        for try await event in HybridBacktestExecutor().run(plugin: plugin, marketUniverse: market.universe, sweep: sweep, settings: settings) {
            switch event {
            case .started:
                break
            case .passCompleted(let result, _):
                passResults.append(result)
            case .completed(let progress):
                completed = progress
            }
        }

        XCTAssertEqual(passResults.count, Int(sweep.combinationCount))
        XCTAssertEqual(Set(passResults.map(\.passIndex)).count, Int(sweep.combinationCount))
        XCTAssertEqual(completed?.completedPasses, sweep.combinationCount)
        XCTAssertTrue(passResults.contains { $0.engine == .cpu })
        XCTAssertTrue(passResults.contains { $0.engine == .metal })
        XCTAssertFalse(passResults.contains { $0.engine == .both })
        #else
        throw XCTSkip("This toolchain cannot import Metal.")
        #endif
    }
}
