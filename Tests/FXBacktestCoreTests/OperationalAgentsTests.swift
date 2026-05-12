import FXBacktestCore
import FXBacktestAPI
import FXBacktestPlugins
import XCTest

final class OperationalAgentsTests: XCTestCase {
    func testFXExportConnectivityAcceptsMatchingAPIVersion() async throws {
        let agent = FXExportConnectivityAgent(statusLoader: { _ in
            FXBacktestAPIStatusResponse(apiVersion: FXBacktestAPIV1.version, service: "FXExport", status: "ok")
        })

        let outcome = try await agent.check(connection: FXExportConnectionSettings())

        XCTAssertEqual(outcome.status, .ok)
    }

    func testFXExportConnectivityRejectsWrongAPIVersion() async throws {
        let agent = FXExportConnectivityAgent(statusLoader: { _ in
            FXBacktestAPIStatusResponse(apiVersion: "wrong.version", service: "FXExport", status: "ok")
        })

        let outcome = try await agent.check(connection: FXExportConnectionSettings())

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertTrue(outcome.message.contains("version mismatch"))
    }

    func testMarketReadinessRejectsMixedDemoAndFXExportData() throws {
        let demo = try market(symbol: "EURUSD", brokerSourceId: "demo")
        let exported = try market(symbol: "USDJPY", brokerSourceId: "icmarkets-sc-mt5-4", mt5Symbol: "USDJPY", digits: 3)
        let universe = try OhlcMarketUniverse(primarySymbol: "EURUSD", series: [demo, exported])

        let outcome = MarketReadinessAgent().evaluate(universe: universe)

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertTrue(outcome.message.contains("Cannot mix demo and FXExport"))
    }

    func testPluginValidationAcceptsBundledPlugins() {
        let agent = PluginValidationAgent()

        for plugin in FXBacktestPluginRegistry.availablePlugins {
            let outcome = agent.validate(plugin: plugin)
            XCTAssertEqual(outcome.status, .ok, outcome.message)
        }
    }

    func testExecutionSnapshotUsesDemoFallbackWithoutCallingFXExport() async throws {
        let market = try market(symbol: "EURUSD", brokerSourceId: "demo")
        let universe = market.universe
        let agent = ExecutionSnapshotAgent(profileLoader: { _, _ in
            XCTFail("Demo execution snapshot must not call FXExport.")
            return FXBacktestExecutionProfile.empty()
        })

        let result = try await agent.load(
            connection: FXExportConnectionSettings(),
            universe: universe,
            demoProfileBuilder: { universe in
                try Self.executionProfile(for: universe, brokerSourceId: "demo")
            }
        )

        XCTAssertEqual(result.outcome.status, .warning)
        XCTAssertEqual(result.profile.accountingMode, .hedging)
        XCTAssertNotNil(result.profile.symbols["EURUSD"])
    }

    func testOptimizationCoordinatorRejectsMetalForCPUOnlyPlugin() throws {
        let plugin = try XCTUnwrap(FXBacktestPluginRegistry.availablePlugins.first { $0.id == "com.fxbacktest.plugins.fxstupid.v1" })
        let market = try market(symbol: "EURUSD", brokerSourceId: "demo")
        let sweep = try ParameterSweep.singlePass(definitions: plugin.parameterDefinitions)
        let executionProfile = try Self.executionProfile(for: market.universe, brokerSourceId: "demo")

        XCTAssertThrowsError(
            try OptimizationRunCoordinatorAgent().prepare(
                plugin: plugin,
                marketUniverse: market.universe,
                sweep: sweep,
                target: .metal,
                maxWorkers: 1,
                chunkSize: 1,
                initialDeposit: 10_000,
                contractSize: 100_000,
                lotSize: 0.01,
                executionProfile: executionProfile
            )
        )
    }

    func testResourceHealthAcceptsCPUExecution() {
        let outcome = ResourceHealthAgent().evaluate(target: .cpu, maxWorkers: 1, chunkSize: 1)

        XCTAssertNotEqual(outcome.status, .failed)
    }

    func testResultPersistenceAgentSavesAndPurgesThroughStoreAPI() async throws {
        let executor = AgentRecordingClickHouseExecutor()
        let store = ClickHouseBacktestResultStore(
            configuration: FXBacktestClickHouseConfiguration(database: "fxbacktest_agent_test"),
            executor: executor
        )
        let plugin = MovingAverageCrossPlugin()
        let sweep = try ParameterSweep.singlePass(definitions: plugin.parameterDefinitions)
        let run = BacktestStoredRun(
            runID: "agent-run",
            pluginIdentifier: plugin.descriptor.id,
            engine: .cpu,
            brokerSourceId: "demo",
            primarySymbol: "EURUSD",
            symbols: ["EURUSD"],
            settings: BacktestRunSettings(),
            sweep: sweep,
            note: "agent-test"
        )
        let result = BacktestPassResult(
            passIndex: 0,
            pluginIdentifier: plugin.descriptor.id,
            engine: .cpu,
            parameters: [BacktestParameterValue(key: "fast_period", value: 8)],
            netProfit: 1,
            grossProfit: 1,
            grossLoss: 0,
            maxDrawdown: 0,
            totalTrades: 1,
            winningTrades: 1,
            losingTrades: 0,
            winRate: 1,
            profitFactor: 1,
            barsProcessed: 10
        )

        let saveOutcome = try await ResultPersistenceAgent.saveSnapshot(
            store: store,
            run: run,
            results: [result],
            progress: BacktestProgress(completedPasses: 1, totalPasses: 1, elapsedSeconds: 0.1),
            status: "completed"
        )
        let purge = try await ResultPersistenceAgent.purgeAll(store: store)

        let statements = await executor.statements()
        XCTAssertEqual(saveOutcome.status, .ok)
        XCTAssertEqual(purge.outcome.status, .ok)
        XCTAssertTrue(statements.contains { $0.contains("INSERT INTO `fxbacktest_agent_test`.`fxbacktest_runs`") })
        XCTAssertTrue(statements.contains { $0.contains("FORMAT JSONEachRow") })
        XCTAssertTrue(statements.contains { $0.contains("DELETE WHERE 1") })
    }

    private func market(
        symbol: String,
        brokerSourceId: String,
        mt5Symbol: String? = nil,
        digits: Int = 5
    ) throws -> OhlcDataSeries {
        let start = Int64(1_704_067_200)
        let utc = ContiguousArray((0..<10).map { start + Int64($0 * 60) })
        let close = ContiguousArray((0..<10).map { Int64(100_000 + $0 * 10) })
        return try OhlcDataSeries(
            metadata: FXBacktestMarketMetadata(
                brokerSourceId: brokerSourceId,
                logicalSymbol: symbol,
                mt5Symbol: mt5Symbol,
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

    private static func executionProfile(for universe: OhlcMarketUniverse, brokerSourceId: String) throws -> FXBacktestExecutionProfile {
        var specs: [String: FXBacktestSymbolExecutionSpec] = [:]
        for symbol in universe.symbols {
            let series = try XCTUnwrap(universe[symbol])
            specs[symbol] = try FXBacktestSymbolExecutionSpec(
                logicalSymbol: symbol,
                mt5Symbol: symbol,
                digits: series.metadata.digits,
                contractSize: 100_000,
                minLot: 0.01,
                lotStep: 0.01,
                maxLot: 100,
                commissionSource: "unit_test",
                slippageSource: "unit_test"
            )
        }
        return try FXBacktestExecutionProfile(
            brokerSourceId: brokerSourceId,
            depositCurrency: "USD",
            leverage: 100,
            accountingMode: .hedging,
            symbols: specs
        )
    }
}

private actor AgentRecordingClickHouseExecutor: FXBacktestClickHouseExecuting {
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
