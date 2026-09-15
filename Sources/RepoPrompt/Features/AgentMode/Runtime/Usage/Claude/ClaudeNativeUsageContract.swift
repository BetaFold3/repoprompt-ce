import Foundation

/// Runtime-semantics contract for native Claude usage accounting (plan §3.2 / §4, Oracle
/// decision 2026-09-15: normal-build session totals, not a special qualification build).
///
/// The figures are the runtime's own reported estimates (`usage` per result, cumulative
/// `total_cost_usd` per process), never endpoint attestations or invoices. A contract therefore
/// qualifies *semantics*, not provenance: the standard first-party provider path, the reported
/// `claude_code_version` whose result/cost cadence was established on captured evidence, and the
/// launch mode's monetary baseline. Wrappers, configured executables, environment override keys,
/// code signatures, configuration fingerprints, credential categories and model/effort selection
/// are not requirements; ownership (dispatch/result correlation, contiguity, deduplication, late
/// and replayed events) remains enforced by the controller and the accumulator.
///
/// Versions without a recorded contract still qualify for **token observations only**: per-result
/// `usage` triples contribute to the cache-hit share while the cumulative-cost baseline stays
/// unavailable for that execution. They are never silently promoted to the monetary contract.
enum ClaudeNativeUsageContract {
    enum LaunchModeKind: String, Equatable {
        case freshSession
        case resumedSession
    }

    struct Qualified: Equatable {
        /// Version-scoped contract identifier persisted on every segment it opens.
        let contractID: String
        /// Exact runtime-reported `claude_code_version` whose semantics were established.
        let runtimeVersion: String
        /// Launch modes whose baseline behaviour is established (fresh = verified zero, resumed =
        /// unknown/prospective).
        let launchModes: Set<LaunchModeKind>
        /// Largest `queued_turn_count` a result may carry while dispatch ownership is still proven.
        let maxQueuedTurnCount: Int
        /// Whether a missing `queued_turn_count` is itself unsupported (the qualified version
        /// always reports it).
        let requiresQueueDepth: Bool
        /// Whether cumulative cost continues across a same-process compaction boundary without a
        /// baseline/generation reset (established on the 2.1.268 captures).
        let compactionQualified: Bool
        /// Whether the cumulative `total_cost_usd` cadence is established for this version.
        let monetaryQualified: Bool

        init(
            contractID: String,
            runtimeVersion: String,
            launchModes: Set<LaunchModeKind>,
            maxQueuedTurnCount: Int = 0,
            requiresQueueDepth: Bool = true,
            compactionQualified: Bool = false,
            monetaryQualified: Bool = true
        ) {
            self.contractID = contractID
            self.runtimeVersion = runtimeVersion
            self.launchModes = launchModes
            self.maxQueuedTurnCount = maxQueuedTurnCount
            self.requiresQueueDepth = requiresQueueDepth
            self.compactionQualified = compactionQualified
            self.monetaryQualified = monetaryQualified
        }
    }

    /// Queue/boundary policy applied to a segment, resolved from its contract identifier.
    struct Policy: Equatable {
        let maxQueuedTurnCount: Int
        let requiresQueueDepth: Bool
        let compactionQualified: Bool

        /// Token-only executions on versions without a recorded contract: serial turns only,
        /// a missing queue depth is tolerated, and a counter boundary is unqualified.
        static let tokensOnly = Policy(maxQueuedTurnCount: 0, requiresQueueDepth: false, compactionQualified: false)
    }

    /// Installed 2.1.268 (paid runs `run-yzza00mc`, `run-wk7k1b7v`, 2026-09-15): dispatch-local
    /// result `usage`, contiguous `result_index`, `queued_turn_count` present, process-cumulative
    /// `total_cost_usd` that continues across repeated `system/init` and across a manual
    /// compaction boundary (zero result tokens, increased cumulative cost). Resumed launches
    /// inherit an unknown cumulative, so their baseline is prospective.
    static let supported2_1_268 = Qualified(
        contractID: "claude-native.provider-reported.v1@2.1.268",
        runtimeVersion: "2.1.268",
        launchModes: [.freshSession, .resumedSession],
        maxQueuedTurnCount: 0,
        requiresQueueDepth: true,
        compactionQualified: true,
        monetaryQualified: true
    )

    /// Versions with established cost/cadence semantics. Add entries only with recorded evidence.
    static let activeContracts: [Qualified] = [supported2_1_268]

    static let tokensOnlyContractPrefix = "claude-native.tokens-only.v1@"

    static func tokensOnlyContractID(runtimeVersion: String) -> String {
        tokensOnlyContractPrefix + runtimeVersion
    }

    static func isTokensOnlyContractID(_ contractID: String) -> Bool {
        contractID.hasPrefix(tokensOnlyContractPrefix)
    }

    #if DEBUG
        /// Deterministic tests inject synthetic contracts here; production never reads it.
        nonisolated(unsafe) static var test_contractsOverride: [Qualified]?
    #endif

    static var contracts: [Qualified] {
        #if DEBUG
            if let override = test_contractsOverride { return override }
        #endif
        return activeContracts
    }

    static func contract(withID contractID: String) -> Qualified? {
        contracts.first { $0.contractID == contractID }
    }

    static func policy(forContractID contractID: String?) -> Policy {
        guard let contractID, let contract = contract(withID: contractID) else { return .tokensOnly }
        return Policy(
            maxQueuedTurnCount: contract.maxQueuedTurnCount,
            requiresQueueDepth: contract.requiresQueueDepth,
            compactionQualified: contract.compactionQualified
        )
    }

    /// Resolves the execution verdict for an actual process launch once the runtime reported its
    /// version. Check order: version present → standard first-party provider path (compatible and
    /// explicitly alternate backends stay excluded) → version-scoped contract for the launch mode
    /// (monetary baseline from the mode) → otherwise token observations only.
    static func verdict(
        for launch: NativeProcessLaunchIdentity,
        runtimeVersion: String
    ) -> AgentUsageExecutionVerdict {
        let version = runtimeVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else {
            return .blocked(.unsupportedRuntime("runtime version unavailable"))
        }
        guard launch.runtimeVariant == .standard, launch.backend == .defaultClaude else {
            return .blocked(.unsupportedLaunchMode("backend \(launch.runtimeVariant.rawValue)"))
        }
        let launchModeKind: LaunchModeKind
        let baseline: AgentUsageSegmentBaseline
        switch launch.launchMode {
        case .freshSession:
            launchModeKind = .freshSession
            baseline = .verifiedZero
        case .resumedSession:
            launchModeKind = .resumedSession
            baseline = .unknown
        }
        let candidates = contracts.filter { $0.runtimeVersion == version }
        guard !candidates.isEmpty else {
            return .qualified(contractID: tokensOnlyContractID(runtimeVersion: version), baseline: .unsupported)
        }
        guard let contract = candidates.first(where: { $0.launchModes.contains(launchModeKind) }) else {
            return .blocked(.unsupportedLaunchMode(launchModeKind.rawValue))
        }
        return .qualified(
            contractID: contract.contractID,
            baseline: contract.monetaryQualified ? baseline : .unsupported
        )
    }

    /// Queue semantics are part of ownership proof: a result whose reported queue depth exceeds
    /// the qualified bound blocks the execution rather than being matched to a guessed dispatch.
    /// A missing depth blocks only where the contract established that it is always reported.
    static func queuePolicyBlock(
        contractID: String?,
        queuedTurnCount: Int?
    ) -> AgentUsageExecutionBlockReason? {
        let policy = policy(forContractID: contractID)
        guard let queuedTurnCount else {
            return policy.requiresQueueDepth ? .unsupportedQueueSemantics("queued_turn_count missing or invalid") : nil
        }
        guard queuedTurnCount <= policy.maxQueuedTurnCount else {
            return .unsupportedQueueSemantics("queued_turn_count \(queuedTurnCount) exceeds qualified bound \(policy.maxQueuedTurnCount)")
        }
        return nil
    }

    /// A same-process counter boundary (compaction) blocks accounting before any affected result
    /// unless the contract established that cumulative cost and result scope survive it.
    static func counterBoundaryBlock(
        contractID: String?,
        kind: String
    ) -> AgentUsageExecutionBlockReason? {
        if policy(forContractID: contractID).compactionQualified {
            return nil
        }
        return .unsupportedCounterBoundary(kind)
    }
}
