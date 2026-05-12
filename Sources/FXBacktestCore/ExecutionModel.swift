import Foundation

public enum FXBacktestAccountingMode: String, Codable, CaseIterable, Sendable {
    case netting
    case hedging
}

public enum FXBacktestOrderSide: Int, Codable, Sendable {
    case buy = 1
    case sell = -1
}

public struct FXBacktestSymbolExecutionSpec: Codable, Hashable, Sendable {
    public var logicalSymbol: String
    public var mt5Symbol: String?
    public var digits: Int
    public var contractSize: Double
    public var minLot: Double
    public var lotStep: Double
    public var maxLot: Double
    public var spreadPoints: Int64
    public var slippagePoints: Int64
    public var commissionPerLotPerSide: Double
    public var commissionSource: String
    public var slippageSource: String
    public var swapLongPerLot: Double
    public var swapShortPerLot: Double
    public var marginInitialPerLot: Double?
    public var marginRate: Double
    public var bid: Double?
    public var ask: Double?
    public var capturedAtUtc: Int64?

    public init(
        logicalSymbol: String,
        mt5Symbol: String? = nil,
        digits: Int,
        contractSize: Double = 100_000,
        minLot: Double = 0.01,
        lotStep: Double = 0.01,
        maxLot: Double = 100,
        spreadPoints: Int64 = 0,
        slippagePoints: Int64 = 0,
        commissionPerLotPerSide: Double = 0,
        commissionSource: String = "not_configured",
        slippageSource: String = "not_configured",
        swapLongPerLot: Double = 0,
        swapShortPerLot: Double = 0,
        marginInitialPerLot: Double? = nil,
        marginRate: Double = 1.0 / 100.0,
        bid: Double? = nil,
        ask: Double? = nil,
        capturedAtUtc: Int64? = nil
    ) throws {
        self.logicalSymbol = logicalSymbol.uppercased()
        self.mt5Symbol = mt5Symbol
        self.digits = digits
        self.contractSize = contractSize
        self.minLot = minLot
        self.lotStep = lotStep
        self.maxLot = maxLot
        self.spreadPoints = spreadPoints
        self.slippagePoints = slippagePoints
        self.commissionPerLotPerSide = commissionPerLotPerSide
        self.commissionSource = commissionSource
        self.slippageSource = slippageSource
        self.swapLongPerLot = swapLongPerLot
        self.swapShortPerLot = swapShortPerLot
        self.marginInitialPerLot = marginInitialPerLot
        self.marginRate = marginRate
        self.bid = bid
        self.ask = ask
        self.capturedAtUtc = capturedAtUtc
        try validate()
    }

    public var priceScale: Double {
        pow(10.0, Double(digits))
    }

    public func validate() throws {
        guard !logicalSymbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FXBacktestError.invalidParameter("Execution spec logical symbol must not be empty.")
        }
        guard (0...10).contains(digits) else {
            throw FXBacktestError.invalidParameter("\(logicalSymbol): digits must be in 0...10.")
        }
        guard contractSize.isFinite, contractSize > 0 else {
            throw FXBacktestError.invalidParameter("\(logicalSymbol): contract size must be > 0.")
        }
        guard minLot.isFinite, lotStep.isFinite, maxLot.isFinite, minLot > 0, lotStep > 0, maxLot >= minLot else {
            throw FXBacktestError.invalidParameter("\(logicalSymbol): lot constraints are invalid.")
        }
        guard spreadPoints >= 0, slippagePoints >= 0 else {
            throw FXBacktestError.invalidParameter("\(logicalSymbol): spread and slippage points must be >= 0.")
        }
        guard commissionPerLotPerSide.isFinite else {
            throw FXBacktestError.invalidParameter("\(logicalSymbol): commission must be finite.")
        }
        guard !commissionSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !slippageSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FXBacktestError.invalidParameter("\(logicalSymbol): execution source fields must not be empty.")
        }
        guard swapLongPerLot.isFinite, swapShortPerLot.isFinite else {
            throw FXBacktestError.invalidParameter("\(logicalSymbol): swap values must be finite.")
        }
        if let marginInitialPerLot {
            guard marginInitialPerLot.isFinite, marginInitialPerLot >= 0 else {
                throw FXBacktestError.invalidParameter("\(logicalSymbol): initial margin per lot must be >= 0.")
            }
        }
        guard marginRate.isFinite, marginRate >= 0 else {
            throw FXBacktestError.invalidParameter("\(logicalSymbol): margin rate must be >= 0.")
        }
        if let bid {
            guard bid.isFinite, bid > 0 else {
                throw FXBacktestError.invalidParameter("\(logicalSymbol): bid must be > 0 when supplied.")
            }
        }
        if let ask {
            guard ask.isFinite, ask > 0 else {
                throw FXBacktestError.invalidParameter("\(logicalSymbol): ask must be > 0 when supplied.")
            }
        }
        if let bid, let ask, ask < bid {
            throw FXBacktestError.invalidParameter("\(logicalSymbol): ask must be >= bid when supplied.")
        }
        if let capturedAtUtc {
            guard capturedAtUtc > 0 else {
                throw FXBacktestError.invalidParameter("\(logicalSymbol): capturedAtUtc must be positive when supplied.")
            }
        }
    }

    public func normalizedLot(_ lots: Double) -> Double {
        guard lots.isFinite else { return minLot }
        let clamped = min(max(lots, minLot), maxLot)
        let steps = ((clamped - minLot) / lotStep).rounded(.down)
        return minLot + (steps * lotStep)
    }

    public func bidAsk(fromMidPrice midPrice: Int64) -> (bid: Int64, ask: Int64) {
        let bidOffset = spreadPoints / 2
        let askOffset = spreadPoints - bidOffset
        return (midPrice - bidOffset, midPrice + askOffset)
    }

    public func executablePrice(side: FXBacktestOrderSide, action: FXBacktestDealAction, midPrice: Int64) -> Int64 {
        let quote = bidAsk(fromMidPrice: midPrice)
        switch (side, action) {
        case (.buy, .open):
            return quote.ask + slippagePoints
        case (.buy, .close):
            return quote.bid - slippagePoints
        case (.sell, .open):
            return quote.bid - slippagePoints
        case (.sell, .close):
            return quote.ask + slippagePoints
        }
    }

    public static func fallback(logicalSymbol: String, digits: Int, settings: BacktestRunSettings) throws -> FXBacktestSymbolExecutionSpec {
        try FXBacktestSymbolExecutionSpec(
            logicalSymbol: logicalSymbol,
            mt5Symbol: logicalSymbol,
            digits: digits,
            contractSize: settings.contractSize,
            minLot: 0.01,
            lotStep: 0.01,
            maxLot: 100,
            spreadPoints: 0,
            slippagePoints: 0,
            commissionPerLotPerSide: 0,
            commissionSource: "fallback",
            slippageSource: "fallback",
            marginRate: 0
        )
    }
}

public struct FXBacktestExecutionProfile: Codable, Hashable, Sendable {
    public var brokerSourceId: String
    public var depositCurrency: String
    public var leverage: Double
    public var accountingMode: FXBacktestAccountingMode
    public var symbols: [String: FXBacktestSymbolExecutionSpec]

    public init(
        brokerSourceId: String = "unknown",
        depositCurrency: String = "USD",
        leverage: Double = 100,
        accountingMode: FXBacktestAccountingMode = .hedging,
        symbols: [String: FXBacktestSymbolExecutionSpec] = [:]
    ) throws {
        self.brokerSourceId = brokerSourceId
        self.depositCurrency = depositCurrency.uppercased()
        self.leverage = leverage
        self.accountingMode = accountingMode
        self.symbols = Dictionary(uniqueKeysWithValues: symbols.map { ($0.key.uppercased(), $0.value) })
        try validate()
    }

    public func validate() throws {
        guard !brokerSourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FXBacktestError.invalidParameter("Execution profile broker source id must not be empty.")
        }
        guard !depositCurrency.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FXBacktestError.invalidParameter("Execution profile deposit currency must not be empty.")
        }
        guard leverage.isFinite, leverage > 0 else {
            throw FXBacktestError.invalidParameter("Execution profile leverage must be > 0.")
        }
        for (key, spec) in symbols {
            guard key == spec.logicalSymbol.uppercased() else {
                throw FXBacktestError.invalidParameter("Execution profile symbol key \(key) does not match spec symbol \(spec.logicalSymbol).")
            }
            try spec.validate()
        }
    }

    public func spec(for logicalSymbol: String, fallbackDigits: Int, settings: BacktestRunSettings) throws -> FXBacktestSymbolExecutionSpec {
        if let spec = symbols[logicalSymbol.uppercased()] {
            return spec
        }
        return try FXBacktestSymbolExecutionSpec.fallback(
            logicalSymbol: logicalSymbol,
            digits: fallbackDigits,
            settings: settings
        )
    }

    public static func empty(brokerSourceId: String = "unknown") -> FXBacktestExecutionProfile {
        try! FXBacktestExecutionProfile(brokerSourceId: brokerSourceId, symbols: [:])
    }
}

public enum FXBacktestDealAction: String, Codable, Sendable {
    case open
    case close
}

public struct FXBacktestPositionV2: Codable, Hashable, Identifiable, Sendable {
    public let id: Int64
    public let symbol: String
    public let side: FXBacktestOrderSide
    public let lots: Double
    public let entryPrice: Int64
    public let openedAtUtc: Int64?
    public let openCommission: Double

    public init(
        id: Int64,
        symbol: String,
        side: FXBacktestOrderSide,
        lots: Double,
        entryPrice: Int64,
        openedAtUtc: Int64?,
        openCommission: Double
    ) {
        self.id = id
        self.symbol = symbol.uppercased()
        self.side = side
        self.lots = lots
        self.entryPrice = entryPrice
        self.openedAtUtc = openedAtUtc
        self.openCommission = openCommission
    }
}

public struct FXBacktestTradeLedgerEntry: Codable, Hashable, Identifiable, Sendable {
    public let id: Int64
    public let positionId: Int64
    public let symbol: String
    public let side: FXBacktestOrderSide
    public let lots: Double
    public let entryPrice: Int64
    public let exitPrice: Int64
    public let openedAtUtc: Int64?
    public let closedAtUtc: Int64?
    public let grossProfit: Double
    public let commission: Double
    public let swap: Double
    public let netProfit: Double
    public let balanceAfter: Double

    public init(
        id: Int64,
        positionId: Int64,
        symbol: String,
        side: FXBacktestOrderSide,
        lots: Double,
        entryPrice: Int64,
        exitPrice: Int64,
        openedAtUtc: Int64?,
        closedAtUtc: Int64?,
        grossProfit: Double,
        commission: Double,
        swap: Double,
        netProfit: Double,
        balanceAfter: Double
    ) {
        self.id = id
        self.positionId = positionId
        self.symbol = symbol.uppercased()
        self.side = side
        self.lots = lots
        self.entryPrice = entryPrice
        self.exitPrice = exitPrice
        self.openedAtUtc = openedAtUtc
        self.closedAtUtc = closedAtUtc
        self.grossProfit = grossProfit
        self.commission = commission
        self.swap = swap
        self.netProfit = netProfit
        self.balanceAfter = balanceAfter
    }
}

public struct BacktestBrokerV2: Sendable {
    public private(set) var balance: Double
    public private(set) var equity: Double
    public private(set) var equityPeak: Double
    public private(set) var maxDrawdown: Double
    public private(set) var grossProfit: Double
    public private(set) var grossLoss: Double
    public private(set) var totalTrades: Int
    public private(set) var winningTrades: Int
    public private(set) var losingTrades: Int
    public private(set) var usedMargin: Double
    public private(set) var positions: [FXBacktestPositionV2]
    public private(set) var ledger: [FXBacktestTradeLedgerEntry]

    private let context: BacktestContext
    private var currentMidPrices: [String: Int64]
    private var nextPositionId: Int64
    private var nextLedgerId: Int64

    public init(context: BacktestContext) {
        self.context = context
        self.balance = context.settings.initialDeposit
        self.equity = context.settings.initialDeposit
        self.equityPeak = context.settings.initialDeposit
        self.maxDrawdown = 0
        self.grossProfit = 0
        self.grossLoss = 0
        self.totalTrades = 0
        self.winningTrades = 0
        self.losingTrades = 0
        self.usedMargin = 0
        self.positions = []
        self.ledger = []
        self.currentMidPrices = [:]
        self.nextPositionId = 1
        self.nextLedgerId = 1
    }

    public mutating func openMarket(symbol: String, side: FXBacktestOrderSide, midPrice: Int64, lots: Double? = nil, openedAtUtc: Int64? = nil, digits: Int? = nil) throws -> Int64 {
        let normalizedSymbol = symbol.uppercased()
        let spec = try context.executionSpec(for: normalizedSymbol, fallbackDigits: digits ?? context.digits)
        let normalizedLots = spec.normalizedLot(lots ?? context.settings.lotSize)
        guard normalizedLots > 0 else {
            throw FXBacktestError.invalidParameter("\(normalizedSymbol): lot size must be > 0.")
        }

        if context.settings.executionProfile.accountingMode == .netting,
           let existing = positions.first(where: { $0.symbol == normalizedSymbol }) {
            if existing.side == side {
                return existing.id
            }
            _ = try closePosition(id: existing.id, midPrice: midPrice, closedAtUtc: openedAtUtc, digits: digits)
        }

        let price = spec.executablePrice(side: side, action: .open, midPrice: midPrice)
        let commission = normalizedLots * spec.commissionPerLotPerSide
        balance -= commission
        let position = FXBacktestPositionV2(
            id: nextPositionId,
            symbol: normalizedSymbol,
            side: side,
            lots: normalizedLots,
            entryPrice: price,
            openedAtUtc: openedAtUtc,
            openCommission: commission
        )
        nextPositionId += 1
        positions.append(position)
        currentMidPrices[normalizedSymbol] = midPrice
        recomputeEquity()
        return position.id
    }

    @discardableResult
    public mutating func closePosition(id: Int64, midPrice: Int64, closedAtUtc: Int64? = nil, digits: Int? = nil) throws -> Bool {
        guard let index = positions.firstIndex(where: { $0.id == id }) else { return false }
        let position = positions[index]
        let spec = try context.executionSpec(for: position.symbol, fallbackDigits: digits ?? context.digits)
        positions.remove(at: index)
        let exitPrice = spec.executablePrice(side: position.side, action: .close, midPrice: midPrice)
        let gross = Self.profit(position: position, exitPrice: exitPrice, spec: spec)
        let closeCommission = position.lots * spec.commissionPerLotPerSide
        let swap = position.side == .buy ? position.lots * spec.swapLongPerLot : position.lots * spec.swapShortPerLot
        let net = gross - closeCommission + swap
        balance += net
        grossProfit += max(0, gross)
        grossLoss += min(0, gross)
        totalTrades += 1
        if net >= 0 {
            winningTrades += 1
        } else {
            losingTrades += 1
        }
        ledger.append(FXBacktestTradeLedgerEntry(
            id: nextLedgerId,
            positionId: position.id,
            symbol: position.symbol,
            side: position.side,
            lots: position.lots,
            entryPrice: position.entryPrice,
            exitPrice: exitPrice,
            openedAtUtc: position.openedAtUtc,
            closedAtUtc: closedAtUtc,
            grossProfit: gross,
            commission: position.openCommission + closeCommission,
            swap: swap,
            netProfit: net - position.openCommission,
            balanceAfter: balance
        ))
        nextLedgerId += 1
        currentMidPrices[position.symbol] = midPrice
        recomputeEquity()
        return true
    }

    public mutating func closeAll(midPrices: [String: Int64], closedAtUtc: Int64? = nil, digitsBySymbol: [String: Int] = [:]) throws {
        let openIds = positions.map(\.id)
        for id in openIds {
            guard let position = positions.first(where: { $0.id == id }) else { continue }
            let mid = midPrices[position.symbol] ?? currentMidPrices[position.symbol] ?? position.entryPrice
            try closePosition(id: id, midPrice: mid, closedAtUtc: closedAtUtc, digits: digitsBySymbol[position.symbol])
        }
    }

    public mutating func markToMarket(symbol: String, midPrice: Int64) {
        currentMidPrices[symbol.uppercased()] = midPrice
        recomputeEquity()
    }

    public var netProfit: Double {
        equity - context.settings.initialDeposit
    }

    public var winRate: Double {
        totalTrades == 0 ? 0 : Double(winningTrades) / Double(totalTrades)
    }

    public var profitFactor: Double {
        grossLoss == 0 ? (grossProfit > 0 ? Double.infinity : 0) : grossProfit / abs(grossLoss)
    }

    public var freeMargin: Double {
        equity - usedMargin
    }

    private mutating func recomputeEquity() {
        var floating = 0.0
        var margin = 0.0
        for position in positions {
            let fallbackDigits = context.digits
            guard let spec = try? context.executionSpec(for: position.symbol, fallbackDigits: fallbackDigits) else {
                continue
            }
            let mid = currentMidPrices[position.symbol] ?? position.entryPrice
            let exit = spec.executablePrice(side: position.side, action: .close, midPrice: mid)
            floating += Self.profit(position: position, exitPrice: exit, spec: spec)
            margin += Self.margin(position: position, midPrice: mid, spec: spec)
        }
        equity = balance + floating
        usedMargin = margin
        equityPeak = max(equityPeak, equity)
        maxDrawdown = max(maxDrawdown, equityPeak - equity)
    }

    private static func profit(position: FXBacktestPositionV2, exitPrice: Int64, spec: FXBacktestSymbolExecutionSpec) -> Double {
        let direction = Double(position.side.rawValue)
        let priceDelta = Double(exitPrice - position.entryPrice) / spec.priceScale
        return direction * priceDelta * spec.contractSize * position.lots
    }

    private static func margin(position: FXBacktestPositionV2, midPrice: Int64, spec: FXBacktestSymbolExecutionSpec) -> Double {
        if let marginInitialPerLot = spec.marginInitialPerLot {
            return marginInitialPerLot * position.lots
        }
        let notional = (Double(midPrice) / spec.priceScale) * spec.contractSize * position.lots
        return notional * spec.marginRate
    }
}
