import Foundation

public struct BacktestOptimizer: Sendable {
    public init() {}

    public func run(
        plugin: AnyFXBacktestPlugin,
        market: OhlcDataSeries,
        sweep: ParameterSweep,
        settings: BacktestRunSettings
    ) -> AsyncThrowingStream<BacktestOptimizationEvent, Error> {
        switch settings.target {
        case .cpu:
            CPUBacktestExecutor().run(plugin: plugin, market: market, sweep: sweep, settings: settings)
        case .metal:
            MetalBacktestExecutor().run(plugin: plugin, market: market, sweep: sweep, settings: settings)
        }
    }
}
