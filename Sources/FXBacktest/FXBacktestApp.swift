import SwiftUI

@main
struct FXBacktestApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1180, minHeight: 760)
                .task {
                    model.startTerminalCommandShellIfNeeded()
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Run Optimization") {
                    model.runOptimization()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.isRunning)

                Button("Cancel Run") {
                    model.cancelRun()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!model.isRunning)
            }
        }
    }
}
