import FXBacktestCore
import Foundation

public struct FXStupid: FXBacktestPluginV1 {
    private let config: FXStupidConfig

    public let descriptor: FXBacktestPluginDescriptor
    public let parameterDefinitions: [ParameterDefinition]

    public init() {
        let config = FXStupidConfig.load()
        self.config = config
        self.descriptor = FXBacktestPluginDescriptor(
            id: config.descriptor.id,
            displayName: config.descriptor.displayName,
            version: config.descriptor.version,
            summary: config.descriptor.summary,
            author: config.descriptor.author,
            supportsCPU: true,
            supportsMetal: false
        )
        self.parameterDefinitions = config.numericInputs.map { input in
            try! ParameterDefinition(
                key: input.key,
                displayName: input.displayName,
                defaultValue: input.value,
                defaultMinimum: input.minimum,
                defaultStep: input.step,
                defaultMaximum: input.maximum,
                valueKind: input.parameterKind
            )
        }
    }

    public func runPass(
        market: OhlcDataSeries,
        parameters: ParameterVector,
        context: BacktestContext
    ) throws -> BacktestPassResult {
        try runPass(marketUniverse: market.universe, parameters: parameters, context: context)
    }

    public func runPass(
        marketUniverse: OhlcMarketUniverse,
        parameters: ParameterVector,
        context: BacktestContext
    ) throws -> BacktestPassResult {
        var runtime = FXStupidRuntime(
            plugin: self,
            config: config,
            marketUniverse: marketUniverse,
            parameters: parameters,
            context: context
        )
        runtime.onInit()

        for index in 0..<marketUniverse.count {
            if runtime.hardStopped { break }
            try runtime.onTick(index: index)
        }

        try runtime.finish()
        return runtime.result()
    }
}

private struct FXStupidRuntime {
    let plugin: FXStupid
    let config: FXStupidConfig
    let marketUniverse: OhlcMarketUniverse
    let parameters: ParameterVector
    let context: BacktestContext
    let symbols: [String]

    var inputs: FXStupidInputs
    var tradedSymbols: [String] = []
    var globalStartLotSize: Double
    var newLot: Double
    var startEquity: Double = 0
    var newMaxEquity: Double = 0
    var trailTemp: Double = 0
    var hardStopped = false
    var barsProcessed = 0
    var flags: UInt32 = 0
    var broker: FXStupidBroker

    init(
        plugin: FXStupid,
        config: FXStupidConfig,
        marketUniverse: OhlcMarketUniverse,
        parameters: ParameterVector,
        context: BacktestContext
    ) {
        self.plugin = plugin
        self.config = config
        self.marketUniverse = marketUniverse
        self.parameters = parameters
        self.context = context
        self.symbols = config.fxpairs
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        self.inputs = FXStupidInputs(config: config, parameters: parameters)
        self.globalStartLotSize = inputs.lotSize
        self.newLot = inputs.lotSize
        self.broker = FXStupidBroker(context: context)
        if config.signalTimeframe != "PERIOD_M1" {
            self.flags |= FXStupidResultFlag.unsupportedTimeframe.rawValue
        }
    }

    mutating func onInit() {
        globalStartLotSize = inputs.lotSize
        startEquity = broker.equity
        newMaxEquity = startEquity
    }

    mutating func onTick(index: Int) throws {
        barsProcessed = index + 1
        for symbol in marketUniverse.symbols {
            if let close = marketUniverse[symbol]?.close[index] {
                try broker.markToMarket(symbol: symbol, price: close, digits: digits(for: symbol))
            }
        }

        eaStop()
        if hardStopped { return }
        try tpCheck()
        try slCheck()
        adjustLotSizes()
        refreshTraded()
        try orderScan(index: index)
    }

    mutating func eaStop() {
        if ordersTotal() + positionsTotal() > 0 {
            if broker.equity < inputs.eaStopMinEqui {
                hardExit()
            }

            if broker.equity < newMaxEquity * (1.0 - inputs.eaStopMaxDD / 100.0) {
                hardExit()
            }
        }
    }

    mutating func tpCheck() throws {
        if ordersTotal() + positionsTotal() > 0 {
            if inputs.trailStop == 1 {
                try trailingStop()
            }

            if inputs.trailStop == 0 {
                if (broker.equity - newMaxEquity) > inputs.eaEquiTP {
                    try closeAll()
                }
            }
        }
    }

    mutating func slCheck() throws {
        if inputs.eaEquiSL > 0 && ordersTotal() + positionsTotal() > 0 {
            if (newMaxEquity - broker.equity) > inputs.eaEquiSL {
                try closeAll()
            }
        }
    }

    mutating func trailingStop() throws {
        let p = broker.equity - newMaxEquity

        if trailTemp == 0 && p > (inputs.eaEquiTP + inputs.trailStepUp) {
            trailTemp = inputs.eaEquiTP + inputs.trailStepUp
        }

        if trailTemp > 0 && p > (trailTemp + inputs.trailStepUp) {
            trailTemp += inputs.trailStepUp
        }

        if trailTemp > 0 && p < inputs.eaEquiTP {
            try closeAll()
        }

        if trailTemp > 0 && p < (trailTemp - inputs.trailStepDown) {
            try closeAll()
        }
    }

    mutating func hardExit() {
        flags |= FXStupidResultFlag.hardStopped.rawValue
        hardStopped = true
    }

    mutating func placeInitialOrder(orderType: Int, symbol: String, price: Int64) throws {
        if orderType == 1 {
            _ = try broker.buy(symbol: symbol, lots: normalizeLot(newLot), price: price, digits: digits(for: symbol))
        }
        if orderType == 2 {
            _ = try broker.sell(symbol: symbol, lots: normalizeLot(newLot), price: price, digits: digits(for: symbol))
        }
    }

    mutating func closeAll() throws {
        try broker.closeAll(digitsBySymbol: marketUniverse.digitsBySymbol())
        newMaxEquity = broker.equity
        if inputs.trailStop == 1 {
            trailTemp = 0
        }
    }

    mutating func adjustLotSizes() {
        if inputs.lotBooster > 0 {
            if broker.equity / startEquity > 1 {
                let newLotSize = inputs.lotSize * ((broker.equity / startEquity) * inputs.lotBooster)
                newLot = normalizeLot(newLotSize)
            } else {
                newLot = globalStartLotSize
            }
        }
    }

    func isTraded(_ symbol: String) -> Bool {
        for traded in tradedSymbols {
            if traded == symbol { return true }
        }
        return false
    }

    mutating func addTraded(_ symbol: String) {
        tradedSymbols.append(symbol)
    }

    func trendChecker(symbol: String, index: Int) -> Int {
        guard let closes = copyClose(symbol: symbol, index: index) else {
            return 0
        }

        var up = true
        var down = true

        for i in 1..<inputs.barsLookBack {
            if closes[i] <= closes[i - 1] { up = false }
            if closes[i] >= closes[i - 1] { down = false }
        }

        if up { return 1 }
        if down { return 2 }

        return 0
    }

    mutating func orderScan(index: Int) throws {
        var total = ordersTotal() + positionsTotal()
        if total >= inputs.maxOrders { return }

        for sx in symbols where total < inputs.maxOrders {
            if sx == "" { continue }
            if isTraded(sx) { continue }
            if !symbolSelect(sx) { continue }

            guard let closes = copyClose(symbol: sx, index: index) else {
                continue
            }

            var up = true
            var down = true

            for k in 1..<inputs.barsLookBack {
                if closes[k] <= closes[k - 1] { up = false }
                if closes[k] >= closes[k - 1] { down = false }
            }

            if !up && !down { continue }

            var ok = false
            guard let price = marketUniverse[sx]?.close[index] else {
                continue
            }

            if up {
                ok = try broker.buy(symbol: sx, lots: newLot, price: price, digits: digits(for: sx))
            } else if down {
                ok = try broker.sell(symbol: sx, lots: newLot, price: price, digits: digits(for: sx))
            }

            if ok {
                addTraded(sx)
                total += 1
            }
        }
    }

    mutating func refreshTraded() {
        for index in tradedSymbols.indices.reversed() {
            let symbol = tradedSymbols[index]
            var found = false

            for position in broker.positions {
                if position.symbol == symbol {
                    found = true
                    break
                }
            }

            if !found {
                tradedSymbols.remove(at: index)
            }
        }
    }

    mutating func finish() throws {
        for symbol in marketUniverse.symbols {
            if let finalClose = marketUniverse[symbol]?.close.last {
                try broker.markToMarket(symbol: symbol, price: finalClose, digits: digits(for: symbol))
            }
        }
        if !hardStopped {
            try closeAll()
        }
    }

    func result() -> BacktestPassResult {
        BacktestPassResult(
            passIndex: parameters.combinationIndex,
            pluginIdentifier: plugin.descriptor.id,
            engine: context.settings.target,
            parameters: parameters.snapshots,
            netProfit: broker.netProfit,
            grossProfit: broker.grossProfit,
            grossLoss: broker.grossLoss,
            maxDrawdown: broker.maxDrawdown,
            totalTrades: broker.totalTrades,
            winningTrades: broker.winningTrades,
            losingTrades: broker.losingTrades,
            winRate: broker.winRate,
            profitFactor: broker.profitFactor,
            barsProcessed: barsProcessed,
            flags: flags
        )
    }

    func ordersTotal() -> Int {
        0
    }

    func positionsTotal() -> Int {
        broker.positions.count
    }

    func symbolSelect(_ symbol: String) -> Bool {
        marketUniverse[symbol] != nil
    }

    func copyClose(symbol: String, index: Int) -> [Int64]? {
        guard symbolSelect(symbol), inputs.barsLookBack > 0, index >= inputs.barsLookBack else {
            return nil
        }
        return marketUniverse.closes(symbol: symbol, range: (index - inputs.barsLookBack)..<index)
    }

    func normalizeLot(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    func digits(for symbol: String) -> Int {
        marketUniverse[symbol]?.metadata.digits ?? context.digits
    }
}

private struct FXStupidBroker {
    let context: BacktestContext
    let initialDeposit: Double
    private(set) var balance: Double
    private(set) var equity: Double
    private(set) var equityPeak: Double
    private(set) var maxDrawdown: Double
    private(set) var grossProfit: Double = 0
    private(set) var grossLoss: Double = 0
    private(set) var totalTrades: Int = 0
    private(set) var winningTrades: Int = 0
    private(set) var losingTrades: Int = 0
    private(set) var positions: [FXStupidPosition] = []
    private var currentPrices: [String: Int64] = [:]

    init(context: BacktestContext) {
        self.context = context
        self.initialDeposit = context.settings.initialDeposit
        self.balance = context.settings.initialDeposit
        self.equity = context.settings.initialDeposit
        self.equityPeak = context.settings.initialDeposit
        self.maxDrawdown = 0
    }

    mutating func buy(symbol: String, lots: Double, price: Int64, digits: Int) throws -> Bool {
        try open(symbol: symbol, direction: .buy, lots: lots, price: price, digits: digits)
    }

    mutating func sell(symbol: String, lots: Double, price: Int64, digits: Int) throws -> Bool {
        try open(symbol: symbol, direction: .sell, lots: lots, price: price, digits: digits)
    }

    mutating func open(symbol: String, direction: FXStupidDirection, lots: Double, price: Int64, digits: Int) throws -> Bool {
        let normalizedSymbol = symbol.uppercased()
        guard lots > 0, !positions.contains(where: { $0.symbol == normalizedSymbol }) else {
            return false
        }
        let spec = try context.executionSpec(for: normalizedSymbol, fallbackDigits: digits)
        let normalizedLots = spec.normalizedLot(lots)
        guard normalizedLots > 0 else { return false }
        let side = direction.orderSide
        let entryPrice = spec.executablePrice(side: side, action: .open, midPrice: price)
        let openCommission = normalizedLots * spec.commissionPerLotPerSide
        balance -= openCommission
        positions.append(FXStupidPosition(
            symbol: normalizedSymbol,
            direction: direction,
            entryPrice: entryPrice,
            lots: normalizedLots,
            digits: digits,
            openCommission: openCommission
        ))
        try markToMarket(symbol: normalizedSymbol, price: price, digits: digits)
        return true
    }

    mutating func closeAll(digitsBySymbol: [String: Int]) throws {
        for position in positions {
            let price = currentPrices[position.symbol] ?? position.entryPrice
            try close(position: position, price: price, digits: digitsBySymbol[position.symbol])
        }
        positions.removeAll(keepingCapacity: true)
        try recomputeEquity()
    }

    mutating func markToMarket(symbol: String, price: Int64, digits: Int) throws {
        let normalizedSymbol = symbol.uppercased()
        _ = try context.executionSpec(for: normalizedSymbol, fallbackDigits: digits)
        currentPrices[normalizedSymbol] = price
        try recomputeEquity()
    }

    var netProfit: Double {
        equity - initialDeposit
    }

    var winRate: Double {
        totalTrades == 0 ? 0 : Double(winningTrades) / Double(totalTrades)
    }

    var profitFactor: Double {
        grossLoss == 0 ? (grossProfit > 0 ? Double.infinity : 0) : grossProfit / abs(grossLoss)
    }

    private mutating func close(position: FXStupidPosition, price: Int64, digits: Int?) throws {
        let spec = try context.executionSpec(for: position.symbol, fallbackDigits: digits ?? position.digits)
        let exitPrice = spec.executablePrice(side: position.direction.orderSide, action: .close, midPrice: price)
        let gross = profit(position: position, price: exitPrice, spec: spec)
        let closeCommission = position.lots * spec.commissionPerLotPerSide
        let swap = position.direction == .buy ? position.lots * spec.swapLongPerLot : position.lots * spec.swapShortPerLot
        let balanceDelta = gross - closeCommission + swap
        let realized = balanceDelta - position.openCommission
        balance += balanceDelta
        grossProfit += max(0, gross)
        grossLoss += min(0, gross)
        totalTrades += 1
        if realized >= 0 {
            winningTrades += 1
        } else {
            losingTrades += 1
        }
    }

    private mutating func recomputeEquity() throws {
        var floating = 0.0
        for position in positions {
            let spec = try context.executionSpec(for: position.symbol, fallbackDigits: position.digits)
            let price = currentPrices[position.symbol] ?? position.entryPrice
            let exitPrice = spec.executablePrice(side: position.direction.orderSide, action: .close, midPrice: price)
            floating += profit(position: position, price: exitPrice, spec: spec)
        }
        equity = balance + floating
        equityPeak = max(equityPeak, equity)
        maxDrawdown = max(maxDrawdown, equityPeak - equity)
    }

    private func profit(position: FXStupidPosition, price: Int64, spec: FXBacktestSymbolExecutionSpec) -> Double {
        let direction = Double(position.direction.rawValue)
        let priceDelta = Double(price - position.entryPrice) / spec.priceScale
        return direction * priceDelta * spec.contractSize * position.lots
    }
}

private struct FXStupidPosition: Sendable, Hashable {
    let symbol: String
    let direction: FXStupidDirection
    let entryPrice: Int64
    let lots: Double
    let digits: Int
    let openCommission: Double
}

private enum FXStupidDirection: Int, Sendable {
    case buy = 1
    case sell = -1

    var orderSide: FXBacktestOrderSide {
        switch self {
        case .buy:
            return .buy
        case .sell:
            return .sell
        }
    }
}

private struct FXStupidInputs {
    let maxOrders: Int
    let barsLookBack: Int
    let trailStop: Int
    let trailStepUp: Double
    let trailStepDown: Double
    let lotSize: Double
    let eaEquiTP: Double
    let eaEquiSL: Double
    let lotBooster: Double
    let eaStopMaxDD: Double
    let eaStopMinEqui: Double

    init(config: FXStupidConfig, parameters: ParameterVector) {
        self.maxOrders = max(0, Int(Self.value("MaxOrders", config: config, parameters: parameters).rounded()))
        self.barsLookBack = max(1, Int(Self.value("BarsLookBack", config: config, parameters: parameters).rounded()))
        self.trailStop = Int(Self.value("TrailStop", config: config, parameters: parameters).rounded())
        self.trailStepUp = Self.value("TrailStepUp", config: config, parameters: parameters)
        self.trailStepDown = Self.value("TrailStepDown", config: config, parameters: parameters)
        self.lotSize = max(0, Self.value("LotSize", config: config, parameters: parameters))
        self.eaEquiTP = Self.value("EAEqui_TP", config: config, parameters: parameters)
        self.eaEquiSL = Self.value("EAEqui_SL", config: config, parameters: parameters)
        self.lotBooster = Self.value("LotBooster", config: config, parameters: parameters)
        self.eaStopMaxDD = Self.value("EAStopMaxDD", config: config, parameters: parameters)
        self.eaStopMinEqui = Self.value("EAStopMinEqui", config: config, parameters: parameters)
    }

    private static func value(_ key: String, config: FXStupidConfig, parameters: ParameterVector) -> Double {
        parameters[key] ?? config.numericInputs.first(where: { $0.key == key })?.value ?? 0
    }
}

private struct FXStupidConfig: Decodable {
    let descriptor: Descriptor
    let fxpairs: String
    let signalTimeframe: String
    let numericInputs: [NumericInput]

    enum CodingKeys: String, CodingKey {
        case descriptor
        case fxpairs
        case signalTimeframe = "signal_timeframe"
        case numericInputs = "numeric_inputs"
    }

    static func load() -> FXStupidConfig {
        let decoder = JSONDecoder()
        let url = Bundle.module.url(forResource: "FXStupid.config", withExtension: "json", subdirectory: "FXStupid")
            ?? Bundle.module.url(forResource: "FXStupid.config", withExtension: "json")
        guard let url else {
            fatalError("Missing FXStupid.config.json resource.")
        }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(FXStupidConfig.self, from: data)
        } catch {
            fatalError("Could not load FXStupid.config.json: \(error)")
        }
    }

    struct Descriptor: Decodable {
        let id: String
        let displayName: String
        let version: String
        let summary: String
        let author: String

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case version
            case summary
            case author
        }
    }

    struct NumericInput: Decodable {
        let key: String
        let displayName: String
        let valueKind: String
        let value: Double
        let minimum: Double
        let step: Double
        let maximum: Double

        enum CodingKeys: String, CodingKey {
            case key
            case displayName = "display_name"
            case valueKind = "value_kind"
            case value
            case minimum
            case step
            case maximum
        }

        var parameterKind: ParameterValueKind {
            switch valueKind {
            case "integer":
                return .integer
            case "boolean":
                return .boolean
            default:
                return .decimal
            }
        }
    }
}

private enum FXStupidResultFlag: UInt32 {
    case hardStopped = 1
    case unsupportedTimeframe = 2
}
