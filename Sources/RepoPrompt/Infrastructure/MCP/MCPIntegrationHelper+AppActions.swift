import AppKit
import Foundation
import RepoPromptAgentCore

/// App-level MCP integration actions: deep links into other apps, the clipboard,
/// and command-line installers.
extension MCPIntegrationHelper {
    /// Opens a Cursor deeplink that installs the MCP server config.
    static func installInCursor() {
        guard
            let jsonData = try? JSONSerialization.data(withJSONObject: mcpConfigDict, options: []),
            let jsonString = String(data: jsonData, encoding: .utf8)
        else { return }

        let base64Config = Data(jsonString.utf8).base64EncodedString()
        let urlString = "cursor://anysphere.cursor-deeplink/mcp/install?name=RepoPrompt&config=\(base64Config)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }

        setMCPServerInstalled()
    }

    /// Opens a VS Code deeplink that installs the RepoPrompt MCP server config.
    ///
    /// VS Code expects a single JSON object containing at least a `name`
    /// field plus the server configuration. Omitting `name` causes the
    /// entry to appear as "undefined" in its UI.
    static func installInVSCode() {
        let payload: [String: Any] = [
            "name": repoPromptMCPConfiguration.name,
            "command": repoPromptMCPConfiguration.command,
            "args": repoPromptMCPConfiguration.args
        ]

        guard
            let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
            let jsonString = String(data: jsonData, encoding: .utf8)
        else { return }

        // VS Code expects the JSON directly URL-encoded in the query string.
        let percentEncoded = jsonString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "vscode:mcp/install?\(percentEncoded)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }

        setMCPServerInstalled()
    }

    // MARK: – Clipboard --------------------------------------------------------

    /// Copies the JSON snippet (uses the stable symlink path) to the clipboard.
    static func copyConfigToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(jsonSnippet, forType: .string)
    }

    // MARK: - CLI PATH Installation ------------------------------------------------

    /// Installs the CLI to /usr/local/bin as rpce-cli (release) or rpce-cli-debug (debug).
    /// Uses AppleScript to request admin privileges.
    @MainActor
    static func installCLIToPath() async throws {
        try await CLIPathInstaller.install()
    }

    /// Uninstalls the CLI from /usr/local/bin.
    /// Uses AppleScript to request admin privileges.
    @MainActor
    static func uninstallCLIFromPath() async throws {
        try await CLIPathInstaller.uninstall()
    }

    /// Returns the current CLI PATH installation status.
    @MainActor
    static func cliPathInstallStatus() -> CLIPathInstaller.InstallationStatus {
        CLIPathInstaller.checkStatus()
    }

    /// The CLI command name that will be installed (rpce-cli or rpce-cli-debug).
    static var cliCommandName: String {
        CLIPathInstaller.cliCommandName
    }

    /// The directory where the CLI will be installed.
    static var cliInstallDirectory: String {
        CLIPathInstaller.installDirectory
    }

    /// The full path where the CLI will be installed.
    static var cliInstallPath: String {
        CLIPathInstaller.installPath
    }

    // MARK: - claude-rp Wrapper Installation ----------------------------------------

    /// Installs the claude-rp wrapper to /usr/local/bin.
    /// This wrapper runs Claude Code with RepoPrompt's MCP tools preferred over built-in tools.
    /// Uses AppleScript to request admin privileges.
    @MainActor
    static func installClaudeRP() async throws {
        try await CLIPathInstaller.installClaudeRP()
    }

    /// Uninstalls the claude-rp wrapper from /usr/local/bin.
    /// Uses AppleScript to request admin privileges.
    @MainActor
    static func uninstallClaudeRP() async throws {
        try await CLIPathInstaller.uninstallClaudeRP()
    }

    /// Returns the current claude-rp wrapper installation status.
    @MainActor
    static func claudeRPInstallStatus() -> CLIPathInstaller.ClaudeRPInstallationStatus {
        CLIPathInstaller.checkClaudeRPStatus()
    }

    /// Human-readable description of the claude-rp wrapper status.
    @MainActor
    static func claudeRPStatusDescription() -> String {
        CLIPathInstaller.claudeRPStatusDescription()
    }

    /// The claude-rp command name that will be installed (claude-rpce or claude-rpce-debug).
    static var claudeRPCommandName: String {
        CLIPathInstaller.claudeRPCommandName
    }

    /// The full path where the claude-rp wrapper will be installed.
    static var claudeRPInstallPath: String {
        CLIPathInstaller.claudeRPInstallPath
    }
}
