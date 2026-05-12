import Foundation
import FXBacktestAPI

public struct FXBacktestMarketMetadata: Hashable, Sendable {
    public let brokerSourceId: String
    public let logicalSymbol: String
    public let mt5Symbol: String?
    public let timeframe: String
    public let digits: Int
    public let firstUtc: Int64?
    public let lastUtc: Int64?

    public init(
        brokerSourceId: String,
        logicalSymbol: String,
        mt5Symbol: String? = nil,
        timeframe: String = "M1",
        digits: Int,
        firstUtc: Int64? = nil,
        lastUtc: Int64? = nil
    ) {
        self.brokerSourceId = brokerSourceId
        self.logicalSymbol = logicalSymbol
        self.mt5Symbol = mt5Symbol
        self.timeframe = timeframe
        self.digits = digits
        self.firstUtc = firstUtc
        self.lastUtc = lastUtc
    }
}

public struct OhlcBar: Sendable, Hashable {
    public let utcTimestamp: Int64
    public let open: Int64
    public let high: Int64
    public let low: Int64
    public let close: Int64

    public init(utcTimestamp: Int64, open: Int64, high: Int64, low: Int64, close: Int64) {
        self.utcTimestamp = utcTimestamp
        self.open = open
        self.high = high
        self.low = low
        self.close = close
    }
}

public struct OhlcDataSeries: Sendable {
    public let metadata: FXBacktestMarketMetadata
    public let utcTimestamps: ContiguousArray<Int64>
    public let open: ContiguousArray<Int64>
    public let high: ContiguousArray<Int64>
    public let low: ContiguousArray<Int64>
    public let close: ContiguousArray<Int64>

    @inlinable public var count: Int { utcTimestamps.count }
    @inlinable public var isEmpty: Bool { count == 0 }

    public init(
        metadata: FXBacktestMarketMetadata,
        utcTimestamps: ContiguousArray<Int64>,
        open: ContiguousArray<Int64>,
        high: ContiguousArray<Int64>,
        low: ContiguousArray<Int64>,
        close: ContiguousArray<Int64>
    ) throws {
        guard (0...10).contains(metadata.digits) else {
            throw FXBacktestError.invalidMarketData("Price digits must be in 0...10.")
        }
        let rowCount = utcTimestamps.count
        guard open.count == rowCount, high.count == rowCount, low.count == rowCount, close.count == rowCount else {
            throw FXBacktestError.invalidMarketData("OHLC columns must have equal length.")
        }
        for index in 0..<rowCount {
            if index > 0, utcTimestamps[index] <= utcTimestamps[index - 1] {
                throw FXBacktestError.invalidMarketData("UTC timestamps must be strictly increasing.")
            }
            if high[index] < open[index] || high[index] < close[index] || low[index] > open[index] || low[index] > close[index] {
                throw FXBacktestError.invalidMarketData("OHLC invariant failed at bar \(index).")
            }
        }
        self.metadata = metadata
        self.utcTimestamps = utcTimestamps
        self.open = open
        self.high = high
        self.low = low
        self.close = close
    }

    public init(response: FXBacktestM1HistoryResponse) throws {
        try response.validate()
        try self.init(
            metadata: FXBacktestMarketMetadata(
                brokerSourceId: response.metadata.brokerSourceId,
                logicalSymbol: response.metadata.logicalSymbol,
                mt5Symbol: response.metadata.mt5Symbol,
                timeframe: response.metadata.timeframe,
                digits: response.metadata.digits,
                firstUtc: response.metadata.firstUtc,
                lastUtc: response.metadata.lastUtc
            ),
            utcTimestamps: ContiguousArray(response.utcTimestamps),
            open: ContiguousArray(response.open),
            high: ContiguousArray(response.high),
            low: ContiguousArray(response.low),
            close: ContiguousArray(response.close)
        )
    }

    @inlinable public func bar(at index: Int) -> OhlcBar {
        OhlcBar(
            utcTimestamp: utcTimestamps[index],
            open: open[index],
            high: high[index],
            low: low[index],
            close: close[index]
        )
    }
}

public extension OhlcDataSeries {
    static func demoEURUSD(barCount: Int = 3_000) throws -> OhlcDataSeries {
        let safeCount = max(300, barCount)
        let start = Int64(1_704_067_200)
        var utc = ContiguousArray<Int64>()
        var open = ContiguousArray<Int64>()
        var high = ContiguousArray<Int64>()
        var low = ContiguousArray<Int64>()
        var close = ContiguousArray<Int64>()
        utc.reserveCapacity(safeCount)
        open.reserveCapacity(safeCount)
        high.reserveCapacity(safeCount)
        low.reserveCapacity(safeCount)
        close.reserveCapacity(safeCount)

        var price = Int64(108_000)
        for index in 0..<safeCount {
            let cycle = Int64((index % 144) - 72)
            let drift = Int64(index / 500)
            let move = (cycle / 9) + (index % 17 == 0 ? 7 : -2) + drift
            let barOpen = price
            let barClose = max(90_000, price + move)
            let barHigh = max(barOpen, barClose) + Int64(5 + (index % 6))
            let barLow = min(barOpen, barClose) - Int64(5 + (index % 4))
            utc.append(start + Int64(index * 60))
            open.append(barOpen)
            high.append(barHigh)
            low.append(barLow)
            close.append(barClose)
            price = barClose
        }

        return try OhlcDataSeries(
            metadata: FXBacktestMarketMetadata(
                brokerSourceId: "demo",
                logicalSymbol: "EURUSD",
                mt5Symbol: "EURUSD",
                digits: 5,
                firstUtc: utc.first,
                lastUtc: utc.last
            ),
            utcTimestamps: utc,
            open: open,
            high: high,
            low: low,
            close: close
        )
    }
}
