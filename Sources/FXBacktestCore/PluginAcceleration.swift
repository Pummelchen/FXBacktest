import Foundation

public enum PluginAccelerationBackend: String, Codable, CaseIterable, Sendable {
    case swiftScalar
    case swiftSIMD
    case metal
}

public enum PluginAccelerationSafety: String, Codable, CaseIterable, Sendable {
    case deterministicWholePass
    case unsupportedForPlugin
}

public struct PluginAccelerationInputColumn: Codable, Hashable, Sendable {
    public let symbol: String?
    public let field: String

    public init(symbol: String? = nil, field: String) {
        self.symbol = symbol?.uppercased()
        self.field = field
    }
}

public struct PluginAccelerationIROperation: Codable, Hashable, Sendable {
    public let opcode: String
    public let inputs: [String]
    public let outputs: [String]
    public let constants: [String: Double]

    public init(opcode: String, inputs: [String] = [], outputs: [String] = [], constants: [String: Double] = [:]) {
        self.opcode = opcode
        self.inputs = inputs
        self.outputs = outputs
        self.constants = constants
    }
}

public struct PluginAccelerationIR: Codable, Hashable, Sendable {
    public let version: String
    public let requiredColumns: [PluginAccelerationInputColumn]
    public let operations: [PluginAccelerationIROperation]

    public init(
        version: String = "fxbacktest.plugin-ir.v1",
        requiredColumns: [PluginAccelerationInputColumn],
        operations: [PluginAccelerationIROperation]
    ) {
        self.version = version
        self.requiredColumns = requiredColumns
        self.operations = operations
    }
}

public struct PluginAccelerationDescriptor: Codable, Hashable, Sendable {
    public let pluginIdentifier: String
    public let apiVersion: String
    public let supportedBackends: [PluginAccelerationBackend]
    public let safety: PluginAccelerationSafety
    public let metalEntryPoint: String?
    public let ir: PluginAccelerationIR?

    public init(
        pluginIdentifier: String,
        apiVersion: String = "fxbacktest.plugin-acceleration.v1",
        supportedBackends: [PluginAccelerationBackend] = [.swiftScalar],
        safety: PluginAccelerationSafety = .deterministicWholePass,
        metalEntryPoint: String? = nil,
        ir: PluginAccelerationIR? = nil
    ) {
        self.pluginIdentifier = pluginIdentifier
        self.apiVersion = apiVersion
        self.supportedBackends = supportedBackends
        self.safety = safety
        self.metalEntryPoint = metalEntryPoint
        self.ir = ir
    }

    public var supportsGeneratedMetal: Bool {
        supportedBackends.contains(.metal) && metalEntryPoint != nil
    }
}

public struct PluginAccelerationPipeline: Sendable {
    public init() {}

    public func validate(_ descriptor: PluginAccelerationDescriptor) throws {
        guard descriptor.apiVersion == "fxbacktest.plugin-acceleration.v1" else {
            throw FXBacktestError.invalidParameter("Unsupported plugin acceleration API \(descriptor.apiVersion).")
        }
        guard !descriptor.pluginIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FXBacktestError.invalidParameter("Acceleration descriptor plugin id must not be empty.")
        }
        guard !descriptor.supportedBackends.isEmpty else {
            throw FXBacktestError.invalidParameter("Acceleration descriptor must declare at least one backend.")
        }
        if descriptor.supportedBackends.contains(.metal) {
            guard descriptor.metalEntryPoint != nil || descriptor.ir != nil else {
                throw FXBacktestError.invalidParameter("Metal acceleration requires either a Metal entry point or plugin IR.")
            }
        }
        if let ir = descriptor.ir {
            guard ir.version == "fxbacktest.plugin-ir.v1" else {
                throw FXBacktestError.invalidParameter("Unsupported plugin IR \(ir.version).")
            }
            guard !ir.operations.isEmpty else {
                throw FXBacktestError.invalidParameter("Plugin IR must contain at least one operation.")
            }
        }
    }
}
