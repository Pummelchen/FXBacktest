import Foundation
import FXBacktestAPI

public struct FXExportConnectionSettings: Codable, Hashable, Sendable {
    public var apiBaseURL: URL
    public var requestTimeoutSeconds: Double

    public init(
        apiBaseURL: URL = URL(string: "http://127.0.0.1:5066")!,
        requestTimeoutSeconds: Double = 120
    ) {
        self.apiBaseURL = apiBaseURL
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }
}

public struct FXExportHistoryRequest: Codable, Hashable, Sendable {
    public var brokerSourceId: String
    public var logicalSymbol: String
    public var expectedMT5Symbol: String
    public var expectedDigits: Int
    public var utcStartInclusive: Int64
    public var utcEndExclusive: Int64
    public var maximumRows: Int

    public init(
        brokerSourceId: String = "icmarkets-sc-mt5-4",
        logicalSymbol: String = "EURUSD",
        expectedMT5Symbol: String = "EURUSD",
        expectedDigits: Int = 5,
        utcStartInclusive: Int64 = 1_704_067_200,
        utcEndExclusive: Int64 = 1_707_177_600,
        maximumRows: Int = 5_000_000
    ) {
        self.brokerSourceId = brokerSourceId
        self.logicalSymbol = logicalSymbol
        self.expectedMT5Symbol = expectedMT5Symbol
        self.expectedDigits = expectedDigits
        self.utcStartInclusive = utcStartInclusive
        self.utcEndExclusive = utcEndExclusive
        self.maximumRows = maximumRows
    }
}

public struct FXExportHistoryLoader: Sendable {
    public init() {}

    public func load(
        connection: FXExportConnectionSettings,
        request: FXExportHistoryRequest
    ) async throws -> OhlcDataSeries {
        do {
            let apiRequest = FXBacktestM1HistoryRequest(
                brokerSourceId: request.brokerSourceId,
                logicalSymbol: request.logicalSymbol,
                utcStartInclusive: request.utcStartInclusive,
                utcEndExclusive: request.utcEndExclusive,
                expectedMT5Symbol: request.expectedMT5Symbol.isEmpty ? nil : request.expectedMT5Symbol,
                expectedDigits: request.expectedDigits,
                maximumRows: request.maximumRows
            )
            let response = try await FXBacktestAPIClient(
                baseURL: connection.apiBaseURL,
                requestTimeoutSeconds: connection.requestTimeoutSeconds
            )
                .loadM1History(apiRequest)
            return try OhlcDataSeries(response: response)
        } catch {
            throw FXBacktestError.dataLoadFailed(String(describing: error))
        }
    }
}
