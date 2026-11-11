import Foundation

/// One `claude` command the installer runs, with arguments (never through a shell).
public struct PluginCommand: Equatable, Sendable {
    public var arguments: [String]

    public init(_ arguments: [String]) {
        self.arguments = arguments
    }

    /// The command as shown to the user, an argument with a space or a slash quoted.
    public var display: String {
        (["claude"] + arguments.map(Self.quoted)).joined(separator: " ")
    }

    private static func quoted(_ argument: String) -> String {
        let plain = argument.allSatisfy { $0.isLetter || $0.isNumber || "@._-".contains($0) }
        guard !plain || argument.isEmpty else { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// What one command of the installer printed.
public struct PluginCommandResult: Equatable, Sendable {
    public var command: PluginCommand
    public var output: String
    public var error: String

    public init(command: PluginCommand, output: String, error: String) {
        self.command = command
        self.output = output
        self.error = error
    }
}

public enum PluginInstallError: Error, Equatable, Sendable {
    /// No ticket-pilot marketplace is configured and the app carries no copy of the plugin.
    case noBundledPlugin
    /// `claude plugin marketplace list --json` did not answer a JSON list.
    case unreadableMarketplaceList
    /// `command` failed with `error` (its stderr); `completed` are the commands that succeeded before it.
    case commandFailed(command: String, error: String, completed: [PluginCommandResult])

    public var alertText: AlertText {
        let message = switch self {
        case .noBundledPlugin:
            "This copy of TicketPilot carries no plugin. Install it with claude plugin install ticket-pilot@ticket-pilot."
        case .unreadableMarketplaceList:
            "claude plugin marketplace list --json answered something TicketPilot cannot read."
        case let .commandFailed(command, error, _):
            "\(command) failed:\n\n\(error.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return AlertText(title: "The plugin was not installed", message: message)
    }
}

/// Installs or updates the ticket-pilot plugin in Claude Code. A configured "ticket-pilot" marketplace
/// stays authoritative (it is refreshed, then the plugin installed or updated from it); without one, the
/// copy the app carries is added as the marketplace.
public struct PluginInstaller: Sendable {
    public static let marketplace = "ticket-pilot"
    public static let pluginKey = "ticket-pilot@ticket-pilot"

    private let claudePath: String
    private let bundledPlugin: URL?
    private let runner: ProcessRunning

    public init(claudePath: String, bundledPlugin: URL?, runner: ProcessRunning) {
        self.claudePath = claudePath
        self.bundledPlugin = bundledPlugin
        self.runner = runner
    }

    /// The commands to run, after reading the configured marketplaces (read-only).
    public func plan(pluginInstalled: Bool) throws(PluginInstallError) -> [PluginCommand] {
        let installStep = PluginCommand(["plugin", pluginInstalled ? "update" : "install", Self.pluginKey])
        if try marketplaceNames().contains(Self.marketplace) {
            return [PluginCommand(["plugin", "marketplace", "update", Self.marketplace]), installStep]
        }
        guard let bundledPlugin else { throw .noBundledPlugin }
        return [
            PluginCommand(["plugin", "marketplace", "add", bundledPlugin.path]),
            PluginCommand(["plugin", "install", Self.pluginKey]),
        ]
    }

    /// Runs `plan` in order, stopping at the first failure.
    public func run(_ plan: [PluginCommand]) throws(PluginInstallError) -> [PluginCommandResult] {
        var results: [PluginCommandResult] = []
        for command in plan {
            let result = try execute(command, completed: results)
            results.append(PluginCommandResult(command: command, output: result.output, error: result.error))
        }
        return results
    }

    /// "TicketPilot will run: …", for the alert asked before `run`.
    public static func confirmation(_ plan: [PluginCommand]) -> AlertText {
        AlertText(
            title: "Install the Claude Code plugin?",
            message: (["TicketPilot will run:"] + plan.map(\.display)).joined(separator: "\n")
        )
    }

    private func marketplaceNames() throws(PluginInstallError) -> [String] {
        let result = try execute(PluginCommand(["plugin", "marketplace", "list", "--json"]), completed: [])
        guard let list = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [Any] else {
            throw .unreadableMarketplaceList
        }
        return list.compactMap { ($0 as? [String: Any])?["name"] as? String }
    }

    private func execute(_ command: PluginCommand, completed: [PluginCommandResult]) throws(PluginInstallError) -> ProcessResult {
        let result: ProcessResult
        do {
            result = try runner.run(claudePath, command.arguments, currentDirectory: nil)
        } catch {
            throw .commandFailed(command: command.display, error: "\(error)", completed: completed)
        }
        guard result.status == 0 else {
            let error = result.error.isEmpty ? result.output : result.error
            throw .commandFailed(command: command.display, error: error, completed: completed)
        }
        return result
    }
}
