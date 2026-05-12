import Foundation

public enum FXBacktestPluginAPIVersion: String, Codable, Sendable {
    case v1 = "fxbacktest.plugin-api.v1"
}

public struct FXBacktestPluginDescriptor: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let version: String
    public let apiVersion: FXBacktestPluginAPIVersion
    public let summary: String
    public let author: String
    public let supportsCPU: Bool
    public let supportsMetal: Bool

    public init(
        id: String,
        displayName: String,
        version: String,
        apiVersion: FXBacktestPluginAPIVersion = .v1,
        summary: String,
        author: String,
        supportsCPU: Bool = true,
        supportsMetal: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.apiVersion = apiVersion
        self.summary = summary
        self.author = author
        self.supportsCPU = supportsCPU
        self.supportsMetal = supportsMetal
    }
}

public struct MetalKernelV1: Hashable, Sendable {
    public let source: String
    public let entryPoint: String
    public let maxPassesPerCommandBuffer: Int

    public init(source: String, entryPoint: String, maxPassesPerCommandBuffer: Int = 16_384) {
        self.source = source
        self.entryPoint = entryPoint
        self.maxPassesPerCommandBuffer = max(1, maxPassesPerCommandBuffer)
    }
}

public protocol FXBacktestPluginV1: Sendable {
    var descriptor: FXBacktestPluginDescriptor { get }
    var parameterDefinitions: [ParameterDefinition] { get }
    var metalKernel: MetalKernelV1? { get }
    var accelerationDescriptor: PluginAccelerationDescriptor { get }

    func runPass(
        market: OhlcDataSeries,
        parameters: ParameterVector,
        context: BacktestContext
    ) throws -> BacktestPassResult

    func runPass(
        marketUniverse: OhlcMarketUniverse,
        parameters: ParameterVector,
        context: BacktestContext
    ) throws -> BacktestPassResult
}

public extension FXBacktestPluginV1 {
    var metalKernel: MetalKernelV1? { nil }

    var accelerationDescriptor: PluginAccelerationDescriptor {
        PluginAccelerationDescriptor(pluginIdentifier: descriptor.id)
    }

    func runPass(
        marketUniverse: OhlcMarketUniverse,
        parameters: ParameterVector,
        context: BacktestContext
    ) throws -> BacktestPassResult {
        try runPass(market: marketUniverse.primary, parameters: parameters, context: context)
    }
}

public struct AnyFXBacktestPlugin: FXBacktestPluginV1, Identifiable {
    public let id: String
    public let descriptor: FXBacktestPluginDescriptor
    public let parameterDefinitions: [ParameterDefinition]
    public let metalKernel: MetalKernelV1?
    public let accelerationDescriptor: PluginAccelerationDescriptor
    private let runPassClosure: @Sendable (OhlcDataSeries, ParameterVector, BacktestContext) throws -> BacktestPassResult
    private let runUniversePassClosure: @Sendable (OhlcMarketUniverse, ParameterVector, BacktestContext) throws -> BacktestPassResult

    public init<P: FXBacktestPluginV1>(_ plugin: P) {
        self.id = plugin.descriptor.id
        self.descriptor = plugin.descriptor
        self.parameterDefinitions = plugin.parameterDefinitions
        self.metalKernel = plugin.metalKernel
        self.accelerationDescriptor = plugin.accelerationDescriptor
        self.runPassClosure = { market, parameters, context in
            try plugin.runPass(market: market, parameters: parameters, context: context)
        }
        self.runUniversePassClosure = { marketUniverse, parameters, context in
            try plugin.runPass(marketUniverse: marketUniverse, parameters: parameters, context: context)
        }
    }

    public func runPass(
        market: OhlcDataSeries,
        parameters: ParameterVector,
        context: BacktestContext
    ) throws -> BacktestPassResult {
        try runPassClosure(market, parameters, context)
    }

    public func runPass(
        marketUniverse: OhlcMarketUniverse,
        parameters: ParameterVector,
        context: BacktestContext
    ) throws -> BacktestPassResult {
        try runUniversePassClosure(marketUniverse, parameters, context)
    }
}
