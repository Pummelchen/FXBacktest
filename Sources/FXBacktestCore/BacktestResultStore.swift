import Foundation

public struct FXBacktestClickHouseConfiguration: Codable, Hashable, Sendable {
    public var url: URL
    public var database: String
    public var username: String?
    public var password: String?
    public var requestTimeoutSeconds: Double

    public init(
        url: URL = URL(string: "http://127.0.0.1:8123")!,
        database: String = "fxbacktest",
        username: String? = nil,
        password: String? = nil,
        requestTimeoutSeconds: Double = 30
    ) {
        self.url = url
        self.database = database
        self.username = username
        self.password = password
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }

    public func validate() throws {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw FXBacktestError.invalidParameter("ClickHouse URL must use http or https.")
        }
        guard Self.isSafeIdentifier(database) else {
            throw FXBacktestError.invalidParameter("ClickHouse database must contain only letters, numbers, and underscore.")
        }
        guard requestTimeoutSeconds.isFinite, requestTimeoutSeconds > 0, requestTimeoutSeconds <= 3_600 else {
            throw FXBacktestError.invalidParameter("ClickHouse timeout must be in 0...3600 seconds.")
        }
    }

    static func isSafeIdentifier(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              (first >= 65 && first <= 90) || (first >= 97 && first <= 122) || first == 95 else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 95
        }
    }
}

public protocol FXBacktestClickHouseExecuting: Sendable {
    @discardableResult
    func execute(_ sql: String, configuration: FXBacktestClickHouseConfiguration) async throws -> String
}

public final class FXBacktestClickHouseHTTPClient: FXBacktestClickHouseExecuting, @unchecked Sendable {
    public init() {}

    @discardableResult
    public func execute(_ sql: String, configuration: FXBacktestClickHouseConfiguration) async throws -> String {
        try configuration.validate()
        var components = URLComponents(url: configuration.url, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "database", value: configuration.database))
        queryItems.append(URLQueryItem(name: "wait_end_of_query", value: "1"))
        components?.queryItems = queryItems
        guard let endpoint = components?.url else {
            throw FXBacktestError.dataLoadFailed("Invalid ClickHouse URL.")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeoutSeconds
        request.httpBody = Data(sql.utf8)
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let username = configuration.username, !username.isEmpty {
            let credentials = "\(username):\(configuration.password ?? "")"
            let token = Data(credentials.utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FXBacktestError.dataLoadFailed("ClickHouse response was not HTTP.")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            throw FXBacktestError.dataLoadFailed("ClickHouse HTTP \(http.statusCode): \(body)")
        }
        return body
    }
}

public struct BacktestStoredRun: Codable, Hashable, Sendable {
    public let runID: String
    public let pluginIdentifier: String
    public let engine: BacktestExecutionTarget
    public let brokerSourceId: String
    public let primarySymbol: String
    public let symbols: [String]
    public let settings: BacktestRunSettings
    public let sweep: ParameterSweep
    public let note: String?

    public init(
        runID: String = UUID().uuidString,
        pluginIdentifier: String,
        engine: BacktestExecutionTarget,
        brokerSourceId: String,
        primarySymbol: String,
        symbols: [String],
        settings: BacktestRunSettings,
        sweep: ParameterSweep,
        note: String? = nil
    ) {
        self.runID = runID
        self.pluginIdentifier = pluginIdentifier
        self.engine = engine
        self.brokerSourceId = brokerSourceId
        self.primarySymbol = primarySymbol.uppercased()
        self.symbols = symbols.map { $0.uppercased() }.sorted()
        self.settings = settings
        self.sweep = sweep
        self.note = note
    }
}

public struct BacktestResultPurgeReport: Codable, Hashable, Sendable {
    public let scope: String
    public let sqlStatements: Int

    public init(scope: String, sqlStatements: Int) {
        self.scope = scope
        self.sqlStatements = sqlStatements
    }
}

public protocol BacktestResultStore: Sendable {
    func ensureSchema() async throws
    func startRun(_ run: BacktestStoredRun) async throws
    func appendResults(_ results: [BacktestPassResult], runID: String) async throws
    func completeRun(runID: String, progress: BacktestProgress, status: String) async throws
    func purgeAll() async throws -> BacktestResultPurgeReport
    func purge(olderThanDays days: Int) async throws -> BacktestResultPurgeReport
}

public struct ClickHouseBacktestResultStore: BacktestResultStore {
    public let configuration: FXBacktestClickHouseConfiguration
    private let executor: any FXBacktestClickHouseExecuting

    public init(
        configuration: FXBacktestClickHouseConfiguration = FXBacktestClickHouseConfiguration(),
        executor: any FXBacktestClickHouseExecuting = FXBacktestClickHouseHTTPClient()
    ) {
        self.configuration = configuration
        self.executor = executor
    }

    public func ensureSchema() async throws {
        try configuration.validate()
        var bootstrapConfiguration = configuration
        bootstrapConfiguration.database = "default"
        try await executor.execute("CREATE DATABASE IF NOT EXISTS \(Self.identifier(configuration.database))", configuration: bootstrapConfiguration)
        try await executor.execute(Self.runsTableSQL(database: configuration.database), configuration: configuration)
        try await executor.execute(Self.passResultsTableSQL(database: configuration.database), configuration: configuration)
    }

    public func startRun(_ run: BacktestStoredRun) async throws {
        try await ensureSchema()
        let settingsJSON = try Self.jsonString(run.settings)
        let sweepJSON = try Self.jsonString(run.sweep)
        let symbolsSQL = run.symbols.map(Self.sqlString).joined(separator: ",")
        let sql = """
        INSERT INTO \(Self.table("fxbacktest_runs", database: configuration.database))
        (run_id, created_at, completed_at, plugin_id, engine, broker_source_id, primary_symbol, symbols, api_version, settings_json, parameter_space_json, status, completed_passes, total_passes, note)
        VALUES (
          \(Self.sqlString(run.runID)),
          now64(3),
          NULL,
          \(Self.sqlString(run.pluginIdentifier)),
          \(Self.sqlString(run.engine.rawValue)),
          \(Self.sqlString(run.brokerSourceId)),
          \(Self.sqlString(run.primarySymbol)),
          [\(symbolsSQL)],
          'fxbacktest.result-store.v1',
          \(Self.sqlString(settingsJSON)),
          \(Self.sqlString(sweepJSON)),
          'running',
          0,
          \(run.sweep.combinationCount),
          \(Self.sqlString(run.note ?? ""))
        )
        """
        try await executor.execute(sql, configuration: configuration)
    }

    public func appendResults(_ results: [BacktestPassResult], runID: String) async throws {
        guard !results.isEmpty else { return }
        let rows = try results.map { result in
            PassResultInsertRow(
                run_id: runID,
                pass_index: result.passIndex,
                plugin_id: result.pluginIdentifier,
                engine: result.engine.rawValue,
                net_profit: result.netProfit,
                gross_profit: result.grossProfit,
                gross_loss: result.grossLoss,
                max_drawdown: result.maxDrawdown,
                total_trades: Self.uint32Clamped(result.totalTrades),
                winning_trades: Self.uint32Clamped(result.winningTrades),
                losing_trades: Self.uint32Clamped(result.losingTrades),
                win_rate: result.winRate,
                profit_factor: result.profitFactor.isFinite ? result.profitFactor : 0,
                bars_processed: Self.uint32Clamped(result.barsProcessed),
                flags: result.flags,
                error_message: result.errorMessage ?? "",
                parameters_json: try Self.jsonString(result.parameters)
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try rows.map { row in
            String(data: try encoder.encode(row), encoding: .utf8) ?? "{}"
        }.joined(separator: "\n")
        let sql = """
        INSERT INTO \(Self.table("fxbacktest_pass_results", database: configuration.database)) FORMAT JSONEachRow
        \(payload)
        """
        try await executor.execute(sql, configuration: configuration)
    }

    public func completeRun(runID: String, progress: BacktestProgress, status: String = "completed") async throws {
        let safeStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "completed" : status
        let sql = """
        ALTER TABLE \(Self.table("fxbacktest_runs", database: configuration.database))
        UPDATE
          completed_at = now64(3),
          status = \(Self.sqlString(safeStatus)),
          completed_passes = \(progress.completedPasses)
        WHERE run_id = \(Self.sqlString(runID))
        """
        try await executor.execute(sql, configuration: configuration)
    }

    public func purgeAll() async throws -> BacktestResultPurgeReport {
        let passSQL = "ALTER TABLE \(Self.table("fxbacktest_pass_results", database: configuration.database)) DELETE WHERE 1"
        let runSQL = "ALTER TABLE \(Self.table("fxbacktest_runs", database: configuration.database)) DELETE WHERE 1"
        try await executor.execute(passSQL, configuration: configuration)
        try await executor.execute(runSQL, configuration: configuration)
        return BacktestResultPurgeReport(scope: "all", sqlStatements: 2)
    }

    public func purge(olderThanDays days: Int) async throws -> BacktestResultPurgeReport {
        guard days > 0 else {
            throw FXBacktestError.invalidParameter("Purge age must be > 0 days.")
        }
        let passSQL = """
        ALTER TABLE \(Self.table("fxbacktest_pass_results", database: configuration.database))
        DELETE WHERE inserted_at < now() - INTERVAL \(days) DAY
        """
        let runSQL = """
        ALTER TABLE \(Self.table("fxbacktest_runs", database: configuration.database))
        DELETE WHERE created_at < now() - INTERVAL \(days) DAY
        """
        try await executor.execute(passSQL, configuration: configuration)
        try await executor.execute(runSQL, configuration: configuration)
        return BacktestResultPurgeReport(scope: "older-than-\(days)-days", sqlStatements: 2)
    }

    private static func runsTableSQL(database: String) -> String {
        """
        CREATE TABLE IF NOT EXISTS \(table("fxbacktest_runs", database: database))
        (
          run_id String,
          created_at DateTime64(3, 'UTC'),
          completed_at Nullable(DateTime64(3, 'UTC')),
          plugin_id LowCardinality(String),
          engine LowCardinality(String),
          broker_source_id String,
          primary_symbol String,
          symbols Array(String),
          api_version String,
          settings_json String,
          parameter_space_json String,
          status LowCardinality(String),
          completed_passes UInt64,
          total_passes UInt64,
          note String
        )
        ENGINE = MergeTree
        ORDER BY (created_at, run_id)
        """
    }

    private static func passResultsTableSQL(database: String) -> String {
        """
        CREATE TABLE IF NOT EXISTS \(table("fxbacktest_pass_results", database: database))
        (
          run_id String,
          pass_index UInt64,
          plugin_id LowCardinality(String),
          engine LowCardinality(String),
          net_profit Float64,
          gross_profit Float64,
          gross_loss Float64,
          max_drawdown Float64,
          total_trades UInt32,
          winning_trades UInt32,
          losing_trades UInt32,
          win_rate Float64,
          profit_factor Float64,
          bars_processed UInt32,
          flags UInt32,
          error_message String,
          parameters_json String,
          inserted_at DateTime64(3, 'UTC') DEFAULT now64(3)
        )
        ENGINE = MergeTree
        ORDER BY (run_id, pass_index)
        """
    }

    private static func table(_ name: String, database: String) -> String {
        "\(identifier(database)).\(identifier(name))"
    }

    private static func identifier(_ value: String) -> String {
        "`\(value.replacingOccurrences(of: "`", with: "``"))`"
    }

    private static func sqlString(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))'"
    }

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: try encoder.encode(value), encoding: .utf8) ?? "{}"
    }

    private static func uint32Clamped(_ value: Int) -> UInt32 {
        guard value > 0 else { return 0 }
        if value >= Int(UInt32.max) {
            return UInt32.max
        }
        return UInt32(value)
    }
}

private struct PassResultInsertRow: Encodable {
    let run_id: String
    let pass_index: UInt64
    let plugin_id: String
    let engine: String
    let net_profit: Double
    let gross_profit: Double
    let gross_loss: Double
    let max_drawdown: Double
    let total_trades: UInt32
    let winning_trades: UInt32
    let losing_trades: UInt32
    let win_rate: Double
    let profit_factor: Double
    let bars_processed: UInt32
    let flags: UInt32
    let error_message: String
    let parameters_json: String
}
