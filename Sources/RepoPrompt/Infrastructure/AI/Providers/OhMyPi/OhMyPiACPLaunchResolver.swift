import Foundation

struct OhMyPiACPResolvedLaunch: Equatable {
    let command: String
    let arguments: [String]
    let additionalPathHints: [String]
    let executableIdentity: ExecutableFileIdentity
    let processExecutablePath: String
    let processExecutableIdentity: ExecutableFileIdentity
}

enum OhMyPiACPLaunchResolutionError: Error, Equatable, LocalizedError {
    case missingConfiguredCommand
    case unsafeConfiguredCommand(String)
    case exactPathNotFound(String)
    case entryNotExecutable(String)
    case noValidLaunchCandidate(String, [String], ShellEnvironmentSource?)
    case environmentDiscoveryRequired(String)
    case invalidProcessExecutable(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguredCommand:
            "Oh My Pi ACP launch requires the omp command or an absolute omp executable path."
        case let .unsafeConfiguredCommand(command):
            "Refusing Oh My Pi ACP command \(command). Configure the omp executable only."
        case let .exactPathNotFound(command):
            "Oh My Pi CLI is unavailable at \(command). Install or reinstall OMP, ensure omp is on PATH, or configure the correct absolute path."
        case let .entryNotExecutable(path):
            "Oh My Pi CLI is installed but not executable at \(path). Run chmod u+x on the reported path or reinstall OMP."
        case let .noValidLaunchCandidate(command, failures, source):
            AgentCLILaunchDiagnostics.appendFallbackEnvironmentHint(
                to: "Oh My Pi CLI is unavailable for \(command). Install or reinstall OMP, ensure omp is on PATH, or configure the correct absolute path. Tried: \(failures.joined(separator: "; "))",
                source: source
            )
        case let .environmentDiscoveryRequired(command):
            "Oh My Pi CLI path discovery has not completed for \(command). Run the OMP support preflight or configure an absolute path."
        case let .invalidProcessExecutable(reason):
            "Unable to pin the Oh My Pi process executable: \(reason)"
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
                throw Self.actionableEntryError(error, configuredCommand: cached.command)
            }
        }
        let launch = try resolveExplicitLaunch(for: config)
        cache(launch, key: key)
        return launch
    }

    func resolvedLaunch(
        for config: OhMyPiAgentConfig,
        environment: [String: String]
    ) throws -> OhMyPiACPResolvedLaunch {
        try resolveExplicitLaunch(for: config, environment: environment)
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
            OhMyPiRuntimeVersionRegistry.shared.observe(version)

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
            environment: environment,
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
                additionalPathHints: effectiveHints,
                environment: environment
            )
        } catch {
            AgentCLILaunchDiagnostics.recordPathResolutionFailure(
                providerKind: .ohMyPi,
                shellEnvironmentSource: shellEnvironmentSource,
                candidateCount: 1
            )
            throw Self.actionableEntryError(error, configuredCommand: configuredCommand)
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
        additionalPathHints: [String],
        environment: [String: String]
    ) throws -> OhMyPiACPResolvedLaunch {
        guard entryPath.hasPrefix("/"),
              (entryPath as NSString).lastPathComponent.caseInsensitiveCompare("omp") == .orderedSame
        else {
            throw OhMyPiACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }
        let identity = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: entryPath)
        let processIdentity = try expectedProcessExecutableIdentity(
            entryIdentity: identity,
            environment: environment
        )
        return OhMyPiACPResolvedLaunch(
            command: identity.canonicalPath,
            arguments: OhMyPiAgentConfig.managedArguments,
            additionalPathHints: additionalPathHints,
            executableIdentity: identity,
            processExecutablePath: processIdentity.canonicalPath,
            processExecutableIdentity: processIdentity
        )
    }

    private func expectedProcessExecutableIdentity(
        entryIdentity: ExecutableFileIdentity,
        environment: [String: String]
    ) throws -> ExecutableFileIdentity {
        var visitedIdentities = Set<String>()
        return try resolveProcessExecutableIdentity(
            entryIdentity,
            environment: environment,
            remainingScriptDepth: 4,
            visitedIdentities: &visitedIdentities
        )
    }

    private func resolveProcessExecutableIdentity(
        _ identity: ExecutableFileIdentity,
        environment: [String: String],
        remainingScriptDepth: Int,
        visitedIdentities: inout Set<String>
    ) throws -> ExecutableFileIdentity {
        let identityKey = "\(identity.device):\(identity.inode)"
        guard visitedIdentities.insert(identityKey).inserted else {
            throw OhMyPiACPLaunchResolutionError.invalidProcessExecutable(
                "interpreter script chain contains a cycle at \(identity.canonicalPath)"
            )
        }

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: identity.canonicalPath))
            defer { try? handle.close() }
            data = try handle.read(upToCount: 4096) ?? Data()
        } catch {
            throw OhMyPiACPLaunchResolutionError.invalidProcessExecutable(
                "executable is unreadable at \(identity.canonicalPath)"
            )
        }
        if Self.isMachOExecutable(data) {
            return identity
        }
        guard remainingScriptDepth > 0 else {
            throw OhMyPiACPLaunchResolutionError.invalidProcessExecutable(
                "interpreter chain did not terminate at a Mach-O image within 3 script hops"
            )
        }

        let tokens = try Self.shebangTokens(in: data, path: identity.canonicalPath)
        guard let interpreter = tokens.first, interpreter.hasPrefix("/") else {
            throw OhMyPiACPLaunchResolutionError.invalidProcessExecutable(
                "shebang interpreter path must be absolute"
            )
        }

        let interpreterIdentity: ExecutableFileIdentity
        if interpreter == "/usr/bin/env" {
            guard tokens.count == 2 else {
                throw OhMyPiACPLaunchResolutionError.invalidProcessExecutable(
                    "/usr/bin/env shebang must contain exactly one interpreter command"
                )
            }
            let command = tokens[1]
            guard !command.hasPrefix("-"), !command.contains("/") else {
                throw OhMyPiACPLaunchResolutionError.invalidProcessExecutable(
                    "/usr/bin/env interpreter must be a single command name without options"
                )
            }
            interpreterIdentity = try resolveEnvironmentInterpreter(command, environment: environment)
        } else {
            do {
                interpreterIdentity = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: interpreter)
            } catch {
                throw OhMyPiACPLaunchResolutionError.invalidProcessExecutable(error.localizedDescription)
            }
        }

        return try resolveProcessExecutableIdentity(
            interpreterIdentity,
            environment: environment,
            remainingScriptDepth: remainingScriptDepth - 1,
            visitedIdentities: &visitedIdentities
        )
    }

    private func resolveEnvironmentInterpreter(
        _ command: String,
        environment: [String: String]
    ) throws -> ExecutableFileIdentity {
        guard let path = environment["PATH"] else {
            throw OhMyPiACPLaunchResolutionError.invalidProcessExecutable(
                "launch PATH is missing"
            )
        }
        let components = path.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0.hasPrefix("/") })
        else {
            throw OhMyPiACPLaunchResolutionError.invalidProcessExecutable(
                "launch PATH contains an empty or non-absolute component"
            )
        }

        for directory in components {
            let candidate = (directory as NSString).appendingPathComponent(command)
            guard CommandPathResolver.launchability(of: candidate) == .launchable else { continue }
            do {
                return try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: candidate)
            } catch {
                throw OhMyPiACPLaunchResolutionError.invalidProcessExecutable(error.localizedDescription)
            }
        }
        throw OhMyPiACPLaunchResolutionError.invalidProcessExecutable(
            "interpreter \(command) is not resolvable on the launch PATH"
        )
    }

    private static func shebangTokens(in data: Data, path: String) throws -> [String] {
        let bytes = [UInt8](data)
        guard bytes.count >= 2, bytes[0] == 0x23, bytes[1] == 0x21 else {
            throw OhMyPiACPLaunchResolutionError.invalidProcessExecutable(
                "non-Mach-O executable has no shebang at byte offset 0: \(path)"
            )
        }
        let lineEnd = bytes.firstIndex(of: 0x0A) ?? bytes.endIndex
        let line = Array(bytes[..<lineEnd])
        guard !line.contains(0x0D) else {
            throw OhMyPiACPLaunchResolutionError.invalidProcessExecutable(
                "shebang line must not contain a carriage return"
            )
        }

        var tokenData: [Data] = []
        var current: [UInt8] = []
        for byte in line.dropFirst(2) {
            if byte == 0x20 || byte == 0x09 {
                if !current.isEmpty {
                    tokenData.append(Data(current))
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(byte)
            }
        }
        if !current.isEmpty {
            tokenData.append(Data(current))
        }
        guard !tokenData.isEmpty else {
            throw OhMyPiACPLaunchResolutionError.invalidProcessExecutable(
                "shebang line has no interpreter"
            )
        }

        var tokens: [String] = []
        for token in tokenData {
            guard let decoded = String(data: token, encoding: .utf8) else {
                throw OhMyPiACPLaunchResolutionError.invalidProcessExecutable(
                    "shebang line is not valid UTF-8"
                )
            }
            tokens.append(decoded)
        }
        return tokens
    }

    private static func isMachOExecutable(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let magic = Array(data.prefix(4))
        return [
            [0xFE, 0xED, 0xFA, 0xCE], [0xCE, 0xFA, 0xED, 0xFE],
            [0xFE, 0xED, 0xFA, 0xCF], [0xCF, 0xFA, 0xED, 0xFE],
            [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA],
            [0xCA, 0xFE, 0xBA, 0xBF], [0xBF, 0xBA, 0xFE, 0xCA]
        ].contains(magic)
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
        environment: [String: String],
        shellEnvironmentSource: ShellEnvironmentSource?
    ) throws -> OhMyPiACPResolvedLaunch {
        var failures: [String] = []
        for candidate in candidates {
            do {
                return try validatedLaunch(
                    entryPath: candidate,
                    configuredCommand: configuredCommand,
                    additionalPathHints: additionalPathHints,
                    environment: environment
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

    private static func actionableEntryError(_ error: Error, configuredCommand: String) -> Error {
        guard let identityError = error as? ExecutableFileIdentityError else { return error }
        switch identityError {
        case .unavailable:
            return OhMyPiACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        case let .notExecutable(path):
            return OhMyPiACPLaunchResolutionError.entryNotExecutable(path)
        case .pathMustBeAbsolute,
             .notRegularFile,
             .identityChanged,
             .untrustedOwner,
             .untrustedWritableFile,
             .untrustedWritableDirectory:
            return identityError
        }
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
