import FXBacktestCore
import XCTest

final class MarketUniverseTests: XCTestCase {
    func testMarketUniverseRequiresAlignedTimestamps() throws {
        let eurusd = try market(symbol: "EURUSD", offset: 0)
        let usdjpy = try market(symbol: "USDJPY", offset: 0, digits: 3)

        let universe = try OhlcMarketUniverse(primarySymbol: "EURUSD", series: [usdjpy, eurusd])

        XCTAssertEqual(universe.primarySymbol, "EURUSD")
        XCTAssertEqual(universe.symbols, ["EURUSD", "USDJPY"])
        XCTAssertEqual(universe.primary.count, eurusd.count)
        XCTAssertEqual(universe.digitsBySymbol()["USDJPY"], 3)
    }

    func testMarketUniverseRejectsTimestampMismatch() throws {
        let eurusd = try market(symbol: "EURUSD", offset: 0)
        let shifted = try market(symbol: "USDJPY", offset: 60, digits: 3)

        XCTAssertThrowsError(try OhlcMarketUniverse(primarySymbol: "EURUSD", series: [eurusd, shifted]))
    }

    private func market(symbol: String, offset: Int64, digits: Int = 5) throws -> OhlcDataSeries {
        let start = Int64(1_704_067_200) + offset
        let utc = ContiguousArray((0..<5).map { start + Int64($0 * 60) })
        let close = ContiguousArray((0..<5).map { Int64(100_000 + $0 * 10) })
        return try OhlcDataSeries(
            metadata: FXBacktestMarketMetadata(
                brokerSourceId: "demo",
                logicalSymbol: symbol,
                digits: digits,
                firstUtc: utc.first,
                lastUtc: utc.last
            ),
            utcTimestamps: utc,
            open: close,
            high: ContiguousArray(close.map { $0 + 5 }),
            low: ContiguousArray(close.map { $0 - 5 }),
            close: close
        )
    }
}
