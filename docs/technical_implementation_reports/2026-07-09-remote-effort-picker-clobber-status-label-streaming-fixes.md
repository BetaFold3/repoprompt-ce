# Technical Implementation Report - 2026-07-09 - Remote Fixes: Effort-Picker Metadata Clobber, Status-Label Don't-Downgrade, Streaming status_text

## Session Overview

Deep investigation → oracle-planned implementation → oracle review → hardening cycle for three remote-control symptoms (native client on MacBook Pro ↔ gateway ↔ host on Mac Studio, provider codexExec) observed in the first e2e run AFTER the f7de921 fix wave (sessions `9A9F4D93-6194-4F0D-BB55-F12B6DDA1C33` and `0C6109A9-D4CB-4F5F-AF2A-869963E2CA1B`, 2026-07-08 ~21:03–21:07):

- **A (not a bug)**: the first user greeting in a remote-started session produced THREE assistant bubbles on both host and client.
- **B (bug, pre-existing)**: the client's reasoning-effort picker disappeared after the first send and stayed hidden until CLI/model re-selection.
- **C (gap, fix incomplete in f7de921)**: the client showed the fallback "Running on Tuan's Mac" instead of the host's "Thinking…" while a remote run was in progress.

The investigation (report: `docs/investigations/remote-regressions-post-f7de921-triple-bubble-effort-picker-status-label-2026-07-08.md`, local/git-excluded; oracle-authored plan: `docs/investigations/remote-fixes-implementation-plan-2026-07-08.md`, local/git-excluded) ran with three parallel pair investigators plus decisive out-of-band evidence (Codex rollout files, live `rpce-cli-debug` experiments against the running host). Implementation ran as three file-disjoint engineer workers (W-CLIENT, W-HOST, W-GATEWAY) plus a ledger worker, all validated through the lane-serialized conductor daemon; the live CE debug app was never stopped or relaunched.

## Root Causes (established before implementation)

- **A — behavioral, not plumbing.** The Codex rollout for `9A9F4D93…` shows three separate provider-level assistant message items (two back-to-back with NO tool call between them, then `set_status`, then the reply). No transcript component splits or merges anything; host and client render one bubble per provider item. A matched host-local MCP repro (same model config gpt-5.4-mini @ reasoning low, message "Hello", zero remote components) reproduced the multi-bubble shape. Elicitation = universal `set_status` + progress-update prompt guidance × small/low model × content-free greeting. The rollout's `base_instructions` fingerprint proved the session ran the nil-role (top-level) prompt — identical to local. Documented-expected; no code change this wave.
- **B — client selection-identity clobber ⇒ exact-match effort picker starves.** Picker renders iff `remoteCatalog.effortOptions(forModelID: props.selectedModelRaw)` is non-empty (AgentInputBar), matching exact compound IDs (`codexExec:gpt-5.4-mini-low`). On MCP start the host normalizes the model (`CodexModelSpecifier` strips effort suffixes) and echoes plain `agent.model` ("gpt-5.4-mini") in every snapshot; `RemoteAgentModeCoordinator.handle(.metadata)` overwrote `session.selectedModelRaw` unconditionally — first opportunity is the start response itself, hence "disappears on send". Introduced with the structured picker (8e08e44), exposed by the metadata echo (ace9d39); not f7de921. **Coupling (oracle-surfaced):** post-clobber, `modelIDForStart("gpt-5.4-mini")` resolves to nil ⇒ subsequent starts from that tab omitted `model_id` ⇒ host silently applied the `.pair` role default — a functional regression, not cosmetics.
- **C — status label is sampled, not streamed.** f7de921's client consumption (F6) was present and correct, but a runningStatusText-only change never wakes the host's `agent_run wait` (`AgentRunSessionStore` has no change-feed semantics), so the gateway emitted running snapshots only at subscribe/catch-up/start instants plus 30s wait-timeout samples. The affected run lasted ~21s ⇒ zero samples; all early samples raced ahead of Codex's first transport-status write ⇒ nil `status_text` ⇒ fallback for the whole run. Compounding client bug: a later nil-status running frame RESET an already-good label back to the fallback.

## Implementation Details

### B1 — Client: compound remapping of the host metadata echo

**Problem Statement:** The host's normalized `agent.model` echo destroys the client's compound catalog selection, hiding the effort picker and degrading subsequent starts to role-default.

**Solution Approach (oracle-designed, three-layer split):**
- `RemoteTranscriptProjector` parses `agent.reasoning_effort` (trimmed, empty→nil) into `RemoteProjectedSnapshot.agentReasoningEffortRaw`; the `.metadata` event gains `reasoningEffortRaw`.
- New pure resolver `RemoteHostAgentCatalog.resolveCompoundSelection(agentIDRaw:baseModelRaw:effortRaw:)` maps the echo back to the exact `RemoteHostEffortOption.modelID` via structured `base_model_id`/`effort` fields — provider-agnostic (no `CodexModelSpecifier` suffix logic), case-insensitive, requires `supportsStructuredModelGroups`; with absent effort it adopts only a sole/single-nil-effort option (never guesses via `preferredOption`).
- `RemoteAgentModeCoordinator.applyHostModelMetadata` implements the exhaustive decision table: mapped → adopt compound + sync `selectedReasoningEffortRaw` (host truth wins; also lights up the picker for host-default/role starts); unmappable + current selection compound-shaped → no-clobber (keep compound); unmappable + non-compound → legacy fallback (today's behavior + effort adoption). Catalog access goes through an injected `catalogProvider` defaulting to a new `RemoteHostCatalog.cachedNonDegradedCatalog(for:)` — cached-only, never triggers loads, and **never returns degraded placeholders** (degraded ≠ legacy-unstructured; a cold cache on client restart must not reintroduce the clobber). On cache miss the coordinator kicks `loadRemoteHostCatalogIfNeeded` so the next metadata event self-heals.
- Live-host check confirmed the load-bearing assumption: catalog `base_model_id` values ("gpt-5.4-mini", "gpt-5.4-fast") string-equal the host-normalized `agent.model` echo, including service-tier variants.

### C1 — Client: don't-downgrade the running status label

**Problem Statement:** `applyRunState`'s `.running` branch used `statusText ?? fallback` unconditionally, so any nil-status running frame reset a good "Thinking…" label to "Running on <host>…".

**Solution Approach:** coordinator-local `hostProvidedRunningStatusTabIDs: Set<UUID>` — set when a non-empty host `status_text` is applied; while set, nil-status running frames keep the best label seen so far; fallback only before any host label. A flag (not a `runningStatusSource` check) because the client's own placeholders ("Starting on …", "Connected to …") are also `.transport`-sourced — a source-only check would freeze "Starting on …" for entire short runs. Lifecycle: cleared in `applyTerminal`, `.sessionExpired`, `startRemoteSession`, `stop(tabID:)`, and (oracle review) `applyChannel(.revoked)`. The `.connected` "Connected to <host>" stomp is deliberate and documented in-code: channel truth after a gap beats a possibly-stale phase label; the next non-empty `status_text` replaces it.

### C4 — Client: instrumentation

`has_status_text=<bool>` appended to the controller's `remote snapshot projected` os_log line — future e2e captures can confirm from the client alone which running frames carried a label (the f7de921 validation gap).

### C2 — Host + gateway: opt-in streaming of status_text

**Problem Statement:** mid-run `status_text` changes reached the client at best every 30s (gateway wait timeout), typically never for short runs.

**Solution Approach (oracle-redesigned in plan review):** wait-loop *sampling* in `AgentRunMCPToolService` instead of a store-level wake — `AgentRunSessionStore` is untouched. A store-level wake would have needed per-waiter opt-in, reason-aware pendingWake consumption, and a trailing-edge timer (without which Codex's Connecting→Sending→Waiting→Thinking burst would wake on the first label and suppress "Thinking…" until the 30s timeout — worse than today).
- New optional `agent_run wait` arg `include_status_updates` (default false). When true, the wait loop slices `waitUntilInteresting` timeouts to `min(remaining, 2s)` (`statusUpdateSliceSeconds`, DEBUG override for fast tests); on each slice timeout it reads the store snapshot (actor read — no MainActor hop; the store stays fresh because the VM observes `$runningStatusText`) and returns early with `_meta.wait_result = "status_update"` when the normalized non-nil `status_text` differs from the baseline captured once at wait entry. Transitions to nil never trigger. Pure nonisolated helpers `normalizedStatusTextKey` / `shouldReturnStatusUpdate` are unit-tested directly. Multi-session `session_ids` waits got per-racing-task baselines (landed, not descoped). Opted-out path is byte-identical (slice collapses to `remaining`; the `.timedOut` branch short-circuits on the boolean) — CLI/workflow/steer-wait callers see identical timing and payloads.
- Gateway `SessionWatchManager` sets the arg only when the device has **live sinks** (`!state.sinks.isEmpty`, read fresh each wait-loop iteration): a disconnected-but-push-eligible device keeps its 30s wake-push cadence instead of ~2s broadcast-to-nobody churn. The arg is added only when true, keeping old-host payloads byte-identical; `RemoteCommandTranslator` untouched (the arg never crosses the remote wire, so remote clients cannot inject it).
- Cross-version matrix: old host ignores the unknown arg (verified at the wait-handler entry: `execute(args:)` dispatches on `op` only, no allow-list); old gateway never sends it; new client on old host degrades to 30s sampling + C1 best-label. Net effect on current stacks: "Thinking…" reaches the client within ~2s of being set.

**Files Modified:**
- `Sources/RepoPrompt/Features/AgentMode/Runtime/Remote/RemoteTranscriptProjector.swift` — B1 `agentReasoningEffortRaw` parse
- `Sources/RepoPrompt/Features/AgentMode/Runtime/Remote/RemoteAgentSessionController.swift` — B1 `.metadata(reasoningEffortRaw:)`; C4 log field
- `Sources/RepoPrompt/Features/AgentMode/Models/ModelSelection/RemoteHostCatalog.swift` — B1 `RemoteHostCompoundResolution` + `resolveCompoundSelection` + `cachedNonDegradedCatalog`
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/RemoteAgentModeCoordinator.swift` — B1 `catalogProvider` + `applyHostModelMetadata`; C1 flag + lifecycle + `.connected`/degraded-window comments
- `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentRunMCPToolService.swift` — C2 arg parse, slice loop (single + multi), `statusUpdateWaitValue`, pure helpers, DEBUG override, staleness-window comments
- `Sources/RepoPromptGateway/Watch/SessionWatchManager.swift` — C2 sink-gated `include_status_updates` threading
- `Scripts/Fixtures/test-suite-contract-ledger.tsv` — 29 new `retain` rows + 1 in-place contract-text update (T21, assertion flipped to don't-downgrade semantics)
- Tests: `RemoteHostCatalogTests` (+7), `RemoteTranscriptProjectorTests` (+1), `RemoteAgentClientFixesTests` (+10, 1 updated), `RemoteAgentSessionTests` (+1), new `AgentRunWaitStatusUpdateTests` (8), `GatewayWaitLoopContractTests` (+2)

### Technical Decisions

- **Sampling over store-level wake (C2):** dedupe, rate limiting, and trailing-edge "latest wins" for free; zero changes to the actor every MCP client depends on; per-caller opt-in trivially. Accepted, documented staleness window: a change landing between one wait's return and the next wait's baseline capture surfaces at the next change or the 30s cap.
- **Shape-based no-clobber over tuple equality (B1):** the tuple cannot be verified exactly when the catalog is unavailable — which is precisely when the guard matters; "never replace a compound-shaped selection with a plain model" is the only sound rule. Accepted residual: a stale catalog can keep a client compound the host isn't running; the alternative reintroduces B.
- **Degraded ≠ legacy (B1):** the coordinator's catalog provider intentionally bypasses `remoteHostCatalogSnapshot(for:)` (which fabricates `.degraded` on cache miss); a cached degraded entry yields the no-clobber path, not the legacy-adopt path. While a degraded entry sits in cache (20s TTL) `loadRemoteHostCatalogIfNeeded` is a no-op — behavior in that window is the safe no-clobber path (documented in-code).
- **Flag over source-check (C1):** preserves today's placeholder churn exactly; protects only genuinely host-provided text.
- **Sink-gating at the gateway (C2):** the plan's original scope missed that push-eligible sinkless devices keep wait loops; unconditional opt-in would have been a battery/network regression.

## Bug Fixes

**Oracle review P2 — stale ledger contract for the flipped T21 test (caught before commit):**
- **Symptoms**: `testT21CoordinatorUsesStatusTextOnlyForRunningState`'s assertion changed (nil status_text now expects the host label to persist) but its ledger row still described the old "absent → fallback" contract.
- **Root Cause**: `verify-ledger` checks IDs, not descriptions — exactly the drift the ledger exists to prevent.
- **Fix Applied**: row's oracle/failure/notes text updated to don't-downgrade semantics with the old→new assertion mapping recorded.

**Oracle review P2 — load-bearing accessor untested:**
- `cachedNonDegradedCatalog` (the deviation that makes B1 restart-safe) had no test; added `testCachedNonDegradedCatalogReturnsNilForCachedDegradedEntry` (degraded cached → nil; healthy after TTL → returned) + its ledger row.

## Challenges Encountered

- **Make wrapper vs regex filters**: `make dev-test FILTER='A|B'` expanded `|` as shell pipes; workers switched to the equivalent `./conductor test --filter 'A|B'` (same daemon lane).
- **Concurrent-worker compile noise**: one W-HOST build retry hit a transient compile error in a W-CLIENT test file mid-edit; resolved by the briefed wait-and-retry protocol, no cross-scope edits.
- **Fixture gap for the B1 assumption**: the checked-in `agent_manage_list_agents_response.json` fixture predates structured `base_model_id` fields, so the resolver assumption was confirmed against the live host instead (and unresolvable shapes fall into the safe no-clobber path by design).

## Testing

- 29 new tests; combined focused run (`RemoteHostCatalogTests|RemoteTranscriptProjectorTests|RemoteAgentClientFixesTests|RemoteAgentSessionTests|RemoteAgentSessionControllerSettleTests|AgentRunWaitStatusUpdateTests|AgentRunMCPToolServiceWaitTests|GatewayWaitLoopContractTests`) green: **139 tests, 0 failures**; post-review touch-up rerun of the four affected suites: **65 tests, 0 failures**.
- Regression locks: `testWaitWithoutOptInBlocksThroughStatusTextChange` (old-gateway byte-identity), `testMetadataEchoLegacyCatalogAdoptsPlainModelWhenSelectionNotCompound` (legacy hosts), `testModelIDForStartRemainsResolvableAfterMetadataEcho` (B→A coupling), `testWaitPartitionOmitsStatusUpdatesForSinklessPushEligibleDevice` (last-call assertion).
- SwiftFormat: 0 changes; SwiftLint strict: 0 violations in 1506 files; `RepoPrompt` product builds via the coordinated daemon.
- Ledger: `verify-ledger` returns exactly the pre-existing baseline drift (missing=195 stale=3); all 29 new IDs present.

## Oracle Review

Plan-mode pre-review materially reshaped the design: C2 moved from store-level wake to wait-loop sampling (dropping `AgentRunSessionStore` from scope entirely), B1 got the shape-based no-clobber rule and the degraded-cache trap, and the gateway sink-gating requirement was added. Post-implementation review of the full diff: **no P0, no P1, 6 P2** — all applied (T21 ledger text; accessor pin test + degraded-window comment; staleness-window comments at both baseline captures; DEBUG-override serial-XCTest comment; gateway sinkless test strengthened from contains-based to last-call; `.revoked` clears the host-label flag). Verdict: "solid to hand back".

## Next Steps

### Immediate TODOs
- Live e2e re-validation (MacBook Pro ↔ Mac Studio) after rebuilding both sides: effort picker survives first send and a client restart against a live session; client shows "Thinking…" within ~2s mid-run; label survives nil-status frames; `has_status_text` visible in client captures; post-send starts carry an explicit `model_id` (no more silent `.pair`-role drift).
- Symptom A follow-ups remain product-level options (prompt tuning for silent `set_status`; UI grouping of consecutive assistant bubbles) — deliberately not in this wave.
- Refresh the `RemoteHostCatalog` fixture with structured `base_model_id`/`effort` fields so the resolver assumption is pinned by a checked-in fixture, not a live-host check.

### Technical Debt Introduced
- C2 staleness windows (inter-wait baseline capture; losing session in a multi-wait) are accepted and documented in-code; a change surfaces at the next change or the 30s cap.
- `statusUpdateSliceSecondsOverride` is a process-global DEBUG seam safe under serial XCTest only (documented).
- B1 keeps a client compound the host may not be running when the catalog is stale/outside-catalog (documented at the no-clobber site).

## Session Metrics
- **Files Changed**: 15 (6 source + 6 test files (1 new) + ledger + TIR + 2 local git-excluded investigation/plan docs)
- **Lines Modified**: ~+1,530 / −35 (incl. ~1,150 lines of new tests)
- **Components Affected**: remote client runtime (projector/controller/coordinator), remote model catalog, MCP agent_run wait service, gateway session watch loop, contract ledger
- **Delegated workers**: 3 pair investigators + 3 engineer workers + 1 ledger worker + oracle chat (adversarial investigation review → plan → post-review); all builds/tests via the lane-serialized conductor daemon; live app untouched

## Lessons Learned
- When a fix consumes a wire field, validate against the frames the transport actually *emits* in the target scenario, not just request/response payloads — f7de921's F6 was correct code that never received data mid-run; the `has_status_text` log field makes this checkable from client captures alone.
- Live experiments against the running system (1s `agent_run poll` loop, matched-config MCP repro) settled in minutes what code reading could not: host-side serialization worked, and the "remote-only" triple-bubble reproduced locally.
- An event-driven design isn't automatically better than sampling: the store-level wake looked cleaner but was strictly worse (wake storms, trailing-edge suppression, per-waiter plumbing in a shared actor). The rate limiter the event design needed imposed the same latency bound sampling gets for free.
- Cosmetic bugs can have functional shadows: the effort-picker clobber silently changed the prompt *role* of every subsequent start from that tab.

> Generated from Claude Code session on 2026-07-09
