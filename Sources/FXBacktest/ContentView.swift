import AppKit
import FXBacktestCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedResultID: UInt64?

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
            .disabled(model.isRunning || model.isLoadingData)
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
                        Text("FXExport API")
                        TextField("URL", text: $model.apiURLText)
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
                        Text("Digits")
                        TextField("Expected digits", value: $model.expectedDigits, format: .number)
                            .textFieldStyle(.roundedBorder)
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
                    GridRow {
                        Text("Max Rows")
                        TextField("Maximum rows", value: $model.maximumRows, format: .number)
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
                    .disabled(model.isRunning || model.isLoadingData)
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
                        Text(target.displayName).tag(target)
                            .disabled(target.requiresMetalKernel && model.selectedPlugin.metalKernel == nil)
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
                        Text("Contract")
                        TextField("Contract", value: $model.contractSize, format: .number)
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
        .disabled(model.isRunning)
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
        .disabled(model.isRunning)
    }

    private var resultPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Optimization Results")
                    .font(.headline)
                Spacer()
                Text("\(model.bestResults.count.formatted()) passes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(model.bestResults.enumerated()), id: \.element.passIndex) { index, result in
                            optimizationResultRow(result, index: index)
                        }
                    } header: {
                        optimizationHeader
                    }
                }
                .frame(minWidth: optimizationTableWidth, alignment: .topLeading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
            }
        }
    }

    private var optimizationHeader: some View {
        HStack(spacing: 0) {
            metricHeader("Pass", width: 88, alignment: .leading)
            metricHeader("Result  ✓", width: 118)
            metricHeader("Profit", width: 110)
            metricHeader("Total trades", width: 118)
            metricHeader("Drawdown %", width: 118)
            metricHeader("Recovery factor", width: 132)
            metricHeader("Sharpe ratio", width: 132)
            ForEach(model.selectedPlugin.parameterDefinitions) { parameter in
                metricHeader(parameter.displayName, width: parameterColumnWidth)
            }
        }
        .frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
    }

    private func optimizationResultRow(_ result: BacktestPassResult, index: Int) -> some View {
        let isSelected = selectedResultID == result.passIndex

        return HStack(spacing: 0) {
            metricCell("\(result.passIndex)", width: 88, alignment: .leading, isSelected: isSelected)
            metricCell(formatDecimal(resultValue(result)), width: 118, isSelected: isSelected)
            metricCell(formatDecimal(result.netProfit), width: 110, isSelected: isSelected)
            metricCell("\(result.totalTrades)", width: 118, isSelected: isSelected)
            metricCell(formatDecimal(drawdownPercent(result)), width: 118, isSelected: isSelected)
            metricCell(formatDecimal(recoveryFactor(result)), width: 132, isSelected: isSelected)
            metricCell(formatDecimal(sharpeRatio(result)), width: 132, isSelected: isSelected)
            ForEach(model.selectedPlugin.parameterDefinitions) { parameter in
                metricCell(
                    parameterValue(result, definition: parameter),
                    width: parameterColumnWidth,
                    isSelected: isSelected
                )
            }
        }
        .frame(height: 20)
        .background(rowBackground(index: index, isSelected: isSelected))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedResultID = result.passIndex
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(height: 1)
        }
    }

    private var optimizationTableWidth: CGFloat {
        816 + (CGFloat(model.selectedPlugin.parameterDefinitions.count) * parameterColumnWidth)
    }

    private var parameterColumnWidth: CGFloat {
        132
    }

    private func metricHeader(_ title: String, width: CGFloat, alignment: Alignment = .trailing) -> some View {
        Text(title)
            .font(.system(size: 11))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.primary)
            .frame(width: width, alignment: alignment)
            .padding(.horizontal, 6)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            }
    }

    private func metricCell(_ value: String, width: CGFloat, alignment: Alignment = .trailing, isSelected: Bool) -> some View {
        Text(value)
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.primary)
            .frame(width: width, alignment: alignment)
            .padding(.horizontal, 6)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.7))
                    .frame(width: 1)
            }
    }

    private func rowBackground(index: Int, isSelected: Bool) -> Color {
        if isSelected {
            return Color(nsColor: .selectedContentBackgroundColor).opacity(0.28)
        }
        return index.isMultiple(of: 2)
            ? Color(nsColor: .textBackgroundColor)
            : Color(nsColor: .controlBackgroundColor).opacity(0.58)
    }

    private func resultValue(_ result: BacktestPassResult) -> Double {
        model.resultInitialDeposit + result.netProfit
    }

    private func drawdownPercent(_ result: BacktestPassResult) -> Double {
        guard model.resultInitialDeposit > 0 else { return 0 }
        return (result.maxDrawdown / model.resultInitialDeposit) * 100
    }

    private func recoveryFactor(_ result: BacktestPassResult) -> Double {
        guard result.maxDrawdown > 0 else { return 0 }
        return result.netProfit / result.maxDrawdown
    }

    private func sharpeRatio(_: BacktestPassResult) -> Double {
        0
    }

    private func parameterValue(_ result: BacktestPassResult, definition: ParameterDefinition) -> String {
        guard let value = result.parameters.first(where: { $0.key == definition.key })?.value else {
            return ""
        }
        switch definition.valueKind {
        case .integer:
            return value.formatted(.number.precision(.fractionLength(0)))
        case .boolean:
            return value == 0 ? "0" : "1"
        case .decimal:
            return value.formatted(.number.precision(.fractionLength(0...4)))
        }
    }

    private func formatDecimal(_ value: Double) -> String {
        guard value.isFinite else { return "inf" }
        return value.formatted(.number.precision(.fractionLength(2)))
    }
}
