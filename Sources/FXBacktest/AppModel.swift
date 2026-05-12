import FXBacktestCore
import FXBacktestPlugins
import Foundation

struct ParameterInputRow: Identifiable, Hashable {
    var id: String { definition.key }
    let definition: ParameterDefinition
    var input: Double
    var minimum: Double
    var step: Double
    var maximum: Double
}

private enum StatusLogMode {
    case silent
    case normal
    case success
    case warning
    case error
    case progress(BacktestProgress)
}

@MainActor
final class AppModel: ObservableObject, @unchecked Sendable {
    let plugins = FXBacktestPluginRegistry.availablePlugins

    @Published var selectedPluginID: String
    @Published var parameterRows: [ParameterInputRow]
    @Published var executionTarget: BacktestExecutionTarget = .cpu
    @Published var maxWorkers: Int = max(1, ProcessInfo.processInfo.activeProcessorCount)
    @Published var chunkSize: Int = 128
    @Published var initialDeposit: Double = 10_000
    @Published var contractSize: Double = 100_000
    @Published var lotSize: Double = 0.10

    @Published var apiURLText = "http://127.0.0.1:5066"
    @Published var brokerSourceId = "icmarkets-sc-mt5-4"
    @Published var logicalSymbol = "EURUSD"
    @Published var logicalSymbolsText = "EURUSD"
    @Published var expectedMT5Symbol = "EURUSD"
    @Published var expectedDigits = 5
    @Published var utcStartInclusive: Int64 = 1_704_067_200
    @Published var utcEndExclusive: Int64 = 1_707_177_600
    @Published var maximumRows = 5_000_000
    @Published var clickHouseURLText = "http://127.0.0.1:8123"
    @Published var clickHouseDatabase = "fxbacktest"
    @Published var clickHouseUsername = ""
    @Published var clickHousePassword = ""
    @Published var persistResultsToClickHouse = false

    @Published private(set) var market: OhlcDataSeries?
    @Published private(set) var marketUniverse: OhlcMarketUniverse?
    @Published private(set) var results: [BacktestPassResult] = []
    @Published private(set) var resultInitialDeposit: Double = 10_000
    @Published private(set) var progress = BacktestProgress(completedPasses: 0, totalPasses: 0, elapsedSeconds: 0)
    @Published private(set) var statusText = "Ready"
    @Published private(set) var isRunning = false
    @Published private(set) var isLoadingData = false
    @Published private(set) var agentOutcomes: [FXBacktestAgentKind: FXBacktestAgentOutcome] = [:]

    private var runTask: Task<Void, Never>?
    private var dataLoadTask: Task<Void, Never>?
    private var terminalCommandShellStarted = false
    private var lastTerminalProgressLog = Date.distantPast
    private var lastRunSettings: BacktestRunSettings?

    init() {
        let first = FXBacktestPluginRegistry.availablePlugins.first!
        self.selectedPluginID = first.id
        self.parameterRows = Self.rows(for: first)
        self.market = try? OhlcDataSeries.demoEURUSD()
        if let market {
            self.marketUniverse = market.universe
        }
        if let market {
            self.statusText = "Loaded demo \(market.metadata.logicalSymbol) M1 data: \(market.count) bars"
        }
    }

    var selectedPlugin: AnyFXBacktestPlugin {
        plugins.first { $0.id == selectedPluginID } ?? plugins[0]
    }

    var combinationCountText: String {
        do {
            return try NumberFormatter.integer.string(from: NSNumber(value: makeSweep().combinationCount)) ?? "0"
        } catch {
            return "Invalid"
        }
    }

    var bestResults: [BacktestPassResult] {
        results.sorted { lhs, rhs in
            if lhs.netProfit == rhs.netProfit {
                return lhs.passIndex < rhs.passIndex
            }
            return lhs.netProfit > rhs.netProfit
        }
    }

    func selectPlugin(_ pluginID: String) {
        guard !isRunning, !isLoadingData else {
            updateStatus("Stop active work before selecting a plugin", log: .warning)
            return
        }
        selectedPluginID = pluginID
        parameterRows = Self.rows(for: selectedPlugin)
        results = []
        lastRunSettings = nil
        resultInitialDeposit = initialDeposit
        progress = BacktestProgress(completedPasses: 0, totalPasses: 0, elapsedSeconds: 0)
        if executionTarget.requiresMetalKernel, selectedPlugin.metalKernel == nil {
            executionTarget = .cpu
            updateStatus("Selected \(selectedPlugin.descriptor.displayName); switched to CPU because this plugin has no Metal execution path", log: .warning)
        } else {
            updateStatus("Selected \(selectedPlugin.descriptor.displayName)")
        }
    }

    func loadDemoData() {
        guard !isRunning, !isLoadingData else {
            updateStatus("Stop active work before loading demo data", log: .warning)
            return
        }
        do {
            market = try OhlcDataSeries.demoEURUSD()
            marketUniverse = market?.universe
            results = []
            lastRunSettings = nil
            resultInitialDeposit = initialDeposit
            if let market {
                recordAgentOutcome(MarketReadinessAgent().evaluate(universe: market.universe))
                updateStatus("Loaded demo \(market.metadata.logicalSymbol) M1 data: \(market.count) bars", log: .success)
            }
        } catch {
            updateStatus(String(describing: error), log: .error)
        }
    }

    func loadFXExportData() {
        guard !isLoadingData else {
            updateStatus("FXExport data load is already running", log: .warning)
            return
        }
        guard !isRunning else {
            updateStatus("Stop active optimization before loading FXExport data", log: .warning)
            return
        }
        do {
            try validateCurrentDataRequest()
        } catch {
            updateStatus(String(describing: error), log: .error)
            return
        }
        let url: URL
        do {
            url = try Self.validatedHTTPURL(apiURLText, fieldName: "FXExport API URL")
        } catch {
            updateStatus(String(describing: error), log: .error)
            return
        }
        isLoadingData = true
        updateStatus("Loading verified M1 OHLC through FXExport API v1...")
        let connection = FXExportConnectionSettings(
            apiBaseURL: url,
            requestTimeoutSeconds: 120
        )
        let symbols = parseSymbols()
        let requests = symbols.map { symbol in
            FXExportHistoryRequest(
                brokerSourceId: brokerSourceId,
                logicalSymbol: symbol,
                expectedMT5Symbol: symbols.count == 1 ? expectedMT5Symbol : nil,
                expectedDigits: symbols.count == 1 ? expectedDigits : nil,
                utcStartInclusive: utcStartInclusive,
                utcEndExclusive: utcEndExclusive,
                maximumRows: maximumRows
            )
        }
        let primarySymbol = symbols.first ?? logicalSymbol

        dataLoadTask = Task.detached { [connection, requests, primarySymbol] in
            do {
                let connectivity = try await FXExportConnectivityAgent().check(connection: connection)
                await MainActor.run {
                    self.recordAgentOutcome(connectivity)
                }
                guard !connectivity.isBlockingFailure else {
                    throw FXBacktestError.dataLoadFailed(connectivity.message)
                }
                let loadedUniverse = try await FXExportHistoryLoader().loadUniverse(
                    connection: connection,
                    requests: requests,
                    primarySymbol: primarySymbol
                )
                let marketReadiness = MarketReadinessAgent().evaluate(universe: loadedUniverse)
                await MainActor.run {
                    self.recordAgentOutcome(marketReadiness)
                }
                guard !marketReadiness.isBlockingFailure else {
                    throw FXBacktestError.invalidMarketData(marketReadiness.message)
                }
                let loaded = loadedUniverse.primary
                let wasCancelled = Task.isCancelled
                await MainActor.run {
                    if wasCancelled {
                        self.updateStatus("FXExport data load cancelled", log: .warning)
                    } else {
                        self.market = loaded
                        self.marketUniverse = loadedUniverse
                        self.results = []
                        self.lastRunSettings = nil
                        self.resultInitialDeposit = self.initialDeposit
                        self.updateStatus("Loaded \(loadedUniverse.symbols.joined(separator: ",")) M1 data: \(loaded.count) aligned verified bars", log: .success)
                    }
                    self.isLoadingData = false
                    self.dataLoadTask = nil
                }
            } catch {
                let wasCancelled = Task.isCancelled || error is CancellationError
                await MainActor.run {
                    if wasCancelled {
                        self.updateStatus("FXExport data load cancelled", log: .warning)
                    } else {
                        self.updateStatus(String(describing: error), log: .error)
                    }
                    self.isLoadingData = false
                    self.dataLoadTask = nil
                }
            }
        }
    }

    func runOptimization() {
        guard !isRunning else {
            updateStatus("Optimization is already running", log: .warning)
            return
        }
        guard !isLoadingData else {
            updateStatus("Wait for FXExport data loading to finish before running", log: .warning)
            return
        }
        guard let marketUniverse else {
            updateStatus("Load market data first", log: .warning)
            return
        }

        let plugin = selectedPlugin
        let sweep: ParameterSweep
        do {
            try validateCurrentRunSettings()
            let pluginOutcome = PluginValidationAgent().validate(plugin: plugin)
            recordAgentOutcome(pluginOutcome)
            guard !pluginOutcome.isBlockingFailure else {
                throw FXBacktestError.invalidParameter(pluginOutcome.message)
            }
            let marketOutcome = MarketReadinessAgent().evaluate(universe: marketUniverse)
            recordAgentOutcome(marketOutcome)
            guard !marketOutcome.isBlockingFailure else {
                throw FXBacktestError.invalidMarketData(marketOutcome.message)
            }
            let resourceOutcome = ResourceHealthAgent().evaluate(
                target: executionTarget,
                maxWorkers: maxWorkers,
                chunkSize: chunkSize
            )
            recordAgentOutcome(resourceOutcome)
            guard !resourceOutcome.isBlockingFailure else {
                throw FXBacktestError.invalidParameter(resourceOutcome.message)
            }
            if executionTarget.requiresMetalKernel, plugin.metalKernel == nil {
                throw FXBacktestError.metalKernelMissing(plugin: plugin.descriptor.displayName)
            }
            sweep = try makeSweep()
        } catch {
            updateStatus(String(describing: error), log: .error)
            return
        }

        let optimizer = BacktestOptimizer()
        let target = executionTarget
        let workers = maxWorkers
        let chunk = chunkSize
        let deposit = initialDeposit
        let configuredContractSize = contractSize
        let configuredLotSize = lotSize
        let configuredBrokerSourceId = brokerSourceId
        let isDemoUniverse = marketUniverse.seriesBySymbol.values.allSatisfy { $0.metadata.brokerSourceId == "demo" }
        let executionAPIURL: URL
        if isDemoUniverse {
            executionAPIURL = (try? Self.validatedHTTPURL(apiURLText, fieldName: "FXExport API URL")) ?? FXExportConnectionSettings().apiBaseURL
        } else {
            do {
                executionAPIURL = try Self.validatedHTTPURL(apiURLText, fieldName: "FXExport API URL")
            } catch {
                updateStatus(String(describing: error), log: .error)
                return
            }
        }
        let executionConnection = FXExportConnectionSettings(
            apiBaseURL: executionAPIURL,
            requestTimeoutSeconds: 60
        )

        results = []
        lastRunSettings = nil
        resultInitialDeposit = deposit
        progress = BacktestProgress(completedPasses: 0, totalPasses: sweep.combinationCount, elapsedSeconds: 0)
        isRunning = true
        lastTerminalProgressLog = .distantPast
        updateStatus("Loading current MT5 execution terms for \(marketUniverse.symbols.joined(separator: ","))...")

        runTask = Task {
            var finalProgress: BacktestProgress?
            var completionStatus = "completed"
            var persistence: ResultPersistenceAgent?
            do {
                let executionProfile: FXBacktestExecutionProfile
                do {
                    let snapshot = try await ExecutionSnapshotAgent().load(
                        connection: executionConnection,
                        universe: marketUniverse,
                        demoProfileBuilder: { universe in
                            try Self.makeFallbackExecutionProfile(
                                for: universe,
                                brokerSourceId: configuredBrokerSourceId,
                                contractSize: configuredContractSize
                            )
                        }
                    )
                    executionProfile = snapshot.profile
                    recordAgentOutcome(snapshot.outcome)
                } catch {
                    recordAgentOutcome(FXBacktestAgentOutcome(
                        descriptor: ExecutionSnapshotAgent.descriptor,
                        status: .failed,
                        message: String(describing: error)
                    ))
                    throw error
                }
                let settings: BacktestRunSettings
                do {
                    let prepared = try OptimizationRunCoordinatorAgent().prepare(
                        plugin: plugin,
                        marketUniverse: marketUniverse,
                        sweep: sweep,
                        target: target,
                        maxWorkers: workers,
                        chunkSize: chunk,
                        initialDeposit: deposit,
                        contractSize: configuredContractSize,
                        lotSize: configuredLotSize,
                        executionProfile: executionProfile
                    )
                    settings = prepared.settings
                    recordAgentOutcome(prepared.outcome)
                } catch {
                    recordAgentOutcome(FXBacktestAgentOutcome(
                        descriptor: OptimizationRunCoordinatorAgent.descriptor,
                        status: .failed,
                        message: String(describing: error)
                    ))
                    throw error
                }
                lastRunSettings = settings
                updateStatus("Running \(plugin.descriptor.displayName) on \(settings.target.rawValue.uppercased()) with current MT5 execution terms...")
                persistence = await startPersistenceIfEnabled(
                    plugin: plugin,
                    marketUniverse: marketUniverse,
                    sweep: sweep,
                    settings: settings
                )
                for try await event in optimizer.run(plugin: plugin, marketUniverse: marketUniverse, sweep: sweep, settings: settings) {
                    handle(event)
                    switch event {
                    case .passCompleted(let result, _):
                        do {
                            try await persistence?.append(result)
                        } catch {
                            updateStatus("ClickHouse persistence failed: \(error)", log: .error)
                        }
                    case .completed(let progress):
                        finalProgress = progress
                    case .started:
                        break
                    }
                }
            } catch is CancellationError {
                completionStatus = "cancelled"
                updateStatus("Run cancelled", log: .warning)
            } catch {
                completionStatus = "failed"
                updateStatus(String(describing: error), log: .error)
            }
            let progressToPersist = finalProgress ?? self.progress
            do {
                if let outcome = try await persistence?.finish(progress: progressToPersist, status: completionStatus) {
                    recordAgentOutcome(outcome)
                }
            } catch {
                recordAgentOutcome(FXBacktestAgentOutcome(
                    descriptor: ResultPersistenceAgent.descriptor,
                    status: .failed,
                    message: "ClickHouse completion update failed: \(error)"
                ))
                updateStatus("ClickHouse completion update failed: \(error)", log: .error)
            }
            isRunning = false
            runTask = nil
        }
    }

    private func recordAgentOutcome(_ outcome: FXBacktestAgentOutcome) {
        agentOutcomes[outcome.kind] = outcome
        let line = "[agent] \(outcome.displayName): \(outcome.message)"
        switch outcome.status {
        case .ok:
            Task { await TerminalLog.info(line) }
        case .warning:
            Task { await TerminalLog.warn(line) }
        case .failed:
            Task { await TerminalLog.error(line) }
        }
    }

    func cancelRun() {
        guard isRunning else { return }
        updateStatus("Cancelling active optimization...")
        runTask?.cancel()
    }

    func startTerminalCommandShellIfNeeded() {
        guard !terminalCommandShellStarted else { return }
        terminalCommandShellStarted = true
        let ignoredArguments = Array(CommandLine.arguments.dropFirst())
        let model = self
        Task.detached(priority: .background) {
            await TerminalCommandSession(model: model, ignoredLaunchArguments: ignoredArguments).run()
        }
    }

    func stopActiveWorkAndWait(reason: String) async {
        let hadActiveWork = isRunning || isLoadingData
        if isRunning {
            updateStatus("Stopping active optimization before \(reason)...")
            runTask?.cancel()
        }
        if isLoadingData {
            updateStatus("Stopping active FXExport data load before \(reason)...")
            dataLoadTask?.cancel()
        }
        while isRunning || isLoadingData {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if hadActiveWork {
            updateStatus("Active work stopped; \(reason) can proceed.", log: .success)
        } else if reason == "terminal stop command" {
            updateStatus("No active FXBacktest work is running")
        }
    }

    private func handle(_ event: BacktestOptimizationEvent) {
        switch event {
        case .started(let totalPasses):
            progress = BacktestProgress(completedPasses: 0, totalPasses: totalPasses, elapsedSeconds: 0)
        case .passCompleted(let result, let latestProgress):
            results.append(result)
            if results.count > 10_000 {
                results.removeFirst(results.count - 10_000)
            }
            progress = latestProgress
            updateStatus(
                "\(latestProgress.completedPasses)/\(latestProgress.totalPasses) passes, \(latestProgress.passesPerSecond.formatted(.number.precision(.fractionLength(0)))) pass/s",
                log: .progress(latestProgress)
            )
        case .completed(let finalProgress):
            progress = finalProgress
            updateStatus("Completed \(finalProgress.completedPasses) passes in \(finalProgress.elapsedSeconds.formatted(.number.precision(.fractionLength(2))))s", log: .success)
        }
    }

    private func updateStatus(_ message: String, log: StatusLogMode = .normal) {
        statusText = message
        switch log {
        case .silent:
            break
        case .normal:
            Task { await TerminalLog.info(message) }
        case .success:
            Task { await TerminalLog.ok(message) }
        case .warning:
            Task { await TerminalLog.warn(message) }
        case .error:
            Task { await TerminalLog.error(message) }
        case .progress(let progress):
            let now = Date()
            if progress.completedPasses == progress.totalPasses || now.timeIntervalSince(lastTerminalProgressLog) >= 2 {
                lastTerminalProgressLog = now
                Task { await TerminalLog.info(message) }
            }
        }
    }

    func makeSweep() throws -> ParameterSweep {
        try ParameterSweep(dimensions: parameterRows.map {
            try ParameterSweepDimension(
                definition: $0.definition,
                input: $0.input,
                minimum: $0.minimum,
                step: $0.step,
                maximum: $0.maximum
            )
        })
    }

    private func validateCurrentDataRequest() throws {
        _ = try Self.validatedHTTPURL(apiURLText, fieldName: "FXExport API URL")
        guard !brokerSourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FXBacktestError.invalidParameter("Broker source id must not be empty.")
        }
        guard !parseSymbols().isEmpty else {
            throw FXBacktestError.invalidParameter("At least one logical symbol must be configured.")
        }
        guard (0...10).contains(expectedDigits) else {
            throw FXBacktestError.invalidParameter("Expected digits must be in 0...10.")
        }
        guard utcStartInclusive < utcEndExclusive else {
            throw FXBacktestError.invalidParameter("UTC start must be earlier than UTC end.")
        }
        guard utcStartInclusive % 60 == 0, utcEndExclusive % 60 == 0 else {
            throw FXBacktestError.invalidParameter("UTC start and end must be minute-aligned.")
        }
        guard maximumRows > 0 else {
            throw FXBacktestError.invalidParameter("Maximum rows must be > 0.")
        }
    }

    private func validateCurrentRunSettings() throws {
        guard maxWorkers > 0 else {
            throw FXBacktestError.invalidParameter("Workers must be > 0.")
        }
        guard chunkSize > 0 else {
            throw FXBacktestError.invalidParameter("Chunk size must be > 0.")
        }
        guard initialDeposit.isFinite, initialDeposit > 0 else {
            throw FXBacktestError.invalidParameter("Initial deposit must be a finite value > 0.")
        }
        guard contractSize.isFinite, contractSize > 0 else {
            throw FXBacktestError.invalidParameter("Contract size must be a finite value > 0.")
        }
        guard lotSize.isFinite, lotSize > 0 else {
            throw FXBacktestError.invalidParameter("Lot size must be a finite value > 0.")
        }
        if persistResultsToClickHouse {
            try makeClickHouseConfiguration().validate()
        }
    }

    private func parseSymbols() -> [String] {
        let source = logicalSymbolsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? logicalSymbol : logicalSymbolsText
        var seen = Set<String>()
        var result: [String] = []
        for raw in source.split(separator: ",", omittingEmptySubsequences: true) {
            let symbol = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !symbol.isEmpty, !seen.contains(symbol) else { continue }
            seen.insert(symbol)
            result.append(symbol)
        }
        return result
    }

    private func makeFallbackExecutionProfile(for universe: OhlcMarketUniverse) throws -> FXBacktestExecutionProfile {
        try Self.makeFallbackExecutionProfile(for: universe, brokerSourceId: brokerSourceId, contractSize: contractSize)
    }

    nonisolated private static func makeFallbackExecutionProfile(
        for universe: OhlcMarketUniverse,
        brokerSourceId: String,
        contractSize: Double
    ) throws -> FXBacktestExecutionProfile {
        var specs: [String: FXBacktestSymbolExecutionSpec] = [:]
        for symbol in universe.symbols {
            guard let series = universe[symbol] else { continue }
            specs[symbol] = try FXBacktestSymbolExecutionSpec(
                logicalSymbol: symbol,
                mt5Symbol: symbol,
                digits: series.metadata.digits,
                contractSize: contractSize,
                minLot: 0.01,
                lotStep: 0.01,
                maxLot: 100,
                spreadPoints: 0,
                slippagePoints: 0,
                commissionPerLotPerSide: 0,
                commissionSource: "demo_fallback",
                slippageSource: "demo_fallback",
                marginRate: 0
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

    private func makeClickHouseConfiguration() throws -> FXBacktestClickHouseConfiguration {
        guard let url = URL(string: clickHouseURLText) else {
            throw FXBacktestError.invalidParameter("Invalid ClickHouse URL.")
        }
        let username = clickHouseUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = clickHousePassword
        let config = FXBacktestClickHouseConfiguration(
            url: url,
            database: clickHouseDatabase,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            requestTimeoutSeconds: 60
        )
        try config.validate()
        return config
    }

    private static func validatedHTTPURL(_ text: String, fieldName: String) throws -> URL {
        guard let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            throw FXBacktestError.invalidParameter("\(fieldName) must be an absolute http or https URL.")
        }
        return url
    }

    private func startPersistenceIfEnabled(
        plugin: AnyFXBacktestPlugin,
        marketUniverse: OhlcMarketUniverse,
        sweep: ParameterSweep,
        settings: BacktestRunSettings
    ) async -> ResultPersistenceAgent? {
        guard persistResultsToClickHouse else { return nil }
        do {
            let config = try makeClickHouseConfiguration()
            let store = ClickHouseBacktestResultStore(configuration: config)
            let run = BacktestStoredRun(
                pluginIdentifier: plugin.descriptor.id,
                engine: settings.target,
                brokerSourceId: settings.executionProfile.brokerSourceId,
                primarySymbol: marketUniverse.primarySymbol,
                symbols: marketUniverse.symbols,
                settings: settings,
                sweep: sweep,
                note: "FXBacktest interactive run"
            )
            let agent = try await ResultPersistenceAgent.start(store: store, run: run)
            recordAgentOutcome(await agent.latestOutcome())
            return agent
        } catch {
            recordAgentOutcome(FXBacktestAgentOutcome(
                descriptor: ResultPersistenceAgent.descriptor,
                status: .failed,
                message: "ClickHouse persistence disabled for this run: \(error)"
            ))
            updateStatus("ClickHouse persistence disabled for this run: \(error)", log: .error)
            return nil
        }
    }

    private static func rows(for plugin: AnyFXBacktestPlugin) -> [ParameterInputRow] {
        plugin.parameterDefinitions.map {
            ParameterInputRow(
                definition: $0,
                input: $0.defaultValue,
                minimum: $0.defaultMinimum,
                step: $0.defaultStep,
                maximum: $0.defaultMaximum
            )
        }
    }
}

private extension NumberFormatter {
    static let integer: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}

extension AppModel {
    func executeTerminalCommand(_ line: String) async -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        do {
            let tokens = try TerminalCommandTokenizer().tokenize(trimmed)
            guard let commandToken = tokens.first else { return true }
            let command = commandToken.lowercased()
            let arguments = tokens.dropFirst()

            switch command {
            case "help", "?":
                await TerminalLog.block(Self.terminalHelpText)
            case "status":
                await TerminalLog.block(statusSummary())
            case "agents":
                await TerminalLog.block(agentSummary())
            case "config", "settings":
                await TerminalLog.block(configurationSummary())
            case "plugins":
                await TerminalLog.block(pluginSummary())
            case "params", "parameters":
                await TerminalLog.block(parameterSummary())
            case "select-plugin", "plugin":
                try await selectPluginFromTerminal(arguments)
            case "load-demo", "demo":
                await stopActiveWorkAndWait(reason: "load demo data")
                loadDemoData()
            case "load-fxexport", "load-data", "load":
                try await loadFXExportFromTerminal(arguments)
            case "run", "optimize":
                try await runFromTerminal(arguments)
            case "save-results", "persist-results":
                try await saveResultsFromTerminal(arguments)
            case "clean-backtest-data", "purge-backtests", "purge-results":
                try await cleanBacktestDataFromTerminal(arguments)
            case "stop", "cancel":
                await stopActiveWorkAndWait(reason: "terminal stop command")
            case "set":
                try await setFromTerminal(arguments)
            case "set-param", "param":
                try await setParameterFromTerminal(arguments)
            case "reset-params":
                await stopActiveWorkAndWait(reason: "reset parameters")
                parameterRows = Self.rows(for: selectedPlugin)
                results = []
                lastRunSettings = nil
                resultInitialDeposit = initialDeposit
                updateStatus("Reset parameters for \(selectedPlugin.descriptor.displayName)", log: .success)
            case "exit", "quit":
                await stopActiveWorkAndWait(reason: "exit")
                await TerminalLog.ok("Exiting FXBacktest")
                return false
            default:
                throw TerminalCommandError.unknownCommand(commandToken)
            }
        } catch {
            await TerminalLog.error(String(describing: error))
        }
        return true
    }

    private static var terminalHelpText: String {
        """
        FXBacktest commands:
          status
          agents
          config
          plugins
          plugin <plugin-id-or-display-name>
          params
          set <field> <value>
          set --api-url http://127.0.0.1:5066 --target both --workers 8
          set --clickhouse-url http://127.0.0.1:8123 --clickhouse-db fxbacktest --persist-results true
          set-param <key> --input 12 --min 6 --step 2 --max 40
          load-demo
          load-fxexport [--api-url URL] [--broker ID] [--symbol EURUSD] [--symbols EURUSD,USDJPY] [--mt5-symbol EURUSD] [--digits 5] [--from UTC] [--to UTC] [--max-rows N]
          run [cpu|gpu|metal|both] [--workers N] [--chunk N] [--initial-deposit N] [--contract-size N] [--lot N]
          save-results [--run-id ID] [--note TEXT]
          clean-backtest-data --older-than-days 30
          clean-backtest-data --all true
          stop
          reset-params
          help
          exit

        State-changing commands gracefully stop active work before changing the app state.
        FXBacktest has no launch-time options; use this resident command shell after startup.
        FXBacktest must load Forex history only through FXExport API v1, never ClickHouse directly.
        ClickHouse access is allowed only through FXBacktest's result-store API for optimization results.
        """
    }

    private func selectPluginFromTerminal(_ arguments: ArraySlice<String>) async throws {
        guard !arguments.isEmpty else {
            throw TerminalCommandError.missingValue("plugin")
        }
        let requested = arguments.joined(separator: " ").lowercased()
        guard let plugin = plugins.first(where: {
            $0.id.lowercased() == requested || $0.descriptor.displayName.lowercased() == requested
        }) else {
            throw TerminalCommandError.invalidValue("Unknown plugin '\(arguments.joined(separator: " "))'. Run `plugins`.")
        }
        await stopActiveWorkAndWait(reason: "select plugin")
        selectPlugin(plugin.id)
    }

    private func loadFXExportFromTerminal(_ arguments: ArraySlice<String>) async throws {
        let parsed = try ParsedTerminalOptions(tokens: arguments)
        guard parsed.positionals.isEmpty else {
            throw TerminalCommandError.invalidValue("load-fxexport accepts options only; unexpected \(parsed.positionals.joined(separator: " ")).")
        }
        try validateConfigurationOptions(parsed.options, allowedGroup: .data)
        await stopActiveWorkAndWait(reason: "load FXExport data")
        try applyConfigurationOptions(parsed.options, allowedGroup: .data)
        loadFXExportData()
    }

    private func runFromTerminal(_ arguments: ArraySlice<String>) async throws {
        let parsed = try ParsedTerminalOptions(tokens: arguments)
        let requestedTarget: BacktestExecutionTarget?
        if let targetName = parsed.positionals.first {
            requestedTarget = try parseTarget(targetName)
        } else {
            requestedTarget = nil
        }
        if parsed.positionals.count > 1 {
            throw TerminalCommandError.invalidValue("run accepts at most one positional target: cpu, gpu/metal, or both.")
        }
        if let requestedTarget {
            try validateTargetSelection(requestedTarget)
        }
        try validateConfigurationOptions(parsed.options, allowedGroup: .run)
        await stopActiveWorkAndWait(reason: "start optimization")
        if let requestedTarget {
            executionTarget = requestedTarget
        }
        try applyConfigurationOptions(parsed.options, allowedGroup: .run)
        runOptimization()
    }

    private func saveResultsFromTerminal(_ arguments: ArraySlice<String>) async throws {
        let parsed = try ParsedTerminalOptions(tokens: arguments)
        guard parsed.positionals.isEmpty else {
            throw TerminalCommandError.invalidValue("save-results accepts options only.")
        }
        let allowedOptions: Set<String> = ["run-id", "run", "note"]
        for key in parsed.options.keys where !allowedOptions.contains(key) {
            throw TerminalCommandError.unknownOption(key)
        }
        guard !results.isEmpty else {
            throw TerminalCommandError.invalidValue("No pass results are currently held in memory.")
        }
        let runID = parsed.options["run-id"] ?? parsed.options["run"] ?? UUID().uuidString
        let note = parsed.options["note"]
        let config = try makeClickHouseConfiguration()
        let store = ClickHouseBacktestResultStore(configuration: config)
        let sweep = try makeSweep()
        let activeUniverse = marketUniverse ?? market?.universe
        guard let activeUniverse else {
            throw TerminalCommandError.invalidValue("Load market data before saving results.")
        }
        let resultsSnapshot = results
        let progressSnapshot = progress
        let selectedPluginID = selectedPlugin.descriptor.id
        let isRunActiveSnapshot = isRunning
        let settings = try lastRunSettings ?? BacktestRunSettings(
            target: executionTarget,
            maxWorkers: maxWorkers,
            chunkSize: chunkSize,
            initialDeposit: resultInitialDeposit,
            contractSize: contractSize,
            lotSize: lotSize,
            executionProfile: makeFallbackExecutionProfile(for: activeUniverse)
        )
        let run = BacktestStoredRun(
            runID: runID,
            pluginIdentifier: selectedPluginID,
            engine: settings.target,
            brokerSourceId: settings.executionProfile.brokerSourceId,
            primarySymbol: activeUniverse.primarySymbol,
            symbols: activeUniverse.symbols,
            settings: settings,
            sweep: sweep,
            note: note
        )
        updateStatus("Saving \(resultsSnapshot.count.formatted()) held pass results to ClickHouse run \(runID)...")
        let outcome = try await ResultPersistenceAgent.saveSnapshot(
            store: store,
            run: run,
            results: resultsSnapshot,
            progress: progressSnapshot,
            status: isRunActiveSnapshot ? "snapshot" : "completed"
        )
        recordAgentOutcome(outcome)
        updateStatus(outcome.message, log: .success)
    }

    private func cleanBacktestDataFromTerminal(_ arguments: ArraySlice<String>) async throws {
        let parsed = try ParsedTerminalOptions(tokens: arguments)
        guard parsed.positionals.isEmpty else {
            throw TerminalCommandError.invalidValue("clean-backtest-data accepts options only.")
        }
        let allowedOptions: Set<String> = ["all", "older-than-days", "days"]
        for key in parsed.options.keys where !allowedOptions.contains(key) {
            throw TerminalCommandError.unknownOption(key)
        }
        let config = try makeClickHouseConfiguration()
        let store = ClickHouseBacktestResultStore(configuration: config)
        let report: BacktestResultPurgeReport
        let outcome: FXBacktestAgentOutcome
        if let all = parsed.options["all"], try parseBool(all, name: "all") {
            let result = try await ResultPersistenceAgent.purgeAll(store: store)
            report = result.report
            outcome = result.outcome
        } else if let daysValue = parsed.options["older-than-days"] ?? parsed.options["days"] {
            let days = try parseInt(daysValue, name: "older-than-days", minimum: 1)
            let result = try await ResultPersistenceAgent.purge(store: store, olderThanDays: days)
            report = result.report
            outcome = result.outcome
        } else {
            throw TerminalCommandError.invalidValue("Use clean-backtest-data --older-than-days N or clean-backtest-data --all true.")
        }
        recordAgentOutcome(outcome)
        updateStatus("Cleaned ClickHouse backtest result data scope \(report.scope)", log: .success)
    }

    private func setFromTerminal(_ arguments: ArraySlice<String>) async throws {
        guard !arguments.isEmpty else {
            throw TerminalCommandError.missingValue("set field")
        }

        if arguments.first?.hasPrefix("--") == true || arguments.contains(where: { $0.contains("=") }) {
            let parsed = try ParsedTerminalOptions(tokens: arguments)
            guard parsed.positionals.isEmpty else {
                throw TerminalCommandError.invalidValue("Unexpected positional values: \(parsed.positionals.joined(separator: " ")).")
            }
            try validateConfigurationOptions(parsed.options, allowedGroup: .all)
            await stopActiveWorkAndWait(reason: "apply settings")
            try applyConfigurationOptions(parsed.options, allowedGroup: .all)
        } else {
            guard arguments.count >= 2, let field = arguments.first else {
                throw TerminalCommandError.missingValue("set value")
            }
            let value = arguments.dropFirst().joined(separator: " ")
            try validateConfigurationOption(key: field, value: value, allowedGroup: .all)
            await stopActiveWorkAndWait(reason: "apply settings")
            try applyConfigurationOption(key: field, value: value, allowedGroup: .all)
        }

        results = []
        lastRunSettings = nil
        resultInitialDeposit = initialDeposit
        updateStatus("Updated FXBacktest settings", log: .success)
    }

    private func setParameterFromTerminal(_ arguments: ArraySlice<String>) async throws {
        guard let rawKey = arguments.first else {
            throw TerminalCommandError.missingValue("parameter key")
        }
        guard let index = parameterRows.firstIndex(where: { $0.definition.key.lowercased() == rawKey.lowercased() }) else {
            throw TerminalCommandError.invalidValue("Unknown parameter '\(rawKey)'. Run `params`.")
        }

        let parsed = try ParsedTerminalOptions(tokens: arguments.dropFirst())
        var row = parameterRows[index]

        if parsed.options.isEmpty, parsed.positionals.isEmpty {
            await TerminalLog.block(parameterLine(row))
            return
        }
        if parsed.options.isEmpty, parsed.positionals.count == 4 {
            row.input = try parseDouble(parsed.positionals[0], name: "input")
            row.minimum = try parseDouble(parsed.positionals[1], name: "min")
            row.step = try parseDouble(parsed.positionals[2], name: "step")
            row.maximum = try parseDouble(parsed.positionals[3], name: "max")
        } else {
            guard parsed.positionals.isEmpty else {
                throw TerminalCommandError.invalidValue("Use either four positional values or --input/--min/--step/--max.")
            }
            for (key, value) in parsed.options {
                switch canonicalKey(key) {
                case "input":
                    row.input = try parseDouble(value, name: key)
                case "min":
                    row.minimum = try parseDouble(value, name: key)
                case "step":
                    row.step = try parseDouble(value, name: key)
                case "max":
                    row.maximum = try parseDouble(value, name: key)
                default:
                    throw TerminalCommandError.unknownOption(key)
                }
            }
        }

        _ = try ParameterSweepDimension(
            definition: row.definition,
            input: row.input,
            minimum: row.minimum,
            step: row.step,
            maximum: row.maximum
        )
        await stopActiveWorkAndWait(reason: "update parameter")
        parameterRows[index] = row
        results = []
        lastRunSettings = nil
        resultInitialDeposit = initialDeposit
        updateStatus("Updated parameter \(row.definition.key)", log: .success)
    }

    private enum ConfigurationGroup {
        case all
        case data
        case run
    }

    private func applyConfigurationOptions(_ options: [String: String], allowedGroup: ConfigurationGroup) throws {
        for (key, value) in options {
            try applyConfigurationOption(key: key, value: value, allowedGroup: allowedGroup)
        }
    }

    private func validateConfigurationOptions(_ options: [String: String], allowedGroup: ConfigurationGroup) throws {
        for (key, value) in options {
            try validateConfigurationOption(key: key, value: value, allowedGroup: allowedGroup)
        }
    }

    private func validateConfigurationOption(key: String, value: String, allowedGroup: ConfigurationGroup) throws {
        let canonical = try canonicalAllowedConfigurationKey(key, allowedGroup: allowedGroup)
        switch canonical {
        case "api-url":
            guard Self.isValidAbsoluteHTTPURL(value) else {
                throw TerminalCommandError.invalidValue("api-url must be an absolute http or https URL.")
            }
        case "broker", "symbol", "symbols", "mt5-symbol", "clickhouse-db", "clickhouse-user", "clickhouse-password":
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TerminalCommandError.invalidValue("\(key) must not be empty.")
            }
        case "clickhouse-url":
            guard URL(string: value) != nil else {
                throw TerminalCommandError.invalidValue("clickhouse-url must be a valid URL.")
            }
        case "persist-results":
            _ = try parseBool(value, name: key)
        case "digits":
            _ = try parseInt(value, name: key, range: 0...10)
        case "from", "to":
            _ = try parseInt64(value, name: key)
        case "max-rows", "workers", "chunk":
            _ = try parseInt(value, name: key, minimum: 1)
        case "target":
            try validateTargetSelection(try parseTarget(value))
        case "initial-deposit", "contract-size", "lot":
            let parsed = try parseDouble(value, name: key, minimum: 0)
            guard parsed > 0 else {
                throw TerminalCommandError.invalidValue("\(key) must be > 0.")
            }
        default:
            throw TerminalCommandError.unknownOption(key)
        }
    }

    private func applyConfigurationOption(key: String, value: String, allowedGroup: ConfigurationGroup) throws {
        let canonical = try canonicalAllowedConfigurationKey(key, allowedGroup: allowedGroup)
        try validateConfigurationOption(key: key, value: value, allowedGroup: allowedGroup)
        switch canonical {
        case "api-url":
            apiURLText = value
        case "broker":
            brokerSourceId = value
        case "symbol":
            logicalSymbol = value.uppercased()
            logicalSymbolsText = logicalSymbol
            expectedMT5Symbol = logicalSymbol
        case "symbols":
            logicalSymbolsText = value.uppercased()
            if let first = parseSymbols().first {
                logicalSymbol = first
                expectedMT5Symbol = first
            }
        case "mt5-symbol":
            expectedMT5Symbol = value
        case "digits":
            expectedDigits = try parseInt(value, name: key, range: 0...10)
        case "from":
            utcStartInclusive = try parseInt64(value, name: key)
        case "to":
            utcEndExclusive = try parseInt64(value, name: key)
        case "max-rows":
            maximumRows = try parseInt(value, name: key, minimum: 1)
        case "target":
            let target = try parseTarget(value)
            try validateTargetSelection(target)
            executionTarget = target
        case "workers":
            maxWorkers = try parseInt(value, name: key, minimum: 1)
        case "chunk":
            chunkSize = try parseInt(value, name: key, minimum: 1)
        case "initial-deposit":
            initialDeposit = try parseDouble(value, name: key, minimum: 0)
        case "contract-size":
            contractSize = try parseDouble(value, name: key, minimum: 0)
        case "lot":
            lotSize = try parseDouble(value, name: key, minimum: 0)
        case "clickhouse-url":
            clickHouseURLText = value
        case "clickhouse-db":
            clickHouseDatabase = value
        case "clickhouse-user":
            clickHouseUsername = value
        case "clickhouse-password":
            clickHousePassword = value
        case "persist-results":
            persistResultsToClickHouse = try parseBool(value, name: key)
        default:
            throw TerminalCommandError.unknownOption(key)
        }
    }

    private func canonicalAllowedConfigurationKey(_ key: String, allowedGroup: ConfigurationGroup) throws -> String {
        let canonical = canonicalKey(key)
        let dataKeys: Set<String> = ["api-url", "broker", "symbol", "symbols", "mt5-symbol", "digits", "from", "to", "max-rows"]
        let runKeys: Set<String> = ["target", "workers", "chunk", "initial-deposit", "contract-size", "lot"]
        let storageKeys: Set<String> = ["clickhouse-url", "clickhouse-db", "clickhouse-user", "clickhouse-password", "persist-results"]
        switch allowedGroup {
        case .data where !dataKeys.contains(canonical):
            throw TerminalCommandError.unknownOption(key)
        case .run where !runKeys.contains(canonical):
            throw TerminalCommandError.unknownOption(key)
        default:
            break
        }
        guard dataKeys.contains(canonical) || runKeys.contains(canonical) || storageKeys.contains(canonical) else {
            throw TerminalCommandError.unknownOption(key)
        }
        return canonical
    }

    private func canonicalKey(_ key: String) -> String {
        switch key.lowercased() {
        case "api", "url", "api-url", "api_url", "fxexport-api", "fxexport-api-url":
            return "api-url"
        case "broker", "broker-source", "broker-source-id", "broker_source_id":
            return "broker"
        case "symbol", "logical-symbol", "logical_symbol":
            return "symbol"
        case "symbols", "logical-symbols", "logical_symbols", "fxpairs":
            return "symbols"
        case "mt5", "mt5-symbol", "expected-mt5-symbol", "expected_mt5_symbol":
            return "mt5-symbol"
        case "digits", "expected-digits", "expected_digits":
            return "digits"
        case "from", "start", "utc-start", "utc_start", "utc-start-inclusive", "utc_start_inclusive":
            return "from"
        case "to", "end", "utc-end", "utc_end", "utc-end-exclusive", "utc_end_exclusive":
            return "to"
        case "max-rows", "maximum-rows", "maximum_rows":
            return "max-rows"
        case "engine", "target":
            return "target"
        case "workers", "max-workers", "max_workers":
            return "workers"
        case "chunk", "chunk-size", "chunk_size":
            return "chunk"
        case "deposit", "initial", "initial-deposit", "initial_deposit":
            return "initial-deposit"
        case "contract", "contract-size", "contract_size":
            return "contract-size"
        case "lot", "lot-size", "lot_size":
            return "lot"
        case "clickhouse-url", "clickhouse_url", "ch-url", "ch_url":
            return "clickhouse-url"
        case "clickhouse-db", "clickhouse-database", "clickhouse_database", "ch-db", "database":
            return "clickhouse-db"
        case "clickhouse-user", "clickhouse-username", "clickhouse_username", "ch-user":
            return "clickhouse-user"
        case "clickhouse-password", "clickhouse_pass", "clickhouse-pass", "ch-password", "ch-pass":
            return "clickhouse-password"
        case "persist", "persist-results", "persist_results", "clickhouse-persist":
            return "persist-results"
        case "minimum":
            return "min"
        case "maximum":
            return "max"
        default:
            return key.lowercased()
        }
    }

    private func parseTarget(_ value: String) throws -> BacktestExecutionTarget {
        switch value.lowercased() {
        case "cpu":
            return .cpu
        case "gpu", "metal", "gpu-metal", "gpu_metal":
            return .metal
        case "both", "hybrid", "cpu-gpu", "cpu_gpu", "cpu-metal", "cpu_metal":
            return .both
        default:
            throw TerminalCommandError.invalidValue("target must be cpu, gpu/metal, or both.")
        }
    }

    private func validateTargetSelection(_ target: BacktestExecutionTarget) throws {
        if target.requiresMetalKernel, selectedPlugin.metalKernel == nil {
            throw TerminalCommandError.invalidValue("\(selectedPlugin.descriptor.displayName) has no Metal execution path; choose cpu.")
        }
    }

    private static func isValidAbsoluteHTTPURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            return false
        }
        return true
    }

    private func parseInt(_ value: String, name: String, minimum: Int? = nil, range: ClosedRange<Int>? = nil) throws -> Int {
        guard let parsed = Int(value) else {
            throw TerminalCommandError.invalidValue("\(name) must be an integer.")
        }
        if let minimum, parsed < minimum {
            throw TerminalCommandError.invalidValue("\(name) must be >= \(minimum).")
        }
        if let range, !range.contains(parsed) {
            throw TerminalCommandError.invalidValue("\(name) must be in \(range.lowerBound)...\(range.upperBound).")
        }
        return parsed
    }

    private func parseInt64(_ value: String, name: String) throws -> Int64 {
        guard let parsed = Int64(value) else {
            throw TerminalCommandError.invalidValue("\(name) must be an integer.")
        }
        return parsed
    }

    private func parseDouble(_ value: String, name: String, minimum: Double? = nil) throws -> Double {
        guard let parsed = Double(value), parsed.isFinite else {
            throw TerminalCommandError.invalidValue("\(name) must be a finite number.")
        }
        if let minimum, parsed < minimum {
            throw TerminalCommandError.invalidValue("\(name) must be >= \(minimum).")
        }
        return parsed
    }

    private func parseBool(_ value: String, name: String) throws -> Bool {
        switch value.lowercased() {
        case "true", "yes", "1", "on", "enabled":
            return true
        case "false", "no", "0", "off", "disabled":
            return false
        default:
            throw TerminalCommandError.invalidValue("\(name) must be true or false.")
        }
    }

    private func statusSummary() -> String {
        let state: String
        if isRunning {
            state = "running"
        } else if isLoadingData {
            state = "loading-data"
        } else {
            state = "idle"
        }
        let marketText: String
        if let marketUniverse {
            let primary = marketUniverse.primary
            marketText = "\(marketUniverse.symbols.joined(separator: ",")) \(primary.metadata.timeframe), \(primary.count.formatted()) aligned bars, primary \(marketUniverse.primarySymbol)"
        } else if let market {
            marketText = "\(market.metadata.logicalSymbol) \(market.metadata.timeframe), \(market.count.formatted()) bars, digits \(market.metadata.digits)"
        } else {
            marketText = "none"
        }
        let sweepText = (try? makeSweep().combinationCount.formatted()) ?? "invalid"
        let bestText: String
        if let best = bestResults.first {
            bestText = "pass \(best.passIndex), profit \(best.netProfit.formatted(.number.precision(.fractionLength(2))))"
        } else {
            bestText = "none"
        }
        return """
        FXBacktest status
          State: \(state)
          Status: \(statusText)
          Plugin: \(selectedPlugin.descriptor.displayName) (\(selectedPlugin.id))
          Market: \(marketText)
          Engine: \(executionTarget.rawValue), workers \(maxWorkers), chunk \(chunkSize)
          ClickHouse persistence: \(persistResultsToClickHouse ? "enabled" : "disabled")
          Agents: \(agentStateSummaryLine())
          Sweep combinations: \(sweepText)
          Progress: \(progress.completedPasses.formatted()) / \(progress.totalPasses.formatted())
          Results held: \(results.count.formatted())
          Best result: \(bestText)
        """
    }

    private func configurationSummary() -> String {
        """
        FXBacktest settings
          FXExport API: \(apiURLText)
          Broker: \(brokerSourceId)
          Symbols: \(logicalSymbolsText)
          Single-symbol validation: MT5 \(expectedMT5Symbol), digits \(expectedDigits)
          UTC range: \(utcStartInclusive) ..< \(utcEndExclusive)
          Maximum rows: \(maximumRows.formatted())
          Engine: \(executionTarget.rawValue)
          Workers: \(maxWorkers)
          Chunk size: \(chunkSize)
          Initial deposit: \(initialDeposit)
          Contract size: \(contractSize)
          Lot size: \(lotSize)
          ClickHouse results: \(clickHouseURLText), database \(clickHouseDatabase), user \(clickHouseUsername.isEmpty ? "(none)" : clickHouseUsername), password \(clickHousePassword.isEmpty ? "(not set)" : "(set)"), auto-persist \(persistResultsToClickHouse)
        """
    }

    private func agentSummary() -> String {
        let lines = FXBacktestAgentKind.allCases.map { kind -> String in
            if let outcome = agentOutcomes[kind] {
                let detail = outcome.details.isEmpty ? "" : " (\(outcome.details.joined(separator: ", ")))"
                return "  \(outcome.displayName): \(outcome.status.rawValue) - \(outcome.message)\(detail)"
            }
            return "  \(Self.agentDisplayName(for: kind)): idle - no outcome recorded yet"
        }
        return (["FXBacktest agents:"] + lines).joined(separator: "\n")
    }

    private func agentStateSummaryLine() -> String {
        let recorded = agentOutcomes.values
        guard !recorded.isEmpty else { return "idle" }
        let failures = recorded.filter { $0.status == .failed }.count
        let warnings = recorded.filter { $0.status == .warning }.count
        let ok = recorded.filter { $0.status == .ok }.count
        return "\(ok) ok, \(warnings) warning, \(failures) failed"
    }

    private static func agentDisplayName(for kind: FXBacktestAgentKind) -> String {
        switch kind {
        case .fxExportConnectivity:
            return FXExportConnectivityAgent.descriptor.displayName
        case .marketReadiness:
            return MarketReadinessAgent.descriptor.displayName
        case .executionSnapshot:
            return ExecutionSnapshotAgent.descriptor.displayName
        case .optimizationRunCoordinator:
            return OptimizationRunCoordinatorAgent.descriptor.displayName
        case .resultPersistence:
            return ResultPersistenceAgent.descriptor.displayName
        case .pluginValidation:
            return PluginValidationAgent.descriptor.displayName
        case .resourceHealth:
            return ResourceHealthAgent.descriptor.displayName
        }
    }

    private func pluginSummary() -> String {
        let lines = plugins.map { plugin in
            let metal = plugin.descriptor.supportsMetal ? "cpu/metal/both" : "cpu-only"
            let acceleration = plugin.accelerationDescriptor.supportedBackends.map(\.rawValue).joined(separator: ",")
            return "  \(plugin.id) - \(plugin.descriptor.displayName) \(plugin.descriptor.version) [\(metal); accel \(acceleration)]"
        }
        return (["EA plugins:"] + lines).joined(separator: "\n")
    }

    private func parameterSummary() -> String {
        (["Parameters:"] + parameterRows.map(parameterLine)).joined(separator: "\n")
    }

    private func parameterLine(_ row: ParameterInputRow) -> String {
        "  \(row.definition.key): input \(row.input), min \(row.minimum), step \(row.step), max \(row.maximum)"
    }
}
