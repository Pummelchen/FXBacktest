import AppKit
import Foundation

struct TerminalCommandSession: Sendable {
    let model: AppModel
    let ignoredLaunchArguments: [String]

    func run() async {
        guard isatty(STDIN_FILENO) == 1 else {
            await TerminalLog.warn("No interactive terminal stdin is attached; FXBacktest will keep running without the command shell.")
            return
        }

        await TerminalLog.info("FXBacktest interactive command shell started")
        await TerminalLog.info("Type `help` for commands. Paste commands at the `>` prompt; FXBacktest accepts no launch-time options.")
        if !ignoredLaunchArguments.isEmpty {
            await TerminalLog.warn("Startup input ignored; no settings were changed: \(ignoredLaunchArguments.joined(separator: " "))")
        }

        while !Task.isCancelled {
            await TerminalLog.prompt()
            guard let line = readLine(strippingNewline: true) else {
                await TerminalLog.warn("Terminal stdin closed; FXBacktest app continues without the command shell.")
                return
            }
            let shouldContinue = await model.executeTerminalCommand(line)
            if !shouldContinue {
                await MainActor.run {
                    NSApplication.shared.terminate(nil)
                }
                return
            }
        }
    }
}

actor TerminalLog {
    static let shared = TerminalLog()

    static func info(_ message: String) async {
        await shared.printLine("[INFO]  \(message)")
    }

    static func ok(_ message: String) async {
        await shared.printLine("[OK]    \(message)")
    }

    static func warn(_ message: String) async {
        await shared.printLine("[WARN]  \(message)")
    }

    static func error(_ message: String) async {
        await shared.printLine("[ERROR] \(message)")
    }

    static func block(_ message: String) async {
        await shared.printLine(message)
    }

    static func prompt() async {
        await shared.write("> ")
    }

    private func printLine(_ message: String) {
        print(message)
    }

    private func write(_ message: String) {
        FileHandle.standardOutput.write(Data(message.utf8))
    }
}

enum TerminalCommandError: Error, CustomStringConvertible {
    case unterminatedQuote
    case danglingEscape
    case missingValue(String)
    case invalidValue(String)
    case unknownOption(String)
    case unknownCommand(String)

    var description: String {
        switch self {
        case .unterminatedQuote:
            return "Unterminated quote in command."
        case .danglingEscape:
            return "Dangling escape at end of command."
        case .missingValue(let name):
            return "Missing value for \(name)."
        case .invalidValue(let reason):
            return "Invalid value: \(reason)."
        case .unknownOption(let name):
            return "Unknown option \(name)."
        case .unknownCommand(let name):
            return "Unknown command \(name). Type `help`."
        }
    }
}

struct TerminalCommandTokenizer {
    func tokenize(_ line: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for character in line {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }
            current.append(character)
        }

        if escaping {
            throw TerminalCommandError.danglingEscape
        }
        if quote != nil {
            throw TerminalCommandError.unterminatedQuote
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}

struct ParsedTerminalOptions {
    var options: [String: String] = [:]
    var positionals: [String] = []

    init(tokens: ArraySlice<String>) throws {
        var index = tokens.startIndex
        while index < tokens.endIndex {
            let token = tokens[index]
            if token.hasPrefix("--") {
                let option = String(token.dropFirst(2))
                if let equalIndex = option.firstIndex(of: "="), equalIndex > option.startIndex {
                    let key = String(option[..<equalIndex]).lowercased()
                    let value = String(option[option.index(after: equalIndex)...])
                    guard !key.isEmpty, !value.isEmpty else {
                        throw TerminalCommandError.missingValue(token)
                    }
                    options[key] = value
                    index = tokens.index(after: index)
                    continue
                }

                let key = option.lowercased()
                guard !key.isEmpty else {
                    throw TerminalCommandError.unknownOption(token)
                }
                let valueIndex = tokens.index(after: index)
                guard valueIndex < tokens.endIndex else {
                    throw TerminalCommandError.missingValue(token)
                }
                let value = tokens[valueIndex]
                guard !value.hasPrefix("--") else {
                    throw TerminalCommandError.missingValue(token)
                }
                options[key] = value
                index = tokens.index(after: valueIndex)
                continue
            }
            if let equalIndex = token.firstIndex(of: "="), equalIndex > token.startIndex {
                let key = String(token[..<equalIndex]).lowercased()
                let value = String(token[token.index(after: equalIndex)...])
                options[key] = value
            } else {
                positionals.append(token)
            }
            index = tokens.index(after: index)
        }
    }
}
