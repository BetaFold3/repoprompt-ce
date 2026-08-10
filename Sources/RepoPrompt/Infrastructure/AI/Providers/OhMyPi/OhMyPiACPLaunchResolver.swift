import Foundation

struct OhMyPiACPResolvedLaunch: Equatable {
    let command: String
    let arguments: [String]
    let additionalPathHints: [String]
    let executableIdentity: ExecutableFileIdentity
}

enum OhMyPiACPLaunchResolutionError: Error, Equatable, LocalizedError {
    case missingConfiguredCommand
    case unsafeConfiguredCommand(String)
    case exactPathNotFound(String)
    case noValidLaunchCandidate(String, [String], ShellEnvironmentSource?)
    case environmentDiscoveryRequired(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguredCommand:
            "Oh My Pi ACP launch requires the omp command or an absolute omp executable path."
        case let .unsafeConfiguredCommand(command):
            "Refusing Oh My Pi ACP command \(command). Configure the omp executable only."
        case let .exactPathNotFound(command):
            "Oh My Pi CLI was not found as a valid executable regular file for \(command)."
        case let .noValidLaunchCandidate(command, failures, source):
            AgentCLILaunchDiagnostics.appendFallbackEnvironmentHint(
                to: "Oh My Pi CLI was not found for \(command). Tried: \(failures.joined(separator: "; "))",
                source: source
            )
        case let .environmentDiscoveryRequired(command):
            "Oh My Pi CLI path discovery has not completed for \(command). Run the OMP support preflight or configure an absolute path."
        }
    }
}

final class OhMyPiACPLaunchResolver: @unchecked Sendable {
    typealias EnvironmentProvider = @Sendable (_ enableDebugLogging: Bool) async -> ACPLaunchEnvironment

    private static let acpHelpArguments = ["acp", "--help"]
    private static let rootHelpArguments = ["--help"]
    private static let versionArguments = ["--version"]

    private let environmentProvider: EnvironmentProvider
    private let probeMutex = AsyncMutex()
    private let lock = NSLock()
    private var cachedLaunchByKey: [String: OhMyPiACPResolvedLaunch] = [:]

    convenience init(
        environmentProvider: @escaping @Sendable (_ enableDebugLogging: Bool) async -> [String: String]
    ) {
        self.init(launchEnvironmentProvider: { enableDebugLogging in
            await ACPLaunchEnvironment(environment: environmentProvider(enableDebugLogging))
        })
    }

    init(
        launchEnvironmentProvider: @escaping EnvironmentProvider = { enableDebugLogging in
            let result = await ProcessEnvironmentBuilder.build(
                ProcessEnvironmentRequest(
                    purpose: .acpAgent(providerID: ACPProviderID.ohMyPi.rawValue),
                    enableDebugLogging: enableDebugLogging
                )
            )
            return ACPLaunchEnvironment(
                environment: result.environment,
                shellEnvironmentSource: result.shellEnvironmentSource
            )
        }
    ) {
        environmentProvider = launchEnvironmentProvider
    }

    func resolvedLaunch(for config: OhMyPiAgentConfig) throws -> OhMyPiACPResolvedLaunch {
        let key = cacheKey(for: config)
        if let cached = cachedLaunch(forKey: key) {
            do {
                try cached.executableIdentity.validateForTrustedPathLaunch(atPath: cached.command)
                return cached
            } catch {
                invalidate(key: key)
                throw error
            }
        }
        let launch = try resolveExplicitLaunch(for: config)
        cache(launch, key: key)
        return launch
    }

    func probeSupport(for config: OhMyPiAgentConfig) async throws -> ACPSupportResult {
        try await probeMutex.withLock { [self] in
            try await probeSupportSerially(for: config)
        }
    }

    private func probeSupportSerially(for config: OhMyPiAgentConfig) async throws -> ACPSupportResult {
        let key = cacheKey(for: config)
        invalidate(key: key)
        do {
            let launch = try await resolveLaunchForProbe(for: config)
            let processConfig = CLIProcessConfiguration(
                command: launch.command,
                additionalPaths: [],
                enableDebugLogging: config.enableDebugLogging,
                shellLookupMode: .fallbackOnly
            )
            let help = try await CLIProcessRunner(config: processConfig).run(
                args: Self.acpHelpArguments,
                stdin: nil,
                outputMode: .none,
                timeout: 10,
                cancelChildOnTaskCancellation: true
            )
            guard help.status == 0 else {
                return .unsupported(reason: "Oh My Pi ACP preflight failed: omp acp --help exited with status \(help.status).")
            }
            let rootHelp = try await CLIProcessRunner(config: processConfig).run(
                args: Self.rootHelpArguments,
                stdin: nil,
                outputMode: .none,
                timeout: 10,
                cancelChildOnTaskCancellation: true
            )
            guard rootHelp.status == 0 else {
                return .unsupported(reason: "Oh My Pi global flag preflight failed: omp --help exited with status \(rootHelp.status).")
            }
            let rootHelpText = Self.combinedOutput(rootHelp)
            let missingFlags = OhMyPiAgentConfig.requiredManagedFlags.filter {
                !rootHelpText.contains($0)
            }
            guard missingFlags.isEmpty else {
                return .unsupported(
                    reason: "Installed Oh My Pi ACP does not support required managed flags: \(missingFlags.joined(separator: ", "))."
                )
            }

            let versionResult = try await CLIProcessRunner(config: processConfig).run(
                args: Self.versionArguments,
                stdin: nil,
                outputMode: .none,
                timeout: 10,
                cancelChildOnTaskCancellation: true
            )
            guard versionResult.status == 0 else {
                return .unsupported(reason: "Oh My Pi version preflight failed with status \(versionResult.status).")
            }
            let versionText = Self.combinedOutput(versionResult)
            guard let version = Self.parseVersion(versionText) else {
                return .unsupported(reason: "Unable to parse Oh My Pi version from omp --version.")
            }
            guard Self.isVersion(version, atLeast: OhMyPiAgentConfig.minimumSupportedVersion) else {
                let minimum = OhMyPiAgentConfig.minimumSupportedVersion.map(String.init).joined(separator: ".")
                return .unsupported(reason: "Oh My Pi \(version.map(String.init).joined(separator: ".")) is unsupported; version \(minimum) or newer is required.")
            }

            try launch.executableIdentity.validateForTrustedPathLaunch(atPath: launch.command)
            cache(launch, key: key)
            return .supported
        } catch is CancellationError {
            invalidate(key: key)
            throw CancellationError()
        } catch {
            invalidate(key: key)
            return .unsupported(reason: error.localizedDescription)
        }
    }

    private func resolveLaunchForProbe(for config: OhMyPiAgentConfig) async throws -> OhMyPiACPResolvedLaunch {
        let configuredCommand = try validatedConfiguredCommand(config)
        let launchEnvironment = await environmentProvider(config.enableDebugLogging)
        let environment = launchEnvironment.environment
        try Task.checkCancellation()
        if configuredCommand.contains("/") {
            return try resolveExplicitLaunch(
                for: config,
                environment: environment,
                shellEnvironmentSource: launchEnvironment.shellEnvironmentSource
            )
        }
        let effectiveHints = CLILaunchProfiles.providerSpecificPathsSupplementedWithNativeDefaults(config.additionalPathHints)
        return try firstValidLaunch(
            candidates: launchCandidates(
                additionalPathHints: effectiveHints,
                environment: environment
            ),
            configuredCommand: configuredCommand,
            additionalPathHints: effectiveHints,
            shellEnvironmentSource: launchEnvironment.shellEnvironmentSource
        )
    }

    private func resolveExplicitLaunch(
        for config: OhMyPiAgentConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shellEnvironmentSource: ShellEnvironmentSource? = nil
    ) throws -> OhMyPiACPResolvedLaunch {
        let configuredCommand = try validatedConfiguredCommand(config)
        guard configuredCommand.contains("/") else {
            throw OhMyPiACPLaunchResolutionError.environmentDiscoveryRequired(configuredCommand)
        }
        let effectiveHints = CLILaunchProfiles.providerSpecificPathsSupplementedWithNativeDefaults(config.additionalPathHints)
        do {
            return try validatedLaunch(
                entryPath: CommandPathResolver.expandPath(configuredCommand, environment: environment),
                configuredCommand: configuredCommand,
                additionalPathHints: effectiveHints
            )
        } catch {
            AgentCLILaunchDiagnostics.recordPathResolutionFailure(
                providerKind: .ohMyPi,
                shellEnvironmentSource: shellEnvironmentSource,
                candidateCount: 1
            )
            throw error
        }
    }

    private func validatedConfiguredCommand(_ config: OhMyPiAgentConfig) throws -> String {
        let command = config.commandName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            throw OhMyPiACPLaunchResolutionError.missingConfiguredCommand
        }
        let basename = (command as NSString).lastPathComponent
        guard basename.caseInsensitiveCompare("omp") == .orderedSame else {
            throw OhMyPiACPLaunchResolutionError.unsafeConfiguredCommand(command)
        }
        return command
    }

    private func validatedLaunch(
        entryPath: String,
        configuredCommand: String,
        additionalPathHints: [String]
    ) throws -> OhMyPiACPResolvedLaunch {
        guard entryPath.hasPrefix("/"),
              (entryPath as NSString).lastPathComponent.caseInsensitiveCompare("omp") == .orderedSame
        else {
            throw OhMyPiACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }
        let identity = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: entryPath)
        return OhMyPiACPResolvedLaunch(
            command: identity.canonicalPath,
            arguments: OhMyPiAgentConfig.managedArguments,
            additionalPathHints: additionalPathHints,
            executableIdentity: identity
        )
    }

    private func launchCandidates(
        additionalPathHints: [String],
        environment: [String: String]
    ) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()
        func append(_ candidate: String) {
            let expanded = CommandPathResolver.expandPath(candidate, environment: environment)
            guard !expanded.isEmpty, expanded.hasPrefix("/"), seen.insert(expanded).inserted else { return }
            candidates.append(expanded)
        }
        append(
            CommandPathResolver.resolve(
                "omp",
                environment: environment,
                additionalPaths: additionalPathHints,
                preferredBasenames: CLILaunchProfiles.ohMyPi.preferredBasenames,
                shellLookupMode: .fallbackOnly
            )
        )
        for directory in CommandPathResolver.mergedPathComponents(
            environment: environment,
            additionalPaths: additionalPathHints
        ) {
            append((directory as NSString).appendingPathComponent("omp"))
        }
        return candidates
    }

    private func firstValidLaunch(
        candidates: [String],
        configuredCommand: String,
        additionalPathHints: [String],
        shellEnvironmentSource: ShellEnvironmentSource?
    ) throws -> OhMyPiACPResolvedLaunch {
        var failures: [String] = []
        for candidate in candidates {
            do {
                return try validatedLaunch(
                    entryPath: candidate,
                    configuredCommand: configuredCommand,
                    additionalPathHints: additionalPathHints
                )
            } catch {
                failures.append("\(candidate): \(error.localizedDescription)")
            }
        }
        AgentCLILaunchDiagnostics.recordPathResolutionFailure(
            providerKind: .ohMyPi,
            shellEnvironmentSource: shellEnvironmentSource,
            candidateCount: candidates.count
        )
        if failures.isEmpty {
            throw OhMyPiACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }
        throw OhMyPiACPLaunchResolutionError.noValidLaunchCandidate(configuredCommand, failures, shellEnvironmentSource)
    }

    private static func combinedOutput(_ result: CLIProcessRunner.Result) -> String {
        let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        return "\(stdout)\n\(stderr)"
    }

    static func parseVersion(_ text: String) -> [Int]? {
        let components = text.split { !$0.isNumber && $0 != "." }
        for component in components {
            let parts = component.split(separator: ".").compactMap { Int($0) }
            if parts.count >= 3 {
                return Array(parts.prefix(3))
            }
        }
        return nil
    }

    private static func isVersion(_ version: [Int], atLeast minimum: [Int]) -> Bool {
        for index in 0 ..< max(version.count, minimum.count) {
            let lhs = index < version.count ? version[index] : 0
            let rhs = index < minimum.count ? minimum[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return true
    }

    private func cachedLaunch(forKey key: String) -> OhMyPiACPResolvedLaunch? {
        lock.lock()
        defer { lock.unlock() }
        return cachedLaunchByKey[key]
    }

    private func cache(_ launch: OhMyPiACPResolvedLaunch, key: String) {
        lock.lock()
        cachedLaunchByKey[key] = launch
        lock.unlock()
    }

    private func invalidate(key: String) {
        lock.lock()
        cachedLaunchByKey.removeValue(forKey: key)
        lock.unlock()
    }

    private func cacheKey(for config: OhMyPiAgentConfig) -> String {
        ([config.commandName] + config.additionalPathHints).joined(separator: "\u{1F}")
    }
}
