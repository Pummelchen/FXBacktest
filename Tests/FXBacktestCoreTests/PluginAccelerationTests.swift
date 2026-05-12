import FXBacktestCore
import FXBacktestPlugins
import XCTest

final class PluginAccelerationTests: XCTestCase {
    func testMovingAverageCrossDeclaresValidAccelerationDescriptor() throws {
        let plugin = MovingAverageCrossPlugin()
        let descriptor = plugin.accelerationDescriptor

        XCTAssertTrue(descriptor.supportedBackends.contains(.metal))
        XCTAssertEqual(descriptor.metalEntryPoint, "moving_average_cross_v1")
        XCTAssertEqual(descriptor.ir?.version, "fxbacktest.plugin-ir.v1")
        XCTAssertNoThrow(try PluginAccelerationPipeline().validate(descriptor))
    }
}
