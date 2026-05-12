# FXBacktest

FXBacktest is a Swift macOS backtesting shell for running converted MQL5 Expert Advisors as Swift plugins against verified M1 OHLC data produced by FXExport.

The current implementation provides:

- Plugin API v1 for single-file Swift EA plugins.
- CPU optimization that splits work by complete backtest pass, not by sharing one pass across threads.
- Optional Metal execution for plugins that embed a matching Metal compute kernel.
- FXExport history loading through the verified canonical M1 OHLC API.
- A live SwiftUI passes table with profit, drawdown, trades, win rate, profit factor, and parameter values.

## Architecture

`FXBacktestCore` owns the stable API:

- `OhlcDataSeries`: immutable, columnar UTC/open/high/low/close arrays.
- `ParameterDefinition`, `ParameterSweepDimension`, `ParameterSweep`: lazy parameter-matrix enumeration.
- `FXBacktestPluginV1`: the plugin contract for converted EAs.
- `CPUBacktestExecutor`: chunked whole-pass parallel optimizer.
- `MetalBacktestExecutor`: plugin-provided Metal kernel runner.
- `FXExportHistoryLoader`: ClickHouse/FXExport data bridge.

`FXBacktestPlugins` stores EA plugins. Converted MQL5 EAs should be added here as single Swift files and registered in `FXBacktestPluginRegistry`.

`FXBacktest` is the SwiftUI app.

## Plugin API v1

A plugin implements `FXBacktestPluginV1`:

```swift
public protocol FXBacktestPluginV1: Sendable {
    var descriptor: FXBacktestPluginDescriptor { get }
    var parameterDefinitions: [ParameterDefinition] { get }
    var metalKernel: MetalKernelV1? { get }

    func runPass(
        market: OhlcDataSeries,
        parameters: ParameterVector,
        context: BacktestContext
    ) throws -> BacktestPassResult
}
```

Rules for converted EA plugins:

- Keep all mutable EA state local to `runPass`.
- Do not share mutable globals across passes.
- Read market arrays only; FXBacktest treats OHLC data as immutable.
- Return aggregate pass metrics only. Single-pass reports are intentionally out of scope for now.
- If GPU execution is required, embed a `MetalKernelV1` source string with the documented buffer layout used by `MetalBacktestExecutor`.

This maps MQL5 EA lifecycle into a deterministic pass: initialize local state, loop over M1 bars, apply signal/trade logic, finalize metrics.

### Metal Kernel ABI v1

Metal plugins embed an MSL source string and entry point. FXBacktest binds buffers as:

| Index | Type | Meaning |
| --- | --- | --- |
| 0 | `const device long *` | UTC epoch seconds |
| 1 | `const device long *` | Open prices, scaled integers |
| 2 | `const device long *` | High prices, scaled integers |
| 3 | `const device long *` | Low prices, scaled integers |
| 4 | `const device long *` | Close prices, scaled integers |
| 5 | `constant uint &` | Bar count |
| 6 | `const device FXBTMetalJob *` | Jobs, one per parameter combination |
| 7 | `const device float *` | Flattened parameter values |
| 8 | `device FXBTMetalResult *` | Output rows, one per job |
| 9 | `constant FXBTMetalRunConfig &` | Initial deposit, contract-lot value, price scale, digits |

The kernel must assign exactly one independent pass to each `thread_position_in_grid` and write only `results[id]`. Do not write shared global state from a plugin kernel.

## Performance Model

FXBacktest follows the same safety constraint as MT5-style optimization: a whole backtest pass owns its state. CPU workers receive ranges of complete parameter combinations, and each pass loops over the full market series independently. This avoids cross-thread state sharing and data corruption.

Metal mode is only used when a plugin supplies a GPU kernel. Swift plugin code itself cannot execute on the GPU. The Metal path compiles the plugin kernel once per run, uploads immutable OHLC buffers, dispatches one GPU thread per parameter combination, and writes one result row per job.

## FXExport Data

FXBacktest expects FXExport to own ingestion, repair, UTC mapping, and verification. The app requests verified canonical M1 data from ClickHouse through FXExport's Swift API. Data loading fails closed if FXExport reports missing verified coverage, bad hashes, mixed digits, duplicate timestamps, or invalid OHLC rows.

Default ClickHouse settings in the UI:

- URL: `http://127.0.0.1:8123`
- Database: `fxexport`
- Symbol: `EURUSD`

Use the Demo button when ClickHouse/FXExport is not running.

## Build And Test

```bash
swift test
swift build -c release
swift run FXBacktest
```

Release builds are the relevant performance baseline because SwiftPM enables whole-module optimization in release mode.
