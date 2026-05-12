import FXBacktestAPI
import FXBacktestCore
import XCTest

final class FXExportAPIDataSeriesTests: XCTestCase {
    func testOhlcDataSeriesBuildsFromFXExportAPIResponse() throws {
        let response = FXBacktestM1HistoryResponse(
            metadata: FXBacktestM1HistoryMetadata(
                brokerSourceId: "demo",
                logicalSymbol: "EURUSD",
                mt5Symbol: "EURUSD",
                digits: 5,
                requestedUtcStart: 1_704_067_200,
                requestedUtcEndExclusive: 1_704_067_320,
                firstUtc: 1_704_067_200,
                lastUtc: 1_704_067_260,
                rowCount: 2
            ),
            utcTimestamps: [1_704_067_200, 1_704_067_260],
            open: [108_000, 108_010],
            high: [108_020, 108_030],
            low: [107_990, 108_000],
            close: [108_010, 108_020]
        )

        let series = try OhlcDataSeries(response: response)

        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(series.metadata.brokerSourceId, "demo")
        XCTAssertEqual(series.metadata.logicalSymbol, "EURUSD")
        XCTAssertEqual(series.metadata.mt5Symbol, "EURUSD")
        XCTAssertEqual(series.metadata.digits, 5)
        XCTAssertEqual(series.open[0], 108_000)
        XCTAssertEqual(series.close[1], 108_020)
    }

    func testOhlcDataSeriesRejectsInvalidDigits() throws {
        XCTAssertThrowsError(try OhlcDataSeries(
            metadata: FXBacktestMarketMetadata(
                brokerSourceId: "demo",
                logicalSymbol: "EURUSD",
                digits: -1
            ),
            utcTimestamps: [1_704_067_200],
            open: [108_000],
            high: [108_010],
            low: [107_990],
            close: [108_005]
        ))
    }

    func testExecutionProfileBuildsFromFXExportExecutionSpecResponse() throws {
        let response = FXBacktestExecutionSpecResponse(
            brokerSourceId: "demo",
            capturedAtUtc: 1_704_067_200,
            accountCurrency: "USD",
            accountLeverage: 100,
            accountMode: "hedging",
            mt5AccountMarginMode: 2,
            symbols: [
                FXBacktestExecutionSymbolSpec(
                    logicalSymbol: "EURUSD",
                    mt5Symbol: "EURUSD",
                    selected: true,
                    digits: 5,
                    bid: 1.08000,
                    ask: 1.08012,
                    point: 0.00001,
                    spreadPoints: 12,
                    spreadFloat: true,
                    contractSize: 100_000,
                    volumeMin: 0.01,
                    volumeStep: 0.01,
                    volumeMax: 100,
                    swapLongPerLot: -6.2,
                    swapShortPerLot: 1.4,
                    swapMode: 1,
                    marginInitialPerLot: nil,
                    marginMaintenancePerLot: nil,
                    marginBuyPerLot: 1_080,
                    marginSellPerLot: 1_079,
                    marginCalcLots: 1,
                    tradeCalcMode: 0,
                    tradeMode: 4,
                    tickSize: 0.00001,
                    tickValue: 1,
                    tickValueProfit: 1,
                    tickValueLoss: 1,
                    commissionPerLotPerSide: nil,
                    commissionSource: "not_exposed_by_mt5_symbol_info",
                    slippagePoints: 0,
                    slippageSource: "deterministic_zero_default"
                )
            ]
        )

        let profile = try FXExportExecutionLoader.executionProfile(from: response)
        let spec = try XCTUnwrap(profile.symbols["EURUSD"])

        XCTAssertEqual(profile.accountingMode, .hedging)
        XCTAssertEqual(spec.spreadPoints, 12)
        XCTAssertEqual(spec.marginInitialPerLot, 1_080)
        XCTAssertEqual(spec.marginRate, 0.01, accuracy: 0.000_000_1)
        XCTAssertEqual(spec.commissionPerLotPerSide, 0)
        XCTAssertEqual(spec.commissionSource, "not_exposed_by_mt5_symbol_info")
        XCTAssertEqual(spec.bid, 1.08000)
        XCTAssertEqual(spec.ask, 1.08012)
    }
}
