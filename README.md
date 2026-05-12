# FXBacktest

FXBacktest is a native Swift macOS backtesting application for running converted MQL5 Expert Advisors as high-performance Swift plugins. It is designed to work with [FXExport](https://github.com/Pummelchen/FXExport) as the historical Forex data provider: FXExport ingests and verifies M1 OHLC data from MetaTrader 5, and FXBacktest consumes that verified data for optimization runs.

The goal is similar to the MT5 Strategy Tester optimization view: define a matrix of input/min/step/max parameters, run many complete backtest passes on CPU or Metal, and watch the live table of pass results.

## Current Capabilities

- Native SwiftPM macOS app with SwiftUI interface.
- Plugin API v1 for converted MQL5 EAs stored as optimized single-file Swift plugins.
- CPU optimizer that splits work by complete backtest pass across workers.
- Optional Metal execution for plugins that provide a matching Metal compute kernel.
- Read-only FXExport data loading through the dedicated FXBacktest API v1.
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
- `Sources/FXBacktestCore/FXExportHistoryLoader.swift`: FXExport FXBacktest API v1 client bridge.
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
- CPU/Metal engine selector.
- Parameter matrix editor.
- Run/Stop buttons.
- Live pass-results table.

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

Leave FXExport running while FXBacktest loads data.

Then in FXBacktest:

1. Set FXExport API URL, usually `http://127.0.0.1:5066`.
2. Set broker source id, for example `icmarkets-sc-mt5-4`.
3. Set logical symbol, for example `EURUSD`.
4. Set expected MT5 symbol and digits.
5. Set UTC start/end epoch seconds, minute-aligned.
6. Click `Load FXExport`.
7. Select CPU or Metal.
8. Edit the parameter matrix.
9. Click `Run`.

The same flow from the FXBacktest terminal prompt is:

```text
> load-fxexport --api-url http://127.0.0.1:5066 --broker icmarkets-sc-mt5-4 --symbol EURUSD --mt5-symbol EURUSD --digits 5 --from 1704067200 --to 1707177600 --max-rows 5000000
> set-param fast_period --input 12 --min 6 --step 2 --max 40
> set-param slow_period --input 48 --min 24 --step 4 --max 120
> run cpu --workers 8 --chunk 128
```

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
set --api-url http://127.0.0.1:5066 --target cpu --workers 8
set-param <key> --input 12 --min 6 --step 2 --max 40
load-demo
load-fxexport [--api-url URL] [--broker ID] [--symbol EURUSD] [--mt5-symbol EURUSD] [--digits 5] [--from UTC] [--to UTC] [--max-rows N]
run [cpu|metal] [--workers N] [--chunk N] [--initial-deposit N] [--contract-size N] [--lot N]
stop
reset-params
help
exit
```

## FXExport Data Contract

FXBacktest consumes FXExport only through the dedicated FXBacktest API v1:

- API version: `fxexport.fxbacktest.history.v1`
- Status endpoint: `GET /v1/status`
- M1 history endpoint: `POST /v1/history/m1`

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

## Plugin API v1

Converted EAs implement `FXBacktestPluginV1`:

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

Plugin rules:

- Keep all mutable EA state local to `runPass`.
- Do not share mutable globals across passes.
- Treat OHLC arrays as read-only.
- Return aggregate metrics for each pass.
- Store each converted EA plugin in its own subfolder under `Sources/FXBacktestPlugins/`, for example `Sources/FXBacktestPlugins/FXStupid/`.
- Register plugins in `FXBacktestPluginRegistry`.

Single-pass reports are intentionally not implemented yet. The current product focus is maximum optimizer throughput and a live pass table.

### FXStupid

`FXStupid` is the first converted MQL5 EA plugin. Its Swift file keeps the original EA flow close to the source:

```text
OnInit -> OnTick -> EAStop -> TPCheck -> SLCheck -> AdjustLotSizes -> RefreshTraded -> OrderScan
```

The original MQL5 `input` values are stored in `FXStupid.config.json` beside the plugin file and become FXBacktest parameter definitions. The plugin is CPU-only for now because preserving the EA control flow is more important than immediately rewriting it as a Metal kernel.

Current limitation: FXBacktest currently supplies one loaded `OhlcDataSeries` to a plugin pass. FXStupid preserves the original multi-symbol scan loop, but symbols without loaded FXBacktest market data behave like unavailable MT5 symbols and are skipped.

## CPU And Metal Execution Model

CPU optimization splits the parameter matrix into chunks. Each worker receives complete passes and each pass owns its strategy state. FXBacktest does not split one pass across multiple threads because that risks state corruption in converted EA logic.

Metal optimization is available only for plugins that provide `MetalKernelV1`. Swift plugin code does not automatically run on the GPU. A Metal plugin kernel receives immutable OHLC buffers, a flattened parameter buffer, job records, and a result buffer. Each GPU thread owns one complete parameter combination and writes one result row.

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

FXBacktest is in the first functional engine/app stage. It can load demo data, load verified FXExport data, run CPU optimizations, and run Metal optimizations for plugins that provide a kernel. Future work should add more converted EA plugins, richer broker/execution modeling, durable optimization jobs, and optional single-pass reporting.
