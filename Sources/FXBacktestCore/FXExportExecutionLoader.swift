import Foundation
import FXBacktestAPI

public struct FXExportExecutionSymbolRequest: Codable, Hashable, Sendable {
    public var logicalSymbol: String
    public var expectedMT5Symbol: String?
    public var expectedDigits: Int?

    public init(logicalSymbol: String, expectedMT5Symbol: String? = nil, expectedDigits: Int? = nil) {
        self.logicalSymbol = logicalSymbol
        self.expectedMT5Symbol = expectedMT5Symbol
        self.expectedDigits = expectedDigits
    }
}

public struct FXExportExecutionRequest: Codable, Hashable, Sendable {
    public var brokerSourceId: String
    public var symbols: [FXExportExecutionSymbolRequest]

    public init(brokerSourceId: String, symbols: [FXExportExecutionSymbolRequest]) {
        self.brokerSourceId = brokerSourceId
        self.symbols = symbols
    }
}

public struct FXExportExecutionLoader: Sendable {
    public init() {}

    public func load(
        connection: FXExportConnectionSettings,
        request: FXExportExecutionRequest
    ) async throws -> FXBacktestExecutionProfile {
        do {
            let apiRequest = FXBacktestExecutionSpecRequest(
                brokerSourceId: request.brokerSourceId,
                symbols: request.symbols.map {
                    FXBacktestExecutionSymbolRequest(
                        logicalSymbol: $0.logicalSymbol,
                        expectedMT5Symbol: $0.expectedMT5Symbol,
                        expectedDigits: $0.expectedDigits
                    )
                }
            )
            let response = try await FXBacktestAPIClient(
                baseURL: connection.apiBaseURL,
                requestTimeoutSeconds: connection.requestTimeoutSeconds
            )
                .loadExecutionSpec(apiRequest)
            return try Self.executionProfile(from: response)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FXBacktestError.dataLoadFailed(String(describing: error))
        }
    }

    public static func executionProfile(from response: FXBacktestExecutionSpecResponse) throws -> FXBacktestExecutionProfile {
        try response.validate()
        var specs: [String: FXBacktestSymbolExecutionSpec] = [:]
        specs.reserveCapacity(response.symbols.count)
        for symbol in response.symbols {
            let marginInitial = Self.firstPositive([
                symbol.marginInitialPerLot,
                symbol.marginBuyPerLot,
                symbol.marginSellPerLot
            ])
            specs[symbol.logicalSymbol.uppercased()] = try FXBacktestSymbolExecutionSpec(
                logicalSymbol: symbol.logicalSymbol,
                mt5Symbol: symbol.mt5Symbol,
                digits: symbol.digits,
                contractSize: symbol.contractSize,
                minLot: symbol.volumeMin,
                lotStep: symbol.volumeStep,
                maxLot: symbol.volumeMax,
                spreadPoints: Int64(symbol.spreadPoints),
                slippagePoints: Int64(symbol.slippagePoints),
                commissionPerLotPerSide: symbol.commissionPerLotPerSide ?? 0,
                commissionSource: symbol.commissionSource,
                slippageSource: symbol.slippageSource,
                swapLongPerLot: symbol.swapLongPerLot,
                swapShortPerLot: symbol.swapShortPerLot,
                marginInitialPerLot: marginInitial,
                marginRate: 1.0 / response.accountLeverage,
                bid: symbol.bid,
                ask: symbol.ask,
                capturedAtUtc: response.capturedAtUtc
            )
        }
        return try FXBacktestExecutionProfile(
            brokerSourceId: response.brokerSourceId,
            depositCurrency: response.accountCurrency,
            leverage: response.accountLeverage,
            accountingMode: .hedging,
            symbols: specs
        )
    }

    private static func firstPositive(_ values: [Double?]) -> Double? {
        values.compactMap { value -> Double? in
            guard let value, value.isFinite, value > 0 else { return nil }
            return value
        }.first
    }
}
