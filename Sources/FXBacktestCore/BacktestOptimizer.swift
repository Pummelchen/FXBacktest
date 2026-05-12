import Foundation

public struct BacktestOptimizer: Sendable {
    public init() {}

    public func run(
        plugin: AnyFXBacktestPlugin,
        market: OhlcDataSeries,
        sweep: ParameterSweep,
        settings: BacktestRunSettings
    ) -> AsyncThrowingStream<BacktestOptimizationEvent, Error> {
        run(plugin: plugin, marketUniverse: market.universe, sweep: sweep, settings: settings)
    }

    public func run(
        plugin: AnyFXBacktestPlugin,
        marketUniverse: OhlcMarketUniverse,
        sweep: ParameterSweep,
        settings: BacktestRunSettings
    ) -> AsyncThrowingStream<BacktestOptimizationEvent, Error> {
        switch settings.target {
        case .cpu:
            CPUBacktestExecutor().run(plugin: plugin, marketUniverse: marketUniverse, sweep: sweep, settings: settings)
        case .metal:
            MetalBacktestExecutor().run(plugin: plugin, market: marketUniverse.primary, sweep: sweep, settings: settings)
        case .both:
            HybridBacktestExecutor().run(plugin: plugin, marketUniverse: marketUniverse, sweep: sweep, settings: settings)
        }
    }
}
