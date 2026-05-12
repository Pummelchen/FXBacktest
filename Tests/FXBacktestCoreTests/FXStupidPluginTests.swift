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
        let market = try monotonicMarket()
        let sweep = try ParameterSweep.singlePass(definitions: plugin.parameterDefinitions)
        let parameters = try sweep.parameterVector(at: 0)
        let context = BacktestContext(settings: BacktestRunSettings(), digits: market.metadata.digits)

        let result = try plugin.runPass(market: market, parameters: parameters, context: context)

        XCTAssertEqual(result.pluginIdentifier, plugin.descriptor.id)
        XCTAssertEqual(result.barsProcessed, market.count)
        XCTAssertGreaterThan(result.totalTrades, 0)
        XCTAssertGreaterThan(result.netProfit, 0)
    }

    private func monotonicMarket() throws -> OhlcDataSeries {
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
                logicalSymbol: "EURUSD",
                digits: 5,
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
