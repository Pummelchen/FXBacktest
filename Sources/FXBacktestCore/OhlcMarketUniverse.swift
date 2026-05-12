import Foundation

public struct OhlcMarketUniverse: Sendable {
    public let primarySymbol: String
    public let seriesBySymbol: [String: OhlcDataSeries]
    public let symbols: [String]

    public init(primarySymbol: String? = nil, series: [OhlcDataSeries], requireAlignedTimestamps: Bool = true) throws {
        guard !series.isEmpty else {
            throw FXBacktestError.invalidMarketData("Market universe requires at least one OHLC series.")
        }

        var bySymbol: [String: OhlcDataSeries] = [:]
        bySymbol.reserveCapacity(series.count)
        for item in series {
            let symbol = item.metadata.logicalSymbol.uppercased()
            guard bySymbol[symbol] == nil else {
                throw FXBacktestError.invalidMarketData("Duplicate market series for \(symbol).")
            }
            bySymbol[symbol] = item
        }

        let requestedPrimary = (primarySymbol ?? series[0].metadata.logicalSymbol).uppercased()
        guard bySymbol[requestedPrimary] != nil else {
            throw FXBacktestError.invalidMarketData("Primary market symbol \(requestedPrimary) is not present in the universe.")
        }

        if requireAlignedTimestamps {
            try Self.validateAligned(series: series)
        }

        self.primarySymbol = requestedPrimary
        self.seriesBySymbol = bySymbol
        self.symbols = bySymbol.keys.sorted()
    }

    public init(single series: OhlcDataSeries) {
        let symbol = series.metadata.logicalSymbol.uppercased()
        self.primarySymbol = symbol
        self.seriesBySymbol = [symbol: series]
        self.symbols = [symbol]
    }

    public var primary: OhlcDataSeries {
        seriesBySymbol[primarySymbol]!
    }

    public var count: Int {
        primary.count
    }

    public subscript(symbol: String) -> OhlcDataSeries? {
        seriesBySymbol[symbol.uppercased()]
    }

    public func close(symbol: String, at index: Int) -> Int64? {
        guard let series = seriesBySymbol[symbol.uppercased()],
              index >= 0,
              index < series.count else {
            return nil
        }
        return series.close[index]
    }

    public func closes(symbol: String, range: Range<Int>) -> [Int64]? {
        guard let series = seriesBySymbol[symbol.uppercased()],
              range.lowerBound >= 0,
              range.upperBound <= series.count else {
            return nil
        }
        return Array(series.close[range])
    }

    public func digitsBySymbol() -> [String: Int] {
        Dictionary(uniqueKeysWithValues: seriesBySymbol.map { ($0.key, $0.value.metadata.digits) })
    }

    private static func validateAligned(series: [OhlcDataSeries]) throws {
        guard let reference = series.first else { return }
        for candidate in series.dropFirst() {
            guard candidate.count == reference.count else {
                throw FXBacktestError.invalidMarketData("\(candidate.metadata.logicalSymbol) bar count \(candidate.count) does not match primary count \(reference.count).")
            }
            for index in 0..<reference.count where candidate.utcTimestamps[index] != reference.utcTimestamps[index] {
                throw FXBacktestError.invalidMarketData("\(candidate.metadata.logicalSymbol) timestamp mismatch at bar \(index).")
            }
        }
    }
}

public extension OhlcDataSeries {
    var universe: OhlcMarketUniverse {
        OhlcMarketUniverse(single: self)
    }
}
