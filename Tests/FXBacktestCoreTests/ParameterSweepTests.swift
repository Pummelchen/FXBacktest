import FXBacktestCore
import XCTest

final class ParameterSweepTests: XCTestCase {
    func testSweepCountsAndIndexesCombinationsWithoutMaterializingAll() throws {
        let fast = try ParameterDefinition(
            key: "fast",
            displayName: "Fast",
            defaultValue: 2,
            defaultMinimum: 2,
            defaultStep: 1,
            defaultMaximum: 4,
            valueKind: .integer
        )
        let slow = try ParameterDefinition(
            key: "slow",
            displayName: "Slow",
            defaultValue: 10,
            defaultMinimum: 10,
            defaultStep: 5,
            defaultMaximum: 20,
            valueKind: .integer
        )

        let sweep = try ParameterSweep(dimensions: [
            try ParameterSweepDimension(definition: fast, input: 2, minimum: 2, step: 1, maximum: 4),
            try ParameterSweepDimension(definition: slow, input: 10, minimum: 10, step: 5, maximum: 20)
        ])

        XCTAssertEqual(sweep.combinationCount, 9)
        XCTAssertEqual(try sweep.parameterVector(at: 0).values, [2, 10])
        XCTAssertEqual(try sweep.parameterVector(at: 1).values, [3, 10])
        XCTAssertEqual(try sweep.parameterVector(at: 3).values, [2, 15])
        XCTAssertEqual(try sweep.parameterVector(at: 8).values, [4, 20])
    }
}
