import Foundation

public enum BacktestExecutionTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case cpu
    case metal

    public var id: String { rawValue }
}

public struct BacktestRunSettings: Codable, Hashable, Sendable {
    public var target: BacktestExecutionTarget
    public var maxWorkers: Int
    public var chunkSize: Int
    public var initialDeposit: Double
    public var contractSize: Double
    public var lotSize: Double
    public var executionProfile: FXBacktestExecutionProfile

    public init(
        target: BacktestExecutionTarget = .cpu,
        maxWorkers: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        chunkSize: Int = 128,
        initialDeposit: Double = 10_000,
        contractSize: Double = 100_000,
        lotSize: Double = 0.10,
        executionProfile: FXBacktestExecutionProfile = .empty()
    ) {
        self.target = target
        self.maxWorkers = max(1, maxWorkers)
        self.chunkSize = max(1, chunkSize)
        self.initialDeposit = initialDeposit
        self.contractSize = contractSize
        self.lotSize = lotSize
        self.executionProfile = executionProfile
    }
}

public struct BacktestContext: Sendable {
    public let settings: BacktestRunSettings
    public let digits: Int
    public let priceScale: Double

    public init(settings: BacktestRunSettings, digits: Int) {
        self.settings = settings
        self.digits = digits
        self.priceScale = pow(10.0, Double(digits))
    }

    public func executionSpec(for logicalSymbol: String, fallbackDigits: Int? = nil) throws -> FXBacktestSymbolExecutionSpec {
        try settings.executionProfile.spec(
            for: logicalSymbol,
            fallbackDigits: fallbackDigits ?? digits,
            settings: settings
        )
    }
}

public struct BacktestPassResult: Identifiable, Codable, Hashable, Sendable {
    public var id: UInt64 { passIndex }
    public let passIndex: UInt64
    public let pluginIdentifier: String
    public let engine: BacktestExecutionTarget
    public let parameters: [BacktestParameterValue]
    public let netProfit: Double
    public let grossProfit: Double
    public let grossLoss: Double
    public let maxDrawdown: Double
    public let totalTrades: Int
    public let winningTrades: Int
    public let losingTrades: Int
    public let winRate: Double
    public let profitFactor: Double
    public let barsProcessed: Int
    public let flags: UInt32
    public let errorMessage: String?

    public init(
        passIndex: UInt64,
        pluginIdentifier: String,
        engine: BacktestExecutionTarget,
        parameters: [BacktestParameterValue],
        netProfit: Double,
        grossProfit: Double,
        grossLoss: Double,
        maxDrawdown: Double,
        totalTrades: Int,
        winningTrades: Int,
        losingTrades: Int,
        winRate: Double,
        profitFactor: Double,
        barsProcessed: Int,
        flags: UInt32 = 0,
        errorMessage: String? = nil
    ) {
        self.passIndex = passIndex
        self.pluginIdentifier = pluginIdentifier
        self.engine = engine
        self.parameters = parameters
        self.netProfit = netProfit
        self.grossProfit = grossProfit
        self.grossLoss = grossLoss
        self.maxDrawdown = maxDrawdown
        self.totalTrades = totalTrades
        self.winningTrades = winningTrades
        self.losingTrades = losingTrades
        self.winRate = winRate
        self.profitFactor = profitFactor
        self.barsProcessed = barsProcessed
        self.flags = flags
        self.errorMessage = errorMessage
    }

    public func withEngine(_ target: BacktestExecutionTarget) -> BacktestPassResult {
        BacktestPassResult(
            passIndex: passIndex,
            pluginIdentifier: pluginIdentifier,
            engine: target,
            parameters: parameters,
            netProfit: netProfit,
            grossProfit: grossProfit,
            grossLoss: grossLoss,
            maxDrawdown: maxDrawdown,
            totalTrades: totalTrades,
            winningTrades: winningTrades,
            losingTrades: losingTrades,
            winRate: winRate,
            profitFactor: profitFactor,
            barsProcessed: barsProcessed,
            flags: flags,
            errorMessage: errorMessage
        )
    }
}

public struct BacktestProgress: Codable, Hashable, Sendable {
    public let completedPasses: UInt64
    public let totalPasses: UInt64
    public let elapsedSeconds: Double

    public var fraction: Double {
        guard totalPasses > 0 else { return 0 }
        return Double(completedPasses) / Double(totalPasses)
    }

    public var passesPerSecond: Double {
        guard elapsedSeconds > 0 else { return 0 }
        return Double(completedPasses) / elapsedSeconds
    }

    public init(completedPasses: UInt64, totalPasses: UInt64, elapsedSeconds: Double) {
        self.completedPasses = completedPasses
        self.totalPasses = totalPasses
        self.elapsedSeconds = elapsedSeconds
    }
}

public enum BacktestOptimizationEvent: Sendable {
    case started(totalPasses: UInt64)
    case passCompleted(BacktestPassResult, BacktestProgress)
    case completed(BacktestProgress)
}
