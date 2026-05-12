import Foundation

public enum FXBacktestAgentKind: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case fxExportConnectivity
    case marketReadiness
    case executionSnapshot
    case optimizationRunCoordinator
    case resultPersistence
    case pluginValidation
    case resourceHealth

    public var id: String { rawValue }
}

public enum FXBacktestAgentStatus: String, Codable, CaseIterable, Sendable {
    case ok
    case warning
    case failed
}

public struct FXBacktestAgentDescriptor: Codable, Hashable, Identifiable, Sendable {
    public let id: FXBacktestAgentKind
    public let displayName: String
    public let responsibility: String

    public init(id: FXBacktestAgentKind, displayName: String, responsibility: String) {
        self.id = id
        self.displayName = displayName
        self.responsibility = responsibility
    }
}

public struct FXBacktestAgentOutcome: Codable, Hashable, Identifiable, Sendable {
    public var id: FXBacktestAgentKind { kind }

    public let kind: FXBacktestAgentKind
    public let displayName: String
    public let status: FXBacktestAgentStatus
    public let message: String
    public let details: [String]
    public let startedAtUtc: Date
    public let finishedAtUtc: Date

    public init(
        descriptor: FXBacktestAgentDescriptor,
        status: FXBacktestAgentStatus,
        message: String,
        details: [String] = [],
        startedAtUtc: Date = Date(),
        finishedAtUtc: Date = Date()
    ) {
        self.kind = descriptor.id
        self.displayName = descriptor.displayName
        self.status = status
        self.message = message
        self.details = details
        self.startedAtUtc = startedAtUtc
        self.finishedAtUtc = finishedAtUtc
    }

    public var isBlockingFailure: Bool {
        status == .failed
    }

    public var durationSeconds: Double {
        max(0, finishedAtUtc.timeIntervalSince(startedAtUtc))
    }
}

public actor FXBacktestAgentRuntime {
    private var outcomes: [FXBacktestAgentKind: FXBacktestAgentOutcome] = [:]

    public init() {}

    public func record(_ outcome: FXBacktestAgentOutcome) {
        outcomes[outcome.kind] = outcome
    }

    public func snapshot() -> [FXBacktestAgentKind: FXBacktestAgentOutcome] {
        outcomes
    }

    public func outcome(for kind: FXBacktestAgentKind) -> FXBacktestAgentOutcome? {
        outcomes[kind]
    }
}
