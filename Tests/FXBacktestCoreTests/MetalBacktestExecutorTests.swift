import FXBacktestCore
import FXBacktestPlugins
import XCTest

#if canImport(Metal)
import Metal
#endif

final class MetalBacktestExecutorTests: XCTestCase {
    func testMovingAverageCrossAdvertisesMetalSupport() {
        let plugin = MovingAverageCrossPlugin()

        XCTAssertTrue(plugin.descriptor.supportsMetal)
        XCTAssertNotNil(plugin.metalKernel)
    }

    func testMetalExecutorCompilesPluginKernelAndRunsPassesWhenAvailable() async throws {
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
                maximum: max($0.defaultValue, $0.defaultMinimum + $0.defaultStep)
            )
        })
        let settings = BacktestRunSettings(target: .metal, maxWorkers: 1, chunkSize: 4)

        var passResults: [BacktestPassResult] = []
        for try await event in MetalBacktestExecutor().run(plugin: plugin, market: market, sweep: sweep, settings: settings) {
            if case .passCompleted(let result, _) = event {
                passResults.append(result)
            }
        }

        XCTAssertEqual(passResults.count, Int(sweep.combinationCount))
        XCTAssertTrue(passResults.allSatisfy { $0.engine == .metal })
        XCTAssertTrue(passResults.allSatisfy { $0.barsProcessed == market.count })
        #else
        throw XCTSkip("This toolchain cannot import Metal.")
        #endif
    }
}
