# FXBacktest

FXBacktest is a native Swift macOS backtesting application for running converted MQL5 Expert Advisors as high-performance Swift plugins. It is designed to work with [FXExport](https://github.com/Pummelchen/FXExport) as the historical Forex data provider: FXExport ingests and verifies M1 OHLC data from MetaTrader 5, and FXBacktest consumes that verified data for optimization runs.

The goal is similar to the MT5 Strategy Tester optimization view: define a matrix of input/min/step/max parameters, run many complete backtest passes on CPU or Metal, and watch the live table of pass results.

## Current Capabilities

- Native SwiftPM macOS app with SwiftUI interface.
- Plugin API v1 for converted MQL5 EAs stored as optimized single-file Swift plugins.
- Broker/execution model v2 with per-symbol digits, lot constraints, spread, slippage, commission, swap, margin, position lifecycle, and trade ledger types.
- Multi-symbol market universe support for plugins that need more than one loaded Forex pair.
- CPU optimizer that splits work by complete backtest pass across workers.
- Optional GPU execution through Metal for plugins that provide a matching compute kernel.
- Hybrid CPU+GPU execution that shares the pass matrix across CPU workers and Metal for maximum throughput.
- Plugin acceleration descriptor/IR scaffold for future generated Swift SIMD and Metal kernels.
- Read-only FXExport data loading through the dedicated FXBacktest API v1.
- Pre-run MT5 execution snapshot through FXExport API v1 for bid/ask, spread, swap, margin, lot limits, and account leverage.
- ClickHouse-backed FXBacktest result-store API for optimization results only, including explicit purge commands.
- Live pass table with profit, drawdown, trades, win rate, profit factor, and parameters.
- Resident terminal command shell with `>` prompt for loading data, changing settings, starting runs, stopping active work, and checking status without relaunching.
- Demo data mode for UI and engine testing when the FXExport API is not running.

## Repository Layout

```text
Package.swift
Sources/
  FXBacktest/                 SwiftUI macOS app
  FXBacktestCore/             engine, data model, FXExport loader, plugin API
  FXBacktestPlugins/          converted EA plugins
    FXStupid/                 first converted EA plugin and config
Tests/
  FXBacktestCoreTests/        engine, sweep, and Metal smoke tests
```

Important files:

- `Sources/FXBacktestCore/PluginAPI.swift`: Plugin API v1.
- `Sources/FXBacktestCore/CPUBacktestExecutor.swift`: whole-pass CPU optimization.
- `Sources/FXBacktestCore/MetalBacktestExecutor.swift`: plugin-provided Metal kernel runner.
- `Sources/FXBacktestCore/HybridBacktestExecutor.swift`: shared CPU+Metal pass scheduling.
- `Sources/FXBacktestCore/ExecutionModel.swift`: broker/execution v2 model and deterministic broker simulator.
- `Sources/FXBacktestCore/OhlcMarketUniverse.swift`: aligned multi-symbol OHLC universe.
- `Sources/FXBacktestCore/FXExportHistoryLoader.swift`: FXExport FXBacktest API v1 client bridge.
- `Sources/FXBacktestCore/FXExportExecutionLoader.swift`: pre-run MT5 execution metadata loader.
- `Sources/FXBacktestCore/BacktestResultStore.swift`: ClickHouse result-store API and purge support.
- `Sources/FXBacktestCore/PluginAcceleration.swift`: plugin acceleration descriptor and IR v1.
- `Sources/FXBacktestPlugins/MovingAverageCrossPlugin.swift`: reference EA plugin.
- `Sources/FXBacktestPlugins/FXStupid/FXStupid.swift`: converted `FX_Stupid_Original_Min.mq5` plugin.
- `Sources/FXBacktestPlugins/FXStupid/FXStupid.config.json`: FXStupid input/config defaults.

## Requirements

- macOS 13 or newer.
- Apple Silicon Mac recommended, especially M2/M3 for the intended performance target.
- Swift 6 toolchain.
- FXExport repo checked out next to this repo:

```text
FX/
  FXBacktest/
  FXExport/
    MT5Research/
```

The Swift package dependency is local:

```swift
.package(path: "../FXExport/MT5Research")
```

## Quickstart

### 1. Clone FXBacktest

```bash
git clone https://github.com/Pummelchen/FXBacktest.git
cd FXBacktest
```

Make sure FXExport exists next to it:

```bash
cd ..
git clone https://github.com/Pummelchen/FXExport.git
cd FXBacktest
```

### 2. Build And Test

```bash
swift test
swift build -c release
```

Release builds are the relevant performance baseline because SwiftPM uses whole-module optimization in release mode.

### 3. Run The App

```bash
swift run FXBacktest
```

Do not pass launch-time parameters. FXBacktest starts the SwiftUI backtester and a resident terminal prompt:

```text
> 
```

Paste commands into that prompt while the app keeps running. Status messages continue to print to the terminal, and the SwiftUI live table updates at the same time.

FXBacktest has no supported executable flags. Extra text after `swift run FXBacktest` is ignored and cannot change app settings, data selection, plugin selection, run settings, or parameter ranges. All operator input belongs in commands typed after the resident `>` prompt.

The first screen is the working backtester, not a setup wizard. It includes:

- EA plugin picker.
- Data controls.
- CPU, GPU (Metal), and Both engine selector.
- Parameter matrix editor.
- Run/Stop buttons.
- Live MT5-style optimization table.

### 4. Run A Demo Backtest

Use this when the FXExport API is not running.

1. Launch FXBacktest.
2. Select `Moving Average Cross`.
3. Click `Demo`.
4. Keep `CPU` selected.
5. Adjust parameter ranges if needed.
6. Click `Run`.

The same flow from the terminal prompt is:

```text
> load-demo
> run cpu
```

The pass table updates live and sorts the best results by net profit.

### 5. Run A Backtest With FXExport Data

FXExport is responsible for historical data ingestion, broker UTC mapping, verification, repair, and internal storage. FXBacktest only reads verified data through FXExport's dedicated FXBacktest API v1. FXBacktest must not connect to ClickHouse directly.

In FXExport, prepare the data first:

```bash
cd ../FXExport/MT5Research
swift build -c release
.build/release/FXExport
```

At the FXExport `>` prompt, run:

```text
> startcheck --config-dir Config --migrations-dir Migrations
> backfill --config-dir Config --symbols all
> verify --config-dir Config --random-ranges 20
> fxbacktest-api --config-dir Config --api-host 127.0.0.1 --api-port 5066
```

Leave FXExport running while FXBacktest loads data and while a run starts. FXBacktest loads historical M1 OHLC first, then immediately before each backtest run it asks FXExport for current MT5 execution terms for every loaded symbol.

Then in FXBacktest:

1. Set FXExport API URL, usually `http://127.0.0.1:5066`.
2. Set broker source id, for example `icmarkets-sc-mt5-4`.
3. Set logical symbol, for example `EURUSD`.
4. Set expected MT5 symbol and digits.
5. Set UTC start/end epoch seconds, minute-aligned.
6. Click `Load FXExport`.
7. Select CPU, GPU (Metal), or Both.
8. Edit the parameter matrix.
9. Click `Run`.

Before the first optimization pass starts, FXBacktest calls FXExport API v1 `POST /v1/execution/spec` for all symbols in the loaded market universe. FXExport reads the live MT5 terminal through the FXExport EA bridge and returns a deterministic hedging-account execution snapshot: bid, ask, spread, floating-spread flag, contract size, min/step/max lots, swap long/short, swap mode, margin estimates, tick values, trade mode, account currency, and leverage. If the live execution snapshot is unavailable, the run fails closed instead of falling back silently. Demo data is the only exception and uses explicit deterministic demo execution terms.

The same flow from the FXBacktest terminal prompt is:

```text
> load-fxexport --api-url http://127.0.0.1:5066 --broker icmarkets-sc-mt5-4 --symbol EURUSD --mt5-symbol EURUSD --digits 5 --from 1704067200 --to 1707177600 --max-rows 5000000
> set-param fast_period --input 12 --min 6 --step 2 --max 40
> set-param slow_period --input 48 --min 24 --step 4 --max 120
> run both --workers 8 --chunk 128
```

For multi-symbol EAs such as FXStupid, load an aligned market universe in one command. FXBacktest requests each symbol from FXExport API v1 and rejects the universe if timestamps do not line up exactly:

```text
> load-fxexport --api-url http://127.0.0.1:5066 --broker icmarkets-sc-mt5-4 --symbols EURUSD,USDJPY,EURGBP --from 1704067200 --to 1707177600 --max-rows 5000000
> plugin FXStupid
> run cpu --workers 8 --chunk 128
```

Single-symbol `--symbol`, `--mt5-symbol`, and `--digits` validation remains available for strict one-pair loads. For multi-symbol loads, FXBacktest stores the MT5 symbol and digits returned by FXExport for each symbol and uses those exact values in the pre-run execution snapshot request.

If FXExport reports missing verified coverage, bad hashes, mixed digits, duplicate timestamps, invalid OHLC rows, or unsafe ingestion state, FXBacktest fails closed instead of running against questionable data.

## Terminal Command Shell

FXBacktest is intended to stay open. If no backtest is active, it waits at the `>` prompt for the next command. State-changing commands gracefully stop active data loads or optimization runs before changing the app state.

The `--api-url`, `--workers`, `--input`, and similar `--...` tokens below are command options typed inside the running app. They are not launch-time parameters.

Useful commands:

```text
status
config
plugins
plugin <plugin-id-or-display-name>
params
set <field> <value>
set --api-url http://127.0.0.1:5066 --target both --workers 8
set --clickhouse-url http://127.0.0.1:8123 --clickhouse-db fxbacktest --persist-results true
set-param <key> --input 12 --min 6 --step 2 --max 40
load-demo
load-fxexport [--api-url URL] [--broker ID] [--symbol EURUSD] [--symbols EURUSD,USDJPY] [--mt5-symbol EURUSD] [--digits 5] [--from UTC] [--to UTC] [--max-rows N]
run [cpu|gpu|metal|both] [--workers N] [--chunk N] [--initial-deposit N] [--contract-size N] [--lot N]
save-results [--run-id ID] [--note TEXT]
clean-backtest-data --older-than-days 30
clean-backtest-data --all true
stop
reset-params
help
exit
```

`set --persist-results true` streams future optimization rows into ClickHouse through `BacktestResultStore`. `save-results` persists the currently retained in-memory result rows. `clean-backtest-data` is the purge command for old or unwanted optimization result data.

## FXExport Data Contract

FXBacktest consumes FXExport only through the dedicated FXBacktest API v1:

- API version: `fxexport.fxbacktest.history.v1`
- Status endpoint: `GET /v1/status`
- M1 history endpoint: `POST /v1/history/m1`
- Execution snapshot endpoint: `POST /v1/execution/spec`

FXBacktest imports the small `FXExportFXBacktestAPI` SwiftPM product for v1 DTOs and the HTTP client. That module does not expose ClickHouse, FXExport internals, or the old direct history provider.

The data path is:

```text
MT5 + FXExport EA
  -> FXExport Swift ingestion
  -> FXExport internal canonical M1 OHLC storage
  -> FXExport FXBacktest API v1
  -> FXBacktest OhlcDataSeries
  -> CPU or Metal optimization
```

FXBacktest expects:

- M1 closed bars only.
- UTC timestamps, not MT5 server timestamps.
- Scaled integer OHLC prices.
- Strictly increasing timestamps.
- Complete verified coverage for the requested UTC range.
- Matching broker source, logical symbol, MT5 symbol, and digits.

Before every non-demo run, FXBacktest also expects FXExport to provide current MT5 execution metadata through the same API v1 boundary:

```text
MT5 terminal + FXExport EA
  -> FXExport FXBacktest API v1 /v1/execution/spec
  -> FXBacktest FXExportExecutionLoader
  -> BacktestRunSettings.executionProfile
```

That execution snapshot is requested for each symbol in the loaded run and is bound to the broker source, MT5 symbol, and digits from the already loaded FXExport history metadata. FXBacktest does not use stale UI fields or direct database reads to infer execution terms.

Direct ClickHouse access is forbidden for historical Forex OHLC data. The only ClickHouse exception in FXBacktest is the local optimization result-store API, which writes and purges FXBacktest result tables:

- `fxbacktest_runs`
- `fxbacktest_pass_results`

That result-store API is separate from FXExport history storage and must not be used as a shortcut to read broker OHLC data.

## Execution Model v2

`BacktestBrokerV2` is the new deterministic broker/execution surface for converted plugins that need more realistic MT5-style execution. It models:

- Per-symbol digits and scaled integer prices.
- Bid/ask execution from close price plus spread.
- Slippage points.
- Commission per lot per side.
- Swap placeholders for long/short positions.
- Lot min/step/max normalization.
- Hedging or netting accounting mode.
- Margin fields.
- Position lifecycle and closed-trade ledger.

For FXExport-backed runs, the v2 execution profile is pulled from MT5 immediately before the run starts. The account model is always `hedging`. MT5 does not expose a reliable static symbol commission or tester slippage model through `SymbolInfo*`, so the API carries explicit source fields: commission currently defaults to `0` with source `not_exposed_by_mt5_symbol_info`, and slippage defaults to deterministic zero with source `deterministic_zero_default`. Those source fields are part of the model so broker-specific commission or slippage can later be added without hiding assumptions.

The older `BacktestBroker` remains available for simple plugins. New or upgraded plugins should use the v2 execution types when fidelity matters.

## Multi-Symbol Backtests

`OhlcMarketUniverse` holds multiple `OhlcDataSeries` instances keyed by logical symbol. FXBacktest validates that all series have identical timestamps before a multi-symbol run starts. This keeps each pass deterministic and avoids plugins silently reading mismatched bars.

Plugins can implement:

```swift
func runPass(
    marketUniverse: OhlcMarketUniverse,
    parameters: ParameterVector,
    context: BacktestContext
) throws -> BacktestPassResult
```

Existing single-symbol plugins still compile because the default implementation runs against the universe primary series.

## Result Store And Purge

Optimization results can be persisted to ClickHouse through FXBacktest's result-store API:

```text
> set --clickhouse-url http://127.0.0.1:8123 --clickhouse-db fxbacktest --persist-results true
> run cpu
```

For a manual snapshot of retained rows:

```text
> save-results --note current-best-window
```

To clean old result data:

```text
> clean-backtest-data --older-than-days 30
```

To remove all stored optimization result data:

```text
> clean-backtest-data --all true
```

## Plugin API v1

Converted EAs implement `FXBacktestPluginV1`:

```swift
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
```

Plugin rules:

- Keep all mutable EA state local to `runPass`.
- Do not share mutable globals across passes.
- Treat OHLC arrays as read-only.
- Return aggregate metrics for each pass.
- Store each converted EA plugin in its own subfolder under `Sources/FXBacktestPlugins/`, for example `Sources/FXBacktestPlugins/FXStupid/`.
- Register plugins in `FXBacktestPluginRegistry`.

Single-pass reports are intentionally not implemented yet. The current product focus is maximum optimizer throughput and a live pass table.

The live optimization table follows the MT5 tester shape: fixed metric columns first (`Pass`, `Result`, `Profit`, `Total trades`, `Drawdown %`, `Recovery factor`, `Sharpe ratio`), followed by one column per tested plugin input parameter.

### FXStupid

`FXStupid` is the first converted MQL5 EA plugin. Its Swift file keeps the original EA flow close to the source:

```text
OnInit -> OnTick -> EAStop -> TPCheck -> SLCheck -> AdjustLotSizes -> RefreshTraded -> OrderScan
```

The original MQL5 `input` values are stored in `FXStupid.config.json` beside the plugin file and become FXBacktest parameter definitions. The plugin is CPU-only for now because preserving the EA control flow is more important than immediately rewriting it as a Metal kernel.

FXStupid now uses `OhlcMarketUniverse`, so loaded symbols from `FXPairs` can participate in the original scan loop. Symbols not loaded from FXExport behave like unavailable MT5 symbols and are skipped.

## Plugin Acceleration API

`PluginAccelerationDescriptor` and `PluginAccelerationIR` define the v1 scaffold for converting suitable plugins into generated Swift SIMD or Metal kernels while keeping the hand-converted Swift plugin as the fidelity reference. The reference Moving Average Cross plugin declares a Metal entry point and IR operation. FXStupid deliberately stays scalar CPU until its EA flow is validated against MT5 results.

## CPU, GPU, And Hybrid Execution Model

CPU optimization splits the parameter matrix into chunks. Each worker receives complete passes and each pass owns its strategy state. FXBacktest does not split one pass across multiple threads because that risks state corruption in converted EA logic.

GPU optimization is available through Metal only for plugins that provide `MetalKernelV1`. Swift plugin code does not automatically run on the GPU. A Metal plugin kernel receives immutable OHLC buffers, a flattened parameter buffer, job records, and a result buffer. Each GPU thread owns one complete parameter combination and writes one result row.

`Both` is the hybrid mode. It requires a Metal-capable plugin and runs CPU workers plus a Metal command-buffer loop at the same time. A shared allocator hands out disjoint pass ranges, so each parameter combination is executed exactly once by either CPU or GPU. Result rows still record the engine that produced the pass as `cpu` or `metal`; the stored run target is `both`.

## Metal Kernel ABI v1

FXBacktest binds Metal buffers as:

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

The kernel must assign exactly one independent pass to each `thread_position_in_grid` and write only `results[id]`.

## Testing

```bash
swift test
swift test -c release
swift build -c release
```

The test suite includes:

- Lazy parameter-matrix indexing.
- CPU whole-pass chunk execution.
- Metal kernel compile and dispatch smoke test when Metal is available.
- Hybrid CPU+Metal scheduling without duplicate pass indexes.
- Broker/execution v2 spread, commission, and ledger behavior.
- Multi-symbol universe alignment validation.
- FXStupid multi-symbol universe behavior.
- ClickHouse result-store SQL/purge API behavior with a mock executor.
- Plugin acceleration descriptor validation.

## GitHub Wiki

Project documentation is also published in the GitHub Wiki:

- Home
- Quickstart Guide
- FXExport Data Provider
- Architecture
- Plugin API v1
- CPU and Metal Optimization
- Troubleshooting
- Developer Workflow

## Status

FXBacktest is in the first functional engine/app stage. It can load demo data, load single-symbol or aligned multi-symbol verified FXExport data, pull current MT5 execution snapshots through FXExport before each non-demo run, run CPU, Metal, or hybrid CPU+Metal optimizations for plugins that provide a kernel, and persist optimization results to ClickHouse through its own result-store API. Future work should add more converted EA plugins, fuller generated-kernel acceleration, broker-specific commission/slippage enrichment, and optional single-pass reporting.
