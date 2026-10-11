import Foundation

package struct CLILaunchProfile: Equatable {
    package let commandName: String
    package let preferredBasenames: [String]
    package let supplementalSearchPaths: [String]
}

package enum CLILaunchProfiles {
    package static let claudeCodeProviderSpecificPaths: [String] = [
        "~/.claude/local"
    ]

    package static let openCodeProviderSpecificPaths: [String] = [
        "~/.opencode/bin"
    ]
    package static let cursorProviderSpecificPaths: [String] = []
    package static let ohMyPiProviderSpecificPaths: [String] = ["~/.bun/bin"]

    /// Preserve the committed Codex hint order exactly: shell/package-manager
    /// fallbacks first, then Codex.app resources. System bins are intentionally not
    /// added as supplemental hints because the resolver already searches the built
    /// child PATH, which comes from the user's shell/inherited environment.
    static let codexSupplementalSearchPaths: [String] = orderedUnique(
        CLINativePathDefaults.homebrewBins +
            CLINativePathDefaults.nodePackageManagerBins +
            [
                "~/.bun/bin"
            ] +
            CLINativePathDefaults.versionManagerShimBins +
            [
                "~/.cargo/bin",
                "~/.local/bin",
                "~/bin",
                "~/go/bin",
                "/Applications/Codex.app/Contents/Resources"
            ]
    )

    package static let claudeCode = CLILaunchProfile(
        commandName: "claude",
        preferredBasenames: ["claude"],
        supplementalSearchPaths: nativeDefaultsSupplemented(with: claudeCodeProviderSpecificPaths)
    )

    package static let codex = CLILaunchProfile(
        commandName: "codex",
        preferredBasenames: ["codex"],
        supplementalSearchPaths: codexSupplementalSearchPaths
    )

    static let openCode = CLILaunchProfile(
        commandName: "opencode",
        preferredBasenames: ["opencode"],
        supplementalSearchPaths: providerSpecificPathsSupplementedWithNativeDefaults(openCodeProviderSpecificPaths)
    )

    package static let cursor = CLILaunchProfile(
        commandName: "cursor-agent",
        preferredBasenames: ["cursor-agent"],
        supplementalSearchPaths: nativeDefaultsSupplemented(with: cursorProviderSpecificPaths)
    )

    package static let ohMyPi = CLILaunchProfile(
        commandName: "omp",
        preferredBasenames: ["omp"],
        supplementalSearchPaths: providerSpecificPathsSupplementedWithNativeDefaults(ohMyPiProviderSpecificPaths)
    )

    package static let tailscaleAppBundleExecutablePath = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

    package static let tailscale = CLILaunchProfile(
        commandName: "tailscale",
        preferredBasenames: ["tailscale"],
        supplementalSearchPaths: orderedUnique([
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin"
        ] + CLINativePathDefaults.defaultAdditionalPaths)
    )

    package static func nativeDefaultsSupplemented(with providerSpecificPaths: [String]) -> [String] {
        orderedUnique(CLINativePathDefaults.defaultAdditionalPaths + providerSpecificPaths)
    }

    package static func providerSpecificPathsSupplementedWithNativeDefaults(_ providerSpecificPaths: [String]) -> [String] {
        orderedUnique(providerSpecificPaths + CLINativePathDefaults.defaultAdditionalPaths)
    }

    private static func orderedUnique(_ paths: [String]) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        for path in paths where seen.insert(path).inserted {
            ordered.append(path)
        }
        return ordered
    }
}
