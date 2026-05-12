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

@MainActor
final class AppModel: ObservableObject {
    let plugins = FXBacktestPluginRegistry.availablePlugins

    @Published var selectedPluginID: String
    @Published var parameterRows: [ParameterInputRow]
    @Published var executionTarget: BacktestExecutionTarget = .cpu
    @Published var maxWorkers: Int = max(1, ProcessInfo.processInfo.activeProcessorCount)
    @Published var chunkSize: Int = 128
    @Published var initialDeposit: Double = 10_000
    @Published var contractSize: Double = 100_000
    @Published var lotSize: Double = 0.10

    @Published var connectionURLText = "http://127.0.0.1:8123"
    @Published var database = "fxexport"
    @Published var username = ""
    @Published var password = ""
    @Published var brokerSourceId = "icmarkets-sc-mt5-4"
    @Published var logicalSymbol = "EURUSD"
    @Published var expectedMT5Symbol = "EURUSD"
    @Published var expectedDigits = 5
    @Published var utcStartInclusive: Int64 = 1_704_067_200
    @Published var utcEndExclusive: Int64 = 1_707_177_600
    @Published var maximumRows = 5_000_000

    @Published private(set) var market: OhlcDataSeries?
    @Published private(set) var results: [BacktestPassResult] = []
    @Published private(set) var progress = BacktestProgress(completedPasses: 0, totalPasses: 0, elapsedSeconds: 0)
    @Published private(set) var statusText = "Ready"
    @Published private(set) var isRunning = false
    @Published private(set) var isLoadingData = false

    private var runTask: Task<Void, Never>?

    init() {
        let first = FXBacktestPluginRegistry.availablePlugins.first!
        self.selectedPluginID = first.id
        self.parameterRows = Self.rows(for: first)
        self.market = try? OhlcDataSeries.demoEURUSD()
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
        selectedPluginID = pluginID
        parameterRows = Self.rows(for: selectedPlugin)
        results = []
        progress = BacktestProgress(completedPasses: 0, totalPasses: 0, elapsedSeconds: 0)
        statusText = "Selected \(selectedPlugin.descriptor.displayName)"
    }

    func loadDemoData() {
        do {
            market = try OhlcDataSeries.demoEURUSD()
            results = []
            if let market {
                statusText = "Loaded demo \(market.metadata.logicalSymbol) M1 data: \(market.count) bars"
            }
        } catch {
            statusText = String(describing: error)
        }
    }

    func loadFXExportData() {
        guard let url = URL(string: connectionURLText) else {
            statusText = "Invalid ClickHouse URL"
            return
        }
        isLoadingData = true
        statusText = "Loading verified M1 OHLC from FXExport..."
        let connection = FXExportConnectionSettings(
            url: url,
            database: database,
            username: username,
            password: password,
            requestTimeoutSeconds: 120
        )
        let request = FXExportHistoryRequest(
            brokerSourceId: brokerSourceId,
            logicalSymbol: logicalSymbol,
            expectedMT5Symbol: expectedMT5Symbol,
            expectedDigits: expectedDigits,
            utcStartInclusive: utcStartInclusive,
            utcEndExclusive: utcEndExclusive,
            maximumRows: maximumRows
        )

        Task.detached {
            do {
                let loaded = try await FXExportHistoryLoader().load(connection: connection, request: request)
                await MainActor.run {
                    self.market = loaded
                    self.results = []
                    self.statusText = "Loaded \(loaded.metadata.logicalSymbol) M1 data: \(loaded.count) verified bars"
                    self.isLoadingData = false
                }
            } catch {
                await MainActor.run {
                    self.statusText = String(describing: error)
                    self.isLoadingData = false
                }
            }
        }
    }

    func runOptimization() {
        guard !isRunning else { return }
        guard let market else {
            statusText = "Load market data first"
            return
        }

        let sweep: ParameterSweep
        do {
            sweep = try makeSweep()
        } catch {
            statusText = String(describing: error)
            return
        }

        let settings = BacktestRunSettings(
            target: executionTarget,
            maxWorkers: maxWorkers,
            chunkSize: chunkSize,
            initialDeposit: initialDeposit,
            contractSize: contractSize,
            lotSize: lotSize
        )
        let plugin = selectedPlugin
        let optimizer = BacktestOptimizer()

        results = []
        progress = BacktestProgress(completedPasses: 0, totalPasses: sweep.combinationCount, elapsedSeconds: 0)
        isRunning = true
        statusText = "Running \(plugin.descriptor.displayName) on \(settings.target.rawValue.uppercased())..."

        runTask = Task {
            do {
                for try await event in optimizer.run(plugin: plugin, market: market, sweep: sweep, settings: settings) {
                    handle(event)
                }
            } catch is CancellationError {
                statusText = "Run cancelled"
            } catch {
                statusText = String(describing: error)
            }
            isRunning = false
            runTask = nil
        }
    }

    func cancelRun() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        statusText = "Cancelling..."
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
            statusText = "\(latestProgress.completedPasses)/\(latestProgress.totalPasses) passes, \(latestProgress.passesPerSecond.formatted(.number.precision(.fractionLength(0)))) pass/s"
        case .completed(let finalProgress):
            progress = finalProgress
            statusText = "Completed \(finalProgress.completedPasses) passes in \(finalProgress.elapsedSeconds.formatted(.number.precision(.fractionLength(2))))s"
        }
    }

    private func makeSweep() throws -> ParameterSweep {
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
