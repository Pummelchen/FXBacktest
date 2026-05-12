import Foundation

public enum TradeDirection: Int, Sendable {
    case long = 1
    case short = -1
}

public struct BacktestPosition: Sendable, Hashable {
    public let direction: TradeDirection
    public let entryPrice: Int64
    public let lots: Double

    public init(direction: TradeDirection, entryPrice: Int64, lots: Double) {
        self.direction = direction
        self.entryPrice = entryPrice
        self.lots = lots
    }
}

public struct BacktestBroker: Sendable {
    public private(set) var balance: Double
    public private(set) var equity: Double
    public private(set) var equityPeak: Double
    public private(set) var maxDrawdown: Double
    public private(set) var grossProfit: Double
    public private(set) var grossLoss: Double
    public private(set) var totalTrades: Int
    public private(set) var winningTrades: Int
    public private(set) var losingTrades: Int
    public private(set) var position: BacktestPosition?

    private let context: BacktestContext

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
        self.position = nil
    }

    public mutating func openMarket(direction: TradeDirection, price: Int64, lots: Double? = nil) {
        if position?.direction == direction {
            return
        }
        if position != nil {
            closeMarket(price: price)
        }
        position = BacktestPosition(direction: direction, entryPrice: price, lots: lots ?? context.settings.lotSize)
        markToMarket(price: price)
    }

    public mutating func closeMarket(price: Int64) {
        guard let position else { return }
        let pnl = profit(position: position, price: price)
        balance += pnl
        grossProfit += max(0, pnl)
        grossLoss += min(0, pnl)
        totalTrades += 1
        if pnl >= 0 {
            winningTrades += 1
        } else {
            losingTrades += 1
        }
        self.position = nil
        markToMarket(price: price)
    }

    public mutating func markToMarket(price: Int64) {
        let floating = position.map { profit(position: $0, price: price) } ?? 0
        equity = balance + floating
        equityPeak = max(equityPeak, equity)
        maxDrawdown = max(maxDrawdown, equityPeak - equity)
    }

    public mutating func finish(price: Int64) {
        if position != nil {
            closeMarket(price: price)
        } else {
            markToMarket(price: price)
        }
    }

    public var netProfit: Double {
        balance - context.settings.initialDeposit
    }

    public var winRate: Double {
        totalTrades == 0 ? 0 : Double(winningTrades) / Double(totalTrades)
    }

    public var profitFactor: Double {
        grossLoss == 0 ? (grossProfit > 0 ? Double.infinity : 0) : grossProfit / abs(grossLoss)
    }

    private func profit(position: BacktestPosition, price: Int64) -> Double {
        let direction = Double(position.direction.rawValue)
        let priceDelta = Double(price - position.entryPrice) / context.priceScale
        return direction * priceDelta * context.settings.contractSize * position.lots
    }
}
