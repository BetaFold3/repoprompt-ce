import Darwin
import Foundation

enum CLICommandSelection: Equatable {
    case automatic(command: String)
    case configuredExactPath(String)
    case programmaticOverride(command: String)

    var command: String {
        switch self {
        case let .automatic(command), let .configuredExactPath(command), let .programmaticOverride(command):
            command
        }
    }
}

enum CLIExecutableOverrideError: LocalizedError {
    static let messagePrefix = "CLI executable override error:"

    case notAbsolute
    case containsVariableExpression
    case missing
    case directory(suggestion: String)
    case notExecutable
    case brokenSymlink
    case corruptStoredValue(typeDescription: String)
    case launchFailedAfterValidation(underlying: Error)

    var errorDescription: String? {
        let detail = switch self {
        case .notAbsolute:
            "Enter a local absolute path. NUL bytes, embedded line breaks, non-local file URLs, and ~otheruser syntax are not supported."
        case .containsVariableExpression:
            "Variable expressions are not supported; no expansion occurs. Enter the full absolute path."
        case .missing:
            "The configured path does not exist. Install the executable there or choose another path."
        case let .directory(suggestion):
            "The configured path is a directory. Try \(suggestion)."
        case .notExecutable:
            "The configured path must be an executable regular file."
        case .brokenSymlink:
            "The configured path is a broken symbolic link. Repair its target or choose another path."
        case let .corruptStoredValue(typeDescription):
            "The stored value has type \(typeDescription), not String. Reset the setting and apply it again."
        case let .launchFailedAfterValidation(underlying):
            "The executable passed validation but launch failed: \(underlying.localizedDescription)"
        }
        return "\(Self.messagePrefix) \(detail)"
    }
}

enum CLIExecutableOverrideStore {
    private static let keyPrefix = "cliExecutableOverride."

    static func key(for profile: CLILaunchProfile) -> String {
        keyPrefix + profile.commandName
    }

    static func effectiveCommand(
        for profile: CLILaunchProfile,
        defaults: UserDefaults = .standard
    ) throws -> CLICommandSelection {
        let storageKey = key(for: profile)
        guard let storedValue = defaults.object(forKey: storageKey) else {
            return .automatic(command: profile.commandName)
        }
        guard let storedPath = storedValue as? String else {
            throw CLIExecutableOverrideError.corruptStoredValue(
                typeDescription: String(reflecting: type(of: storedValue))
            )
        }
        guard !storedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .automatic(command: profile.commandName)
        }
        return .configuredExactPath(storedPath)
    }

    @discardableResult
    static func apply(
        _ input: String,
        for profile: CLILaunchProfile,
        defaults: UserDefaults = .standard
    ) throws -> CLICommandSelection {
        guard let normalizedPath = try normalizeForApply(input) else {
            defaults.removeObject(forKey: key(for: profile))
            return .automatic(command: profile.commandName)
        }

        try validateForLaunch(normalizedPath, commandName: profile.commandName)
        defaults.set(normalizedPath, forKey: key(for: profile))
        return .configuredExactPath(normalizedPath)
    }

    static func reset(
        for profile: CLILaunchProfile,
        defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: key(for: profile))
    }

    static func normalizeForApply(_ input: String) throws -> String? {
        var normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }
        try rejectUnsupportedCharacters(in: normalized)

        if normalized.range(of: "file:", options: [.anchored, .caseInsensitive]) != nil {
            guard let url = URL(string: normalized),
                  url.isFileURL,
                  let scheme = url.scheme,
                  scheme.caseInsensitiveCompare("file") == .orderedSame,
                  url.host == nil || url.host?.isEmpty == true || url.host == "localhost"
            else {
                throw CLIExecutableOverrideError.notAbsolute
            }
            normalized = url.path
            try rejectUnsupportedCharacters(in: normalized)
        }

        if normalized == "~" {
            normalized = NSHomeDirectory()
        } else if normalized.hasPrefix("~/") {
            normalized = NSHomeDirectory() + String(normalized.dropFirst())
        } else if normalized.hasPrefix("~") {
            throw CLIExecutableOverrideError.notAbsolute
        }

        if containsVariableExpression(normalized) {
            throw CLIExecutableOverrideError.containsVariableExpression
        }
        guard (normalized as NSString).isAbsolutePath else {
            throw CLIExecutableOverrideError.notAbsolute
        }
        return normalized
    }

    @discardableResult
    static func validateForLaunch(
        _ path: String,
        commandName: String = CLILaunchProfiles.claudeCode.commandName
    ) throws -> String {
        guard (path as NSString).isAbsolutePath else {
            throw CLIExecutableOverrideError.notAbsolute
        }

        var linkMetadata = stat()
        guard lstat(path, &linkMetadata) == 0 else {
            throw CLIExecutableOverrideError.missing
        }

        let isSymbolicLink = (linkMetadata.st_mode & S_IFMT) == S_IFLNK
        if isSymbolicLink {
            var targetMetadata = stat()
            guard stat(path, &targetMetadata) == 0 else {
                throw CLIExecutableOverrideError.brokenSymlink
            }
        }

        switch CommandPathResolver.launchability(of: path) {
        case .launchable:
            break
        case .bareCommandFallback:
            throw CLIExecutableOverrideError.notAbsolute
        case .missingPath:
            throw isSymbolicLink
                ? CLIExecutableOverrideError.brokenSymlink
                : CLIExecutableOverrideError.missing
        case .directory:
            let suggestion = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent(commandName)
                .path
            throw CLIExecutableOverrideError.directory(suggestion: suggestion)
        case .notExecutable:
            throw CLIExecutableOverrideError.notExecutable
        }

        var targetMetadata = stat()
        guard stat(path, &targetMetadata) == 0 else {
            throw isSymbolicLink
                ? CLIExecutableOverrideError.brokenSymlink
                : CLIExecutableOverrideError.missing
        }
        guard (targetMetadata.st_mode & S_IFMT) == S_IFREG else {
            throw CLIExecutableOverrideError.notExecutable
        }
        return path
    }

    private static func rejectUnsupportedCharacters(in path: String) throws {
        guard !path.contains("\0"),
              path.rangeOfCharacter(from: .newlines) == nil
        else {
            throw CLIExecutableOverrideError.notAbsolute
        }
    }

    private static func containsVariableExpression(_ path: String) -> Bool {
        path.range(
            of: #"\$(?:\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)"#,
            options: .regularExpression
        ) != nil
    }
}
