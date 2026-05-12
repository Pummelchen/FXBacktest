import FXBacktestCore
import XCTest

final class ExecutionModelTests: XCTestCase {
    func testBacktestBrokerV2AppliesSpreadCommissionAndLedger() throws {
        let spec = try FXBacktestSymbolExecutionSpec(
            logicalSymbol: "EURUSD",
            digits: 5,
            contractSize: 100_000,
            spreadPoints: 10,
            commissionPerLotPerSide: 3.5,
            marginRate: 0.01
        )
        let profile = try FXBacktestExecutionProfile(symbols: ["EURUSD": spec])
        let settings = BacktestRunSettings(
            initialDeposit: 10_000,
            contractSize: 100_000,
            lotSize: 1,
            executionProfile: profile
        )
        let context = BacktestContext(settings: settings, digits: 5)
        var broker = BacktestBrokerV2(context: context)

        let positionID = try broker.openMarket(symbol: "EURUSD", side: .buy, midPrice: 100_000, lots: 1, openedAtUtc: 1)
        XCTAssertEqual(broker.positions.first?.entryPrice, 100_005)
        XCTAssertEqual(broker.balance, 9_996.5, accuracy: 0.0001)

        try broker.closePosition(id: positionID, midPrice: 101_000, closedAtUtc: 2)

        XCTAssertEqual(broker.positions.count, 0)
        XCTAssertEqual(broker.totalTrades, 1)
        XCTAssertEqual(broker.ledger.count, 1)
        XCTAssertEqual(broker.ledger[0].exitPrice, 100_995)
        XCTAssertEqual(broker.ledger[0].netProfit, 983.0, accuracy: 0.0001)
        XCTAssertEqual(broker.netProfit, 983.0, accuracy: 0.0001)
    }
}
