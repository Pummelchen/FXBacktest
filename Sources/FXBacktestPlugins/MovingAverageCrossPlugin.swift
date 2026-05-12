import FXBacktestCore
import Foundation

public struct MovingAverageCrossPlugin: FXBacktestPluginV1 {
    public let descriptor = FXBacktestPluginDescriptor(
        id: "com.fxbacktest.plugins.moving-average-cross.v1",
        displayName: "Moving Average Cross",
        version: "1.0.0",
        summary: "Reference EA plugin that opens long/short positions on fast/slow moving-average crossovers.",
        author: "FXBacktest",
        supportsMetal: true
    )

    public let parameterDefinitions: [ParameterDefinition]

    public init() {
        self.parameterDefinitions = [
            try! ParameterDefinition(
                key: "fast_period",
                displayName: "Fast MA",
                defaultValue: 8,
                defaultMinimum: 4,
                defaultStep: 2,
                defaultMaximum: 30,
                valueKind: .integer
            ),
            try! ParameterDefinition(
                key: "slow_period",
                displayName: "Slow MA",
                defaultValue: 24,
                defaultMinimum: 12,
                defaultStep: 4,
                defaultMaximum: 90,
                valueKind: .integer
            )
        ]
    }

    public var metalKernel: MetalKernelV1? {
        MetalKernelV1(source: Self.metalSource, entryPoint: "moving_average_cross_v1", maxPassesPerCommandBuffer: 8_192)
    }

    public var accelerationDescriptor: PluginAccelerationDescriptor {
        PluginAccelerationDescriptor(
            pluginIdentifier: descriptor.id,
            supportedBackends: [.swiftScalar, .swiftSIMD, .metal],
            metalEntryPoint: "moving_average_cross_v1",
            ir: PluginAccelerationIR(
                requiredColumns: [
                    PluginAccelerationInputColumn(field: "close")
                ],
                operations: [
                    PluginAccelerationIROperation(
                        opcode: "moving_average_cross",
                        inputs: ["close", "fast_period", "slow_period"],
                        outputs: ["position_signal", "trade_ledger", "pass_metrics"]
                    )
                ]
            )
        )
    }

    public func runPass(
        market: OhlcDataSeries,
        parameters: ParameterVector,
        context: BacktestContext
    ) throws -> BacktestPassResult {
        let fast = max(1, Int(parameters[0].rounded()))
        let slow = max(fast + 1, Int(parameters[1].rounded()))
        var broker = BacktestBroker(context: context)

        guard market.count > slow else {
            return result(parameters: parameters, context: context, broker: broker, barsProcessed: market.count, flags: 2)
        }

        var fastSum: Int64 = 0
        var slowSum: Int64 = 0
        var lastSignal = 0

        for index in 0..<market.count {
            let close = market.close[index]
            fastSum += close
            slowSum += close
            if index >= fast {
                fastSum -= market.close[index - fast]
            }
            if index >= slow {
                slowSum -= market.close[index - slow]
            }
            guard index >= slow - 1 else {
                continue
            }

            let fastMA = Double(fastSum) / Double(fast)
            let slowMA = Double(slowSum) / Double(slow)
            let signal = fastMA > slowMA ? 1 : (fastMA < slowMA ? -1 : lastSignal)
            if signal != lastSignal {
                if signal > 0 {
                    broker.openMarket(direction: .long, price: close)
                } else if signal < 0 {
                    broker.openMarket(direction: .short, price: close)
                }
                lastSignal = signal
            }
            broker.markToMarket(price: close)
        }

        if let finalClose = market.close.last {
            broker.finish(price: finalClose)
        }
        return result(parameters: parameters, context: context, broker: broker, barsProcessed: market.count, flags: 0)
    }

    private func result(
        parameters: ParameterVector,
        context: BacktestContext,
        broker: BacktestBroker,
        barsProcessed: Int,
        flags: UInt32
    ) -> BacktestPassResult {
        BacktestPassResult(
            passIndex: parameters.combinationIndex,
            pluginIdentifier: descriptor.id,
            engine: context.settings.target,
            parameters: parameters.snapshots,
            netProfit: broker.netProfit,
            grossProfit: broker.grossProfit,
            grossLoss: broker.grossLoss,
            maxDrawdown: broker.maxDrawdown,
            totalTrades: broker.totalTrades,
            winningTrades: broker.winningTrades,
            losingTrades: broker.losingTrades,
            winRate: broker.winRate,
            profitFactor: broker.profitFactor,
            barsProcessed: barsProcessed,
            flags: flags
        )
    }
}

public enum FXBacktestPluginRegistry {
    public static let availablePlugins: [AnyFXBacktestPlugin] = [
        AnyFXBacktestPlugin(MovingAverageCrossPlugin()),
        AnyFXBacktestPlugin(FXStupid())
    ]
}

private extension MovingAverageCrossPlugin {
    static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct FXBTMetalJob {
        ulong combinationIndex;
        uint parameterOffset;
        uint parameterCount;
    };

    struct FXBTMetalResult {
        ulong combinationIndex;
        float netProfit;
        float grossProfit;
        float grossLoss;
        float maxDrawdown;
        uint totalTrades;
        uint winningTrades;
        uint losingTrades;
        float winRate;
        float profitFactor;
        uint barsProcessed;
        uint flags;
    };

    struct FXBTMetalRunConfig {
        float initialDeposit;
        float contractLots;
        float priceScale;
        uint digits;
    };

    kernel void moving_average_cross_v1(
        const device long *utc [[buffer(0)]],
        const device long *open [[buffer(1)]],
        const device long *high [[buffer(2)]],
        const device long *low [[buffer(3)]],
        const device long *close [[buffer(4)]],
        constant uint &barCount [[buffer(5)]],
        const device FXBTMetalJob *jobs [[buffer(6)]],
        const device float *parameters [[buffer(7)]],
        device FXBTMetalResult *results [[buffer(8)]],
        constant FXBTMetalRunConfig &config [[buffer(9)]],
        uint id [[thread_position_in_grid]]
    ) {
        FXBTMetalJob job = jobs[id];
        uint offset = job.parameterOffset;
        int fast = max(1, int(parameters[offset] + 0.5));
        int slow = max(fast + 1, int(parameters[offset + 1] + 0.5));

        FXBTMetalResult result;
        result.combinationIndex = job.combinationIndex;
        result.netProfit = 0.0;
        result.grossProfit = 0.0;
        result.grossLoss = 0.0;
        result.maxDrawdown = 0.0;
        result.totalTrades = 0;
        result.winningTrades = 0;
        result.losingTrades = 0;
        result.winRate = 0.0;
        result.profitFactor = 0.0;
        result.barsProcessed = barCount;
        result.flags = 0;

        if (barCount <= uint(slow)) {
            result.flags = 2;
            results[id] = result;
            return;
        }

        float initialDeposit = config.initialDeposit;
        float contractLots = config.contractLots;
        float priceScale = config.priceScale;
        float balance = initialDeposit;
        float equity = initialDeposit;
        float peak = initialDeposit;
        float maxDrawdown = 0.0;
        float grossProfit = 0.0;
        float grossLoss = 0.0;
        int position = 0;
        long entry = 0;
        int wins = 0;
        int losses = 0;
        int trades = 0;
        long fastSum = 0;
        long slowSum = 0;
        int lastSignal = 0;

        for (uint index = 0; index < barCount; index++) {
            long price = close[index];
            fastSum += price;
            slowSum += price;
            if (index >= uint(fast)) {
                fastSum -= close[index - uint(fast)];
            }
            if (index >= uint(slow)) {
                slowSum -= close[index - uint(slow)];
            }
            if (index < uint(slow - 1)) {
                continue;
            }

            float fastMA = float(fastSum) / float(fast);
            float slowMA = float(slowSum) / float(slow);
            int signal = fastMA > slowMA ? 1 : (fastMA < slowMA ? -1 : lastSignal);
            if (signal != lastSignal) {
                if (position != 0) {
                    float pnl = float(position) * (float(price - entry) / priceScale) * contractLots;
                    balance += pnl;
                    grossProfit += max(0.0, pnl);
                    grossLoss += min(0.0, pnl);
                    trades += 1;
                    if (pnl >= 0.0) {
                        wins += 1;
                    } else {
                        losses += 1;
                    }
                }
                position = signal;
                entry = price;
                lastSignal = signal;
            }
            float floating = position == 0 ? 0.0 : float(position) * (float(price - entry) / priceScale) * contractLots;
            equity = balance + floating;
            peak = max(peak, equity);
            maxDrawdown = max(maxDrawdown, peak - equity);
        }

        if (position != 0) {
            long finalPrice = close[barCount - 1];
            float pnl = float(position) * (float(finalPrice - entry) / priceScale) * contractLots;
            balance += pnl;
            grossProfit += max(0.0, pnl);
            grossLoss += min(0.0, pnl);
            trades += 1;
            if (pnl >= 0.0) {
                wins += 1;
            } else {
                losses += 1;
            }
        }

        result.netProfit = balance - initialDeposit;
        result.grossProfit = grossProfit;
        result.grossLoss = grossLoss;
        result.maxDrawdown = maxDrawdown;
        result.totalTrades = uint(trades);
        result.winningTrades = uint(wins);
        result.losingTrades = uint(losses);
        result.winRate = trades == 0 ? 0.0 : float(wins) / float(trades);
        result.profitFactor = grossLoss == 0.0 ? (grossProfit > 0.0 ? 999999.0 : 0.0) : grossProfit / abs(grossLoss);
        results[id] = result;
    }
    """
}
