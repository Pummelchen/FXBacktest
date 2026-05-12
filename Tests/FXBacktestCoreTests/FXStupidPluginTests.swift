import FXBacktestCore
import FXBacktestPlugins
import XCTest

final class FXStupidPluginTests: XCTestCase {
    func testFXStupidConfigLoadsAndPluginIsRegistered() throws {
        let plugin = FXStupid()

        XCTAssertEqual(plugin.descriptor.displayName, "FXStupid")
        XCTAssertEqual(plugin.parameterDefinitions.map(\.key), [
            "MaxOrders",
            "BarsLookBack",
            "TrailStop",
            "TrailStepUp",
            "TrailStepDown",
            "LotSize",
            "EAEqui_TP",
            "EAEqui_SL",
            "LotBooster",
            "EAStopMaxDD",
            "EAStopMinEqui"
        ])
        XCTAssertTrue(FXBacktestPluginRegistry.availablePlugins.contains { $0.descriptor.displayName == "FXStupid" })
    }

    func testFXStupidRunsMonotonicEURUSDFlow() throws {
        let plugin = FXStupid()
        let market = try monotonicMarket(symbol: "EURUSD")
        let sweep = try ParameterSweep.singlePass(definitions: plugin.parameterDefinitions)
        let parameters = try sweep.parameterVector(at: 0)
        let context = BacktestContext(settings: BacktestRunSettings(), digits: market.metadata.digits)

        let result = try plugin.runPass(market: market, parameters: parameters, context: context)

        XCTAssertEqual(result.pluginIdentifier, plugin.descriptor.id)
        XCTAssertEqual(result.barsProcessed, market.count)
        XCTAssertGreaterThan(result.totalTrades, 0)
        XCTAssertGreaterThan(result.netProfit, 0)
    }

    func testFXStupidUsesLoadedMultiSymbolUniverse() throws {
        let plugin = FXStupid()
        let eurusd = try monotonicMarket(symbol: "EURUSD")
        let usdjpy = try monotonicMarket(symbol: "USDJPY", digits: 3)
        let universe = try OhlcMarketUniverse(primarySymbol: "EURUSD", series: [eurusd, usdjpy])
        let sweep = try ParameterSweep.singlePass(definitions: plugin.parameterDefinitions)
        let parameters = try sweep.parameterVector(at: 0)
        let context = BacktestContext(settings: BacktestRunSettings(), digits: eurusd.metadata.digits)

        let result = try plugin.runPass(marketUniverse: universe, parameters: parameters, context: context)

        XCTAssertEqual(result.barsProcessed, universe.count)
        XCTAssertGreaterThanOrEqual(result.totalTrades, 2)
    }

    func testFXStupidAppliesExecutionProfileCosts() throws {
        let plugin = FXStupid()
        let market = try monotonicMarket(symbol: "EURUSD")
        let sweep = try ParameterSweep.singlePass(definitions: plugin.parameterDefinitions)
        let parameters = try sweep.parameterVector(at: 0)
        let zeroCostContext = BacktestContext(settings: BacktestRunSettings(), digits: market.metadata.digits)

        let costlySpec = try FXBacktestSymbolExecutionSpec(
            logicalSymbol: "EURUSD",
            mt5Symbol: "EURUSD",
            digits: 5,
            contractSize: 100_000,
            spreadPoints: 20,
            commissionPerLotPerSide: 1,
            commissionSource: "test",
            slippageSource: "test"
        )
        let costlyProfile = try FXBacktestExecutionProfile(symbols: ["EURUSD": costlySpec])
        let costlySettings = BacktestRunSettings(executionProfile: costlyProfile)
        let costlyContext = BacktestContext(settings: costlySettings, digits: market.metadata.digits)

        let zeroCostResult = try plugin.runPass(market: market, parameters: parameters, context: zeroCostContext)
        let costlyResult = try plugin.runPass(market: market, parameters: parameters, context: costlyContext)

        XCTAssertLessThan(costlyResult.netProfit, zeroCostResult.netProfit)
    }

    private func monotonicMarket(symbol: String, digits: Int = 5) throws -> OhlcDataSeries {
        let count = 80
        let start = Int64(1_704_067_200)
        var utc = ContiguousArray<Int64>()
        var open = ContiguousArray<Int64>()
        var high = ContiguousArray<Int64>()
        var low = ContiguousArray<Int64>()
        var close = ContiguousArray<Int64>()

        for index in 0..<count {
            let price = Int64(108_000 + index * 10)
            utc.append(start + Int64(index * 60))
            open.append(price)
            high.append(price + 4)
            low.append(price - 4)
            close.append(price)
        }

        return try OhlcDataSeries(
            metadata: FXBacktestMarketMetadata(
                brokerSourceId: "demo",
                logicalSymbol: symbol,
                digits: digits,
                firstUtc: utc.first,
                lastUtc: utc.last
            ),
            utcTimestamps: utc,
            open: open,
            high: high,
            low: low,
            close: close
        )
    }
}
