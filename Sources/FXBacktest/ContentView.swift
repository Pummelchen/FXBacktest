import FXBacktestCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { model.selectedPluginID },
                set: { if let id = $0 { model.selectPlugin(id) } }
            )) {
                Section("EA Plugins") {
                    ForEach(model.plugins) { plugin in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(plugin.descriptor.displayName)
                                .lineLimit(1)
                            Text(plugin.descriptor.version)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(plugin.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("FXBacktest")
        } detail: {
            VStack(spacing: 0) {
                toolbar
                Divider()
                HSplitView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            dataPanel
                            runPanel
                            parameterPanel
                        }
                        .padding()
                        .frame(minWidth: 380, idealWidth: 430, maxWidth: 520, alignment: .topLeading)
                    }
                    resultPanel
                        .frame(minWidth: 680)
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedPlugin.descriptor.displayName)
                    .font(.headline)
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.progress.totalPasses > 0 {
                ProgressView(value: model.progress.fraction)
                    .frame(width: 220)
            }
            Button {
                model.runOptimization()
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .disabled(model.isRunning)

            Button {
                model.cancelRun()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!model.isRunning)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var dataPanel: some View {
        GroupBox("Data") {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("ClickHouse")
                        TextField("URL", text: $model.connectionURLText)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Database")
                        TextField("Database", text: $model.database)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Broker")
                        TextField("Broker source", text: $model.brokerSourceId)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Symbol")
                        HStack {
                            TextField("Logical", text: $model.logicalSymbol)
                                .textFieldStyle(.roundedBorder)
                            TextField("MT5", text: $model.expectedMT5Symbol)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    GridRow {
                        Text("UTC Start")
                        TextField("Start", value: $model.utcStartInclusive, format: .number)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("UTC End")
                        TextField("End", value: $model.utcEndExclusive, format: .number)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                HStack {
                    Button {
                        model.loadFXExportData()
                    } label: {
                        Label("Load FXExport", systemImage: "externaldrive.connected.to.line.below")
                    }
                    .disabled(model.isLoadingData || model.isRunning)

                    Button {
                        model.loadDemoData()
                    } label: {
                        Label("Demo", systemImage: "chart.line.uptrend.xyaxis")
                    }
                    .disabled(model.isRunning)
                }

                if let market = model.market {
                    Text("\(market.metadata.logicalSymbol) \(market.metadata.timeframe), \(market.count.formatted()) bars, digits \(market.metadata.digits)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var runPanel: some View {
        GroupBox("Run") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Engine", selection: $model.executionTarget) {
                    ForEach(BacktestExecutionTarget.allCases) { target in
                        Text(target.rawValue.uppercased()).tag(target)
                    }
                }
                .pickerStyle(.segmented)

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Workers")
                        Stepper(value: $model.maxWorkers, in: 1...max(1, ProcessInfo.processInfo.activeProcessorCount), step: 1) {
                            Text("\(model.maxWorkers)")
                        }
                    }
                    GridRow {
                        Text("Chunk")
                        TextField("Chunk", value: $model.chunkSize, format: .number)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Initial")
                        TextField("Deposit", value: $model.initialDeposit, format: .number)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Lot")
                        TextField("Lot", value: $model.lotSize, format: .number)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                HStack {
                    Text("Combinations")
                    Spacer()
                    Text(model.combinationCountText)
                        .monospacedDigit()
                }
                HStack {
                    Text("Completed")
                    Spacer()
                    Text("\(model.progress.completedPasses.formatted()) / \(model.progress.totalPasses.formatted())")
                        .monospacedDigit()
                }
                HStack {
                    Text("Pass/s")
                    Spacer()
                    Text(model.progress.passesPerSecond.formatted(.number.precision(.fractionLength(0))))
                        .monospacedDigit()
                }
            }
        }
    }

    private var parameterPanel: some View {
        GroupBox("Parameters") {
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Input").font(.caption).foregroundStyle(.secondary)
                        Text("Min").font(.caption).foregroundStyle(.secondary)
                        Text("Step").font(.caption).foregroundStyle(.secondary)
                        Text("Max").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach($model.parameterRows) { $row in
                        GridRow {
                            VStack(alignment: .leading) {
                                Text(row.definition.displayName)
                                    .lineLimit(1)
                                Text(row.definition.key)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            TextField("Input", value: $row.input, format: .number)
                                .textFieldStyle(.roundedBorder)
                            TextField("Min", value: $row.minimum, format: .number)
                                .textFieldStyle(.roundedBorder)
                            TextField("Step", value: $row.step, format: .number)
                                .textFieldStyle(.roundedBorder)
                            TextField("Max", value: $row.maximum, format: .number)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
        }
    }

    private var resultPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Passes")
                    .font(.headline)
                Spacer()
                Text("showing best \(model.bestResults.count.formatted())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Table(model.bestResults) {
                TableColumn("Pass") { result in
                    Text("\(result.passIndex)")
                        .monospacedDigit()
                }
                .width(70)
                TableColumn("Profit") { result in
                    Text(result.netProfit.formatted(.number.precision(.fractionLength(2))))
                        .monospacedDigit()
                        .foregroundStyle(result.netProfit >= 0 ? .green : .red)
                }
                .width(100)
                TableColumn("Drawdown") { result in
                    Text(result.maxDrawdown.formatted(.number.precision(.fractionLength(2))))
                        .monospacedDigit()
                }
                .width(100)
                TableColumn("Trades") { result in
                    Text("\(result.totalTrades)")
                        .monospacedDigit()
                }
                .width(70)
                TableColumn("Win %") { result in
                    Text((result.winRate * 100).formatted(.number.precision(.fractionLength(1))))
                        .monospacedDigit()
                }
                .width(70)
                TableColumn("PF") { result in
                    Text(result.profitFactor.isFinite ? result.profitFactor.formatted(.number.precision(.fractionLength(2))) : "inf")
                        .monospacedDigit()
                }
                .width(70)
                TableColumn("Params") { result in
                    Text(result.parameters.map { "\($0.key)=\($0.value.formatted(.number.precision(.fractionLength(2))))" }.joined(separator: ", "))
                        .lineLimit(1)
                        .font(.caption)
                }
            }
        }
    }
}
