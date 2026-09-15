import Foundation
@testable import RepoPromptApp
import XCTest

/// Runtime-semantics contract for native Claude usage accounting (Oracle decision 2026-09-15):
/// normal builds verify every execution from its launch identity and reported
/// `claude_code_version`; the standard first-party provider path is required, provenance
/// forensics (wrappers, override keys, signatures, configuration, credential category, model or
/// effort) are not. Versions without a recorded contract count tokens only.
final class ClaudeNativeUsageContractTests: XCTestCase {
    private let version = "0.0.0-test"

    override func tearDown() {
        ClaudeNativeUsageContract.test_contractsOverride = nil
        super.tearDown()
    }

    private func launch(
        mode: NativeProcessLaunchIdentity.LaunchMode = .freshSession,
        provenance: ClaudeNativeProcessSessionController.CommandProvenance = .automaticResolved,
        variant: ClaudeCodeRuntimeVariant = .standard,
        realPath: String = "/opt/claude/versions/2.1.268",
        backend: ClaudeCodeLaunchEnvironment.Backend = .defaultClaude,
        overrideKeys: [String] = [],
        configuredKeys: [String] = []
    ) -> NativeProcessLaunchIdentity {
        .init(
            token: UUID(),
            pid: 1,
            launchMode: mode,
            commandProvenance: provenance,
            runtimeVariant: variant,
            executablePath: "/usr/local/bin/claude",
            executableRealPath: realPath,
            backend: backend,
            environmentOverrideKeys: overrideKeys,
            configuredEnvironmentOverrideKeys: configuredKeys,
            spawnedAt: Date()
        )
    }

    /// Normal builds select the execution-verified policy and carry the 2.1.268 semantics
    /// contract; no compile flag, settings or DEBUG override participates.
    func testNormalBuildsVerifyExecutionsAgainstTheSupportedSemanticsContract() {
        XCTAssertEqual(AgentUsageQualification.productionClaude, .executionVerified)
        XCTAssertEqual(ClaudeNativeUsageContract.activeContracts, [ClaudeNativeUsageContract.supported2_1_268])
        XCTAssertEqual(ClaudeNativeUsageContract.contracts, ClaudeNativeUsageContract.activeContracts)
        let supported = ClaudeNativeUsageContract.supported2_1_268
        XCTAssertEqual(supported.contractID, "claude-native.provider-reported.v1@2.1.268")
        XCTAssertEqual(supported.launchModes, [.freshSession, .resumedSession])
        XCTAssertTrue(supported.monetaryQualified)
        XCTAssertTrue(supported.compactionQualified)
        XCTAssertTrue(supported.requiresQueueDepth)
        XCTAssertEqual(supported.maxQueuedTurnCount, 0)
    }

    /// The supported version qualifies fresh launches with a verified zero baseline and resumed
    /// launches with an unknown (prospective) baseline, regardless of wrapper path, configured
    /// executable, override keys or configured launch shape.
    func testSupportedVersionQualifiesFreshAndResumedLaunchesWithoutProvenanceForensics() {
        let contractID = ClaudeNativeUsageContract.supported2_1_268.contractID
        XCTAssertEqual(
            ClaudeNativeUsageContract.verdict(for: launch(), runtimeVersion: "2.1.268"),
            .qualified(contractID: contractID, baseline: .verifiedZero)
        )
        XCTAssertEqual(
            ClaudeNativeUsageContract.verdict(for: launch(mode: .resumedSession("s")), runtimeVersion: "2.1.268"),
            .qualified(contractID: contractID, baseline: .unknown)
        )
        let variants: [(String, NativeProcessLaunchIdentity)] = [
            ("PATH wrapper", launch(realPath: "/usr/local/bin/claude-wrapper.sh")),
            ("configured executable", launch(provenance: .configuredOverride)),
            ("programmatic executable", launch(provenance: .programmaticOverride)),
            ("routing env keys", launch(overrideKeys: ["ANTHROPIC_BASE_URL", "HTTPS_PROXY"])),
            ("agent mode shape", launch(configuredKeys: ["MAX_MCP_OUTPUT_TOKENS", "MCP_TIMEOUT", "MCP_TOOL_TIMEOUT"])),
            ("whitespace version", launch())
        ]
        for (name, identity) in variants {
            XCTAssertEqual(
                ClaudeNativeUsageContract.verdict(for: identity, runtimeVersion: name == "whitespace version" ? " 2.1.268\n" : "2.1.268"),
                .qualified(contractID: contractID, baseline: .verifiedZero),
                name
            )
        }
    }

    /// Only the standard first-party provider path is supported: compatible and explicitly
    /// alternate backends stay excluded, and a missing version cannot qualify anything.
    func testCompatibleBackendsAndMissingVersionStayExcluded() {
        XCTAssertEqual(
            ClaudeNativeUsageContract.verdict(for: launch(variant: .glm, backend: .compatible(.glmZAI)), runtimeVersion: "2.1.268"),
            .blocked(.unsupportedLaunchMode("backend glm"))
        )
        XCTAssertEqual(
            ClaudeNativeUsageContract.verdict(for: launch(), runtimeVersion: " "),
            .blocked(.unsupportedRuntime("runtime version unavailable"))
        )
    }

    /// A version without a recorded contract counts token observations only: the verdict is
    /// qualified with an unsupported monetary baseline and a version-scoped tokens-only contract
    /// identifier, never silently promoted to the cumulative-cost contract.
    func testUnknownVersionsQualifyForTokenObservationsOnly() {
        let verdict = ClaudeNativeUsageContract.verdict(for: launch(), runtimeVersion: "2.1.999")
        XCTAssertEqual(verdict, .qualified(contractID: "claude-native.tokens-only.v1@2.1.999", baseline: .unsupported))
        XCTAssertTrue(ClaudeNativeUsageContract.isTokensOnlyContractID(verdict.contractID ?? ""))
        XCTAssertFalse(ClaudeNativeUsageContract.isTokensOnlyContractID(ClaudeNativeUsageContract.supported2_1_268.contractID))
        XCTAssertEqual(
            ClaudeNativeUsageContract.verdict(for: launch(mode: .resumedSession("s")), runtimeVersion: "2.1.999"),
            .qualified(contractID: "claude-native.tokens-only.v1@2.1.999", baseline: .unsupported)
        )
        XCTAssertEqual(ClaudeNativeUsageContract.policy(forContractID: "claude-native.tokens-only.v1@2.1.999"), .tokensOnly)
        XCTAssertEqual(ClaudeNativeUsageContract.policy(forContractID: nil), .tokensOnly)
    }

    /// A test override still scopes launch modes: a contract that established only fresh
    /// launches blocks resumed ones, and a contract without monetary semantics yields an
    /// unsupported baseline while remaining version-scoped.
    func testOverrideContractsScopeLaunchModesAndMonetarySemantics() {
        ClaudeNativeUsageContract.test_contractsOverride = [
            .init(contractID: "fresh-only@\(version)", runtimeVersion: version, launchModes: [.freshSession])
        ]
        XCTAssertEqual(
            ClaudeNativeUsageContract.verdict(for: launch(), runtimeVersion: version),
            .qualified(contractID: "fresh-only@\(version)", baseline: .verifiedZero)
        )
        XCTAssertEqual(
            ClaudeNativeUsageContract.verdict(for: launch(mode: .resumedSession("s")), runtimeVersion: version),
            .blocked(.unsupportedLaunchMode("resumedSession"))
        )
        ClaudeNativeUsageContract.test_contractsOverride = [
            .init(contractID: "tokens@\(version)", runtimeVersion: version, launchModes: [.freshSession, .resumedSession], monetaryQualified: false)
        ]
        XCTAssertEqual(
            ClaudeNativeUsageContract.verdict(for: launch(), runtimeVersion: version),
            .qualified(contractID: "tokens@\(version)", baseline: .unsupported)
        )
    }

    /// Queue depth beyond the qualified bound is unsupported ownership (never matched to a
    /// guessed dispatch); a missing depth blocks only where the contract established that it is
    /// always reported. Compaction blocks only where cumulative continuation is not established.
    func testQueueBoundAndCounterBoundaryPolicyFollowTheContract() {
        let supported = ClaudeNativeUsageContract.supported2_1_268.contractID
        XCTAssertEqual(
            ClaudeNativeUsageContract.queuePolicyBlock(contractID: supported, queuedTurnCount: nil),
            .unsupportedQueueSemantics("queued_turn_count missing or invalid")
        )
        XCTAssertEqual(
            ClaudeNativeUsageContract.queuePolicyBlock(contractID: supported, queuedTurnCount: 1),
            .unsupportedQueueSemantics("queued_turn_count 1 exceeds qualified bound 0")
        )
        XCTAssertNil(ClaudeNativeUsageContract.queuePolicyBlock(contractID: supported, queuedTurnCount: 0))
        XCTAssertNil(ClaudeNativeUsageContract.counterBoundaryBlock(contractID: supported, kind: "compact_boundary"))
        XCTAssertNil(ClaudeNativeUsageContract.counterBoundaryBlock(contractID: supported, kind: "status:compacting"))

        let tokensOnly = ClaudeNativeUsageContract.tokensOnlyContractID(runtimeVersion: "2.1.999")
        XCTAssertNil(ClaudeNativeUsageContract.queuePolicyBlock(contractID: tokensOnly, queuedTurnCount: nil))
        XCTAssertEqual(
            ClaudeNativeUsageContract.queuePolicyBlock(contractID: tokensOnly, queuedTurnCount: 1),
            .unsupportedQueueSemantics("queued_turn_count 1 exceeds qualified bound 0")
        )
        XCTAssertEqual(
            ClaudeNativeUsageContract.counterBoundaryBlock(contractID: tokensOnly, kind: "compact_boundary"),
            .unsupportedCounterBoundary("compact_boundary")
        )
        XCTAssertEqual(
            ClaudeNativeUsageContract.counterBoundaryBlock(contractID: nil, kind: "compact_boundary"),
            .unsupportedCounterBoundary("compact_boundary")
        )

        ClaudeNativeUsageContract.test_contractsOverride = [
            .init(contractID: "strict", runtimeVersion: version, launchModes: [.freshSession]),
            .init(contractID: "relaxed", runtimeVersion: version, launchModes: [.freshSession], maxQueuedTurnCount: 1, compactionQualified: true)
        ]
        XCTAssertEqual(
            ClaudeNativeUsageContract.queuePolicyBlock(contractID: "strict", queuedTurnCount: 1),
            .unsupportedQueueSemantics("queued_turn_count 1 exceeds qualified bound 0")
        )
        XCTAssertNil(ClaudeNativeUsageContract.queuePolicyBlock(contractID: "relaxed", queuedTurnCount: 1))
        XCTAssertEqual(
            ClaudeNativeUsageContract.counterBoundaryBlock(contractID: "strict", kind: "compact_boundary"),
            .unsupportedCounterBoundary("compact_boundary")
        )
        XCTAssertNil(ClaudeNativeUsageContract.counterBoundaryBlock(contractID: "relaxed", kind: "compact_boundary"))
    }
}
