import Foundation

public enum ParameterValueKind: String, Codable, CaseIterable, Sendable {
    case integer
    case decimal
    case boolean
}

public struct ParameterDefinition: Identifiable, Codable, Hashable, Sendable {
    public var id: String { key }
    public let key: String
    public let displayName: String
    public let defaultValue: Double
    public let defaultMinimum: Double
    public let defaultStep: Double
    public let defaultMaximum: Double
    public let valueKind: ParameterValueKind

    public init(
        key: String,
        displayName: String,
        defaultValue: Double,
        defaultMinimum: Double,
        defaultStep: Double,
        defaultMaximum: Double,
        valueKind: ParameterValueKind
    ) throws {
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            throw FXBacktestError.invalidParameter("Parameter key must be non-empty and contain only letters, numbers, or underscore.")
        }
        self.key = key
        self.displayName = displayName
        self.defaultValue = defaultValue
        self.defaultMinimum = defaultMinimum
        self.defaultStep = defaultStep
        self.defaultMaximum = defaultMaximum
        self.valueKind = valueKind
        _ = try ParameterSweepDimension(definition: self, input: defaultValue, minimum: defaultMinimum, step: defaultStep, maximum: defaultMaximum)
    }
}

public struct ParameterSweepDimension: Identifiable, Codable, Hashable, Sendable {
    public var id: String { definition.key }
    public let definition: ParameterDefinition
    public var input: Double
    public var minimum: Double
    public var step: Double
    public var maximum: Double

    public init(definition: ParameterDefinition, input: Double, minimum: Double, step: Double, maximum: Double) throws {
        self.definition = definition
        self.input = input
        self.minimum = minimum
        self.step = step
        self.maximum = maximum
        try validate()
    }

    public var valueCount: UInt64 {
        (try? checkedValueCount()) ?? 0
    }

    fileprivate func checkedValueCount() throws -> UInt64 {
        guard minimum.isFinite, step.isFinite, maximum.isFinite else {
            throw FXBacktestError.invalidParameter("\(definition.key): min, step, and max must be finite numbers.")
        }
        guard minimum <= maximum else {
            throw FXBacktestError.invalidParameter("\(definition.key): minimum must be <= maximum.")
        }
        guard step > 0 else {
            throw FXBacktestError.invalidParameter("\(definition.key): step must be > 0.")
        }
        if definition.valueKind == .boolean {
            return minimum == maximum ? 1 : 2
        }
        let span = maximum - minimum
        if span == 0 {
            return 1
        }
        let count = floor((span / step) + 1.0e-9) + 1
        guard count.isFinite, count > 0, count <= Double(UInt64.max) else {
            throw FXBacktestError.invalidParameter("\(definition.key): parameter value count is too large.")
        }
        return UInt64(count)
    }

    public func value(at offset: UInt64) -> Double {
        if definition.valueKind == .boolean {
            return offset == 0 ? minimum : maximum
        }
        let value = minimum + (Double(offset) * step)
        let clamped = min(maximum, value)
        switch definition.valueKind {
        case .integer:
            return clamped.rounded()
        case .decimal:
            return clamped
        case .boolean:
            return clamped == 0 ? 0 : 1
        }
    }

    fileprivate func validate() throws {
        _ = try checkedValueCount()
        guard input.isFinite else {
            throw FXBacktestError.invalidParameter("\(definition.key): input must be a finite number.")
        }
        guard input >= minimum, input <= maximum else {
            throw FXBacktestError.invalidParameter("\(definition.key): input must be inside the optimization range.")
        }
        if definition.valueKind == .boolean {
            guard [0, 1].contains(minimum), [0, 1].contains(maximum), [0, 1].contains(input) else {
                throw FXBacktestError.invalidParameter("\(definition.key): boolean parameters must use 0 or 1.")
            }
        }
        if definition.valueKind == .integer {
            let values = [("input", input), ("minimum", minimum), ("step", step), ("maximum", maximum)]
            for (label, value) in values where value.rounded() != value {
                throw FXBacktestError.invalidParameter("\(definition.key): \(label) must be an integer value.")
            }
        }
    }
}

public struct ParameterVector: Sendable, Hashable {
    public let combinationIndex: UInt64
    public let names: [String]
    public let values: ContiguousArray<Double>

    public init(combinationIndex: UInt64, names: [String], values: ContiguousArray<Double>) {
        self.combinationIndex = combinationIndex
        self.names = names
        self.values = values
    }

    @inlinable public subscript(index: Int) -> Double {
        values[index]
    }

    public subscript(name: String) -> Double? {
        guard let index = names.firstIndex(of: name) else { return nil }
        return values[index]
    }

    public var snapshots: [BacktestParameterValue] {
        names.enumerated().map { index, name in
            BacktestParameterValue(key: name, value: values[index])
        }
    }
}

public struct BacktestParameterValue: Codable, Hashable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let value: Double

    public init(key: String, value: Double) {
        self.key = key
        self.value = value
    }
}

public struct ParameterSweep: Codable, Hashable, Sendable {
    public let dimensions: [ParameterSweepDimension]
    public let combinationCount: UInt64
    private let names: [String]
    private let radices: [UInt64]

    public init(dimensions: [ParameterSweepDimension]) throws {
        guard !dimensions.isEmpty else {
            throw FXBacktestError.invalidSweep("At least one parameter is required.")
        }
        let keys = dimensions.map(\.definition.key)
        guard Set(keys).count == keys.count else {
            throw FXBacktestError.invalidSweep("Parameter keys must be unique.")
        }

        var total: UInt64 = 1
        var localRadices: [UInt64] = []
        localRadices.reserveCapacity(dimensions.count)
        for dimension in dimensions {
            try dimension.validate()
            let count = try dimension.checkedValueCount()
            guard count > 0 else {
                throw FXBacktestError.invalidSweep("\(dimension.definition.key) has no values.")
            }
            guard total <= UInt64.max / count else {
                throw FXBacktestError.invalidSweep("Parameter combination count overflows UInt64.")
            }
            localRadices.append(count)
            total *= count
        }
        self.dimensions = dimensions
        self.combinationCount = total
        self.names = keys
        self.radices = localRadices
    }

    public func parameterVector(at combinationIndex: UInt64) throws -> ParameterVector {
        guard combinationIndex < combinationCount else {
            throw FXBacktestError.invalidSweep("Combination index \(combinationIndex) is outside 0..<\(combinationCount).")
        }
        var quotient = combinationIndex
        var values = ContiguousArray<Double>()
        values.reserveCapacity(dimensions.count)
        for index in dimensions.indices {
            let radix = radices[index]
            let offset = quotient % radix
            quotient /= radix
            values.append(dimensions[index].value(at: offset))
        }
        return ParameterVector(combinationIndex: combinationIndex, names: names, values: values)
    }

    public static func singlePass(definitions: [ParameterDefinition]) throws -> ParameterSweep {
        try ParameterSweep(dimensions: definitions.map {
            try ParameterSweepDimension(
                definition: $0,
                input: $0.defaultValue,
                minimum: $0.defaultValue,
                step: max($0.defaultStep, 1),
                maximum: $0.defaultValue
            )
        })
    }
}
