import FXBacktestCore
import FXBacktestPlugins
import XCTest

final class BacktestResultStoreTests: XCTestCase {
    func testClickHouseResultStoreUsesFXBacktestTablesAndPurgeAPI() async throws {
        let executor = RecordingClickHouseExecutor()
        let config = FXBacktestClickHouseConfiguration(database: "fxbacktest_test")
        let store = ClickHouseBacktestResultStore(configuration: config, executor: executor)
        let plugin = MovingAverageCrossPlugin()
        let sweep = try ParameterSweep.singlePass(definitions: plugin.parameterDefinitions)
        let run = BacktestStoredRun(
            runID: "test-run",
            pluginIdentifier: plugin.descriptor.id,
            engine: .cpu,
            brokerSourceId: "demo",
            primarySymbol: "EURUSD",
            symbols: ["EURUSD"],
            settings: BacktestRunSettings(),
            sweep: sweep,
            note: "unit"
        )
        let result = BacktestPassResult(
            passIndex: 0,
            pluginIdentifier: plugin.descriptor.id,
            engine: .cpu,
            parameters: [BacktestParameterValue(key: "fast_period", value: 8)],
            netProfit: 12,
            grossProfit: 20,
            grossLoss: -8,
            maxDrawdown: 3,
            totalTrades: 2,
            winningTrades: 1,
            losingTrades: 1,
            winRate: 0.5,
            profitFactor: 2.5,
            barsProcessed: 100
        )

        try await store.startRun(run)
        try await store.appendResults([result], runID: run.runID)
        try await store.completeRun(runID: run.runID, progress: BacktestProgress(completedPasses: 1, totalPasses: 1, elapsedSeconds: 0.1), status: "completed")
        _ = try await store.purge(olderThanDays: 30)

        let statements = await executor.statements()
        XCTAssertTrue(statements.contains { $0.contains("CREATE DATABASE IF NOT EXISTS `fxbacktest_test`") })
        XCTAssertTrue(statements.contains { $0.contains("fxbacktest_runs") })
        XCTAssertTrue(statements.contains { $0.contains("fxbacktest_pass_results") && $0.contains("FORMAT JSONEachRow") })
        XCTAssertTrue(statements.contains { $0.contains("DELETE WHERE inserted_at < now() - INTERVAL 30 DAY") })
    }
}

private actor RecordingClickHouseExecutor: FXBacktestClickHouseExecuting {
    private var recordedStatements: [String] = []

    @discardableResult
    func execute(_ sql: String, configuration: FXBacktestClickHouseConfiguration) async throws -> String {
        recordedStatements.append(sql)
        return ""
    }

    func statements() -> [String] {
        recordedStatements
    }
}
