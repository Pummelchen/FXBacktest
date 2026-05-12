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
        XCTAssertEqual(series.metadata.digits, 5)
        XCTAssertEqual(series.open[0], 108_000)
        XCTAssertEqual(series.close[1], 108_020)
    }
}
