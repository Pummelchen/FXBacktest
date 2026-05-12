import Foundation

public enum FXBacktestError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalidMarketData(String)
    case invalidParameter(String)
    case invalidSweep(String)
    case pluginFailed(String)
    case metalUnavailable
    case metalKernelMissing(plugin: String)
    case metalFailed(String)
    case dataLoadFailed(String)

    public var description: String {
        switch self {
        case .invalidMarketData(let reason):
            return "Invalid market data: \(reason)"
        case .invalidParameter(let reason):
            return "Invalid parameter: \(reason)"
        case .invalidSweep(let reason):
            return "Invalid parameter sweep: \(reason)"
        case .pluginFailed(let reason):
            return "Plugin failed: \(reason)"
        case .metalUnavailable:
            return "Metal acceleration is unavailable on this machine."
        case .metalKernelMissing(let plugin):
            return "Plugin \(plugin) does not provide a Metal kernel."
        case .metalFailed(let reason):
            return "Metal execution failed: \(reason)"
        case .dataLoadFailed(let reason):
            return "History data load failed: \(reason)"
        }
    }
}
