import BacktestCore
import ClickHouse
import Domain
import Foundation

public struct FXExportConnectionSettings: Codable, Hashable, Sendable {
    public var url: URL
    public var database: String
    public var username: String
    public var password: String
    public var requestTimeoutSeconds: Double

    public init(
        url: URL = URL(string: "http://127.0.0.1:8123")!,
        database: String = "fxexport",
        username: String = "",
        password: String = "",
        requestTimeoutSeconds: Double = 60
    ) {
        self.url = url
        self.database = database
        self.username = username
        self.password = password
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
        let client = SimpleClickHouseHTTPClient(settings: connection)
        let provider = ClickHouseHistoricalOhlcDataProvider(
            client: client,
            database: connection.database,
            defaultMaximumRows: request.maximumRows
        )
        let historyRequest = try HistoricalOhlcRequest(
            brokerSourceId: try BrokerSourceId(request.brokerSourceId),
            logicalSymbol: try LogicalSymbol(request.logicalSymbol),
            utcStartInclusive: UtcSecond(rawValue: request.utcStartInclusive),
            utcEndExclusive: UtcSecond(rawValue: request.utcEndExclusive),
            expectedMT5Symbol: request.expectedMT5Symbol.isEmpty ? nil : try MT5Symbol(request.expectedMT5Symbol),
            expectedDigits: try Digits(request.expectedDigits),
            maximumRows: request.maximumRows,
            allowEmpty: false
        )
        do {
            let series = try await provider.loadM1Ohlc(historyRequest)
            return try OhlcDataSeries(series: series)
        } catch {
            throw FXBacktestError.dataLoadFailed(String(describing: error))
        }
    }
}

private struct SimpleClickHouseHTTPClient: ClickHouseClientProtocol, Sendable {
    let settings: FXExportConnectionSettings

    func execute(_ query: ClickHouseQuery) async throws -> String {
        var request = URLRequest(url: settings.url)
        request.httpMethod = "POST"
        request.timeoutInterval = settings.requestTimeoutSeconds
        request.httpBody = query.sql.data(using: .utf8)

        if !settings.username.isEmpty {
            let token = "\(settings.username):\(settings.password)"
            let encoded = Data(token.utf8).base64EncodedString()
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FXBacktestError.dataLoadFailed(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FXBacktestError.dataLoadFailed("ClickHouse response was not HTTP.")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw FXBacktestError.dataLoadFailed("ClickHouse HTTP \(httpResponse.statusCode): \(body)")
        }
        return body
    }
}
