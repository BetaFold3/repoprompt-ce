# Claude Oracle shim authentication and Knowledge research workers plan

Scope: read when the task touches how Claude-backed Oracle (`ClaudeCodeProvider`) launches the configured Claude CLI executable or shim, Oracle print-mode output parsing, retry, and cancellation, or letting a Knowledge-profile session start RepoPrompt research workers through `agent_run`.
Authority: Reference
Last-verified: 2026-10-03

Status: user-approved implementation and ROUND 2 scoped remediation are complete; both verified Oracle lanes approve the code, with KW-01/KW-02/KW-03/OR-01 CLOSED. Focused validation passed 298 tests with zero failures across 18 suites, plus lint and format-check. Final executable-list reconciliation and guardrails are complete; the ledger retains only the known baseline Pair-guidance omission (missing 1, stale 0), with no task omissions. Mandatory live §3/§4 acceptance remains unrun and unwaived; full-root validation is unrun. This plan remains active and must not move to completed while mandatory live acceptance is outstanding. Final staging and commit-preflight results are recorded in the session completion summary; no commit was requested.

## Implementation status and acceptance evidence (2026-10-03)

- **Authorization and implementation:** the repository owner approved both workstreams. Both original reviews and both ROUND 1/ROUND 2 re-reviews completed; the parent verified both exact ROUND 2 preset identities. Existing Pair workers completed source/test remediation. The explicit ROUND 2 Oracle verdicts below close KW-02/KW-03; KW-01/OR-01 were closed in ROUND 1. Code approval and green focused validation do not satisfy mandatory live acceptance.
- **Oracle test inventory:** the pre-remediation surgical ledger additions cover 17 methods in `ClaudeCodeProviderPrintModeTests` and three in `MCPAskOracleClaudeShimIntegrationTests` (71 distinct scenarios). Five additional remediation methods now have surgical ledger rows (17 scenarios): bounded/redacted transient and unclassified errors, stdout refusals without fallback, non-refusal stdout fallback, configured-executable refusal context, and safe empty-output diagnostics. The final focused-test result and completed Oracle re-reviews are recorded below; ledger runtime estimates are unmeasured.
- **Knowledge test inventory:** the pre-remediation ledger adds 20 rows (179 distinct scenarios) across policy, prompts, descriptions, provider policy, service boundaries, and retained sockets; existing ceiling, policy-constant, and Claude native-tool rows were also reconciled. Remediation adds seven rows (32 scenarios) for frozen caller identity/profile continuity, caller-partitioned request IDs, authorization before replay, standard/external replay compatibility, and placeholder/expected-profile policy. The existing unsupported-start-arguments row expands from 11 to 12 scenarios with `session_id` rejection. Separate Pair-guidance coverage remains outside this task's ledger ownership. Two ROUND 2 service methods now have surgical integration-tier ledger rows: `testKnowledgeRequestIDReplayRevalidatesTheCallerAfterTheRegistryLookup` (7 scenarios) and `testStandardRespondRevalidatesTheFrozenCallerAtDispatch` (4 scenarios). Counts describe current assertions; the replay method does not currently assert a recorded-failure payload.
- **Metadata/document checks (earlier evidence):** read-only Python checks using `Scripts/test_suite_optimizer.py`'s `read_ledger_rows` passed for schema, row widths, duplicate IDs, execution tiers, and owned-row identity/metadata/disposition/scenario totals. The final pre-remediation readback preserved all 6,353 pre-existing rows, including 19 `AgentToolResultPersistencePolicyTests` rows. These were metadata/structure checks, not runtime validation or code review. Current metadata-only readback passed for the seven new Knowledge rows and the updated argument row, preserving all 6,365 untargeted existing rows and the baseline Pair-guidance omission. No executable list or full ledger verification was run by this support pass.
- **Deterministic validation (pre-remediation, parent-reported):** combined 16-suite `make dev-test` passed 269 tests with zero failures (conductor `63abb9c8-daec-4aa6-ad82-dc28b2209462`) for snapshot `0966e2e59761248f0cc24c77f5fdf563f1db0b27`. That result does not validate subsequent remediation. Earlier `make dev-lint` passed (`7845a8d7`), `make dev-format-check` passed (`a831093a`), and `make guardrails` passed; `Scripts/check-agent-context` passed with the existing route-count warning and its negative checker passed 23 checks. The final post-remediation focused result is recorded separately below. The focused run is not full-root or live-acceptance evidence.
- **ROUND 1 remediation validation (parent-reported):** combined 18-suite `make dev-test` **PASSED: 296 tests, zero failures** (conductor `e3153e0b-aad4-453e-afc8-26b10afc3f54`). `make dev-lint` passed (`eca3addb-d3a4-41c4-b584-95e3967d9b5e`); `make dev-format-check` passed (`214b5fcf-41e7-43b5-bf96-66482ec821c1`); `make guardrails` and `Scripts/check-agent-context` passed with the existing route-count warning (16 direct routes > 15), and the negative checker passed 23 checks. No full-root run or live evidence was provided. Green focused tests do not close Oracle findings or satisfy mandatory live acceptance. This evidence precedes the newly scoped KW-02/KW-03 remediation; it does not validate that later delta.
- **Corrections before the final green run (parent-reported):** two earlier test failures were corrected: the general start guard already rejects `session_id`, so the dead Knowledge-only clause was removed; redundant window resolution during external Knowledge admission was removed. Existing idempotency assertions were unchanged. These are reported remediation details, not an independent code review or finding closure.
- **Final executable/ledger reconciliation (parent-reported):** `make dev-test-list` passed (`be8d1603-0745-4a8c-999f-9397f23a0a18`), and `verify-ledger`'s root/provider/core list steps passed. Final reconciliation is **DONE**, reporting **missing 1, stale 0**: only the known baseline omission `root/RepoPromptTests.AgentDelegationPolicyTests/testPairReviewRemediationGuidanceMatchesDelegationAudienceAcrossProviders`. No task rows are missing. This baseline omission is not attributed to the implementation and remains outside this task's ledger ownership; full `verify-ledger` is not green. The earlier list run (`870b57d3-0bb6-48fd-b6e5-80686e2e9b12`) had the same baseline gap.
- **Original OracleA review:** local export identifier `oracle-review-2026-10-03-115802-oraclea-shim-and-kno-2659.md` (untracked working evidence). Original code verdict: **Request changes**, with P1 **KW-01** (frozen caller continuity), **KW-02** (idempotent replay authorization), and **OR-01** (stdout refusal fallback). Dispositions are supplied by the verified ROUND 1 and ROUND 2 verdicts below; original severities are not reinterpreted.
- **Original OracleB review:** local export identifier `oracle-review-2026-10-03-120248-oracleb-shim-and-kno-6b2d.md` (untracked working evidence). Code verdict: **Approve with non-blocking findings**; no P0/P1 reported. P2 findings are **R-01** (stdout refusal fallback), **R-02** (unredacted failure previews), and **R-03** (unhydrated/mutable caller-profile handling). Listed P3 findings are **R-04** (leaf prompt wording), **R-05** (loose retry-classifier markers), **R-06** (start `session_id` wording/enforcement), **R-07** (inherited-model catalog validation), **R-08** (extra admission awaits), **R-09** (standard respond revalidation tightening), **R-10** (stale status text), and **R-11** (compatible-backend error-mapping inconsistency). OracleB's original acceptance verdict remains not accepted pending mandatory live evidence. These are the original lane's severities, not a downgrade of OracleA's P1 findings.
- **Verified OracleA re-review ROUND 1:** local export identifier `oracle-review-2026-10-03-124045-oraclea-remediation-6e70.md` (untracked working evidence). **CLOSE KW-01** and **CLOSE OR-01**. That round **KEPT OPEN P1 KW-02** (caller/target authorization could change during the registry lookup before duplicate success/failure disclosure) and added **P1 KW-03** (removing the standard `respond` dispatch fence allowed resolution after authority changed during metadata capture). Its code verdict was **Request changes**. Both remaining findings are now explicitly CLOSED by ROUND 2 below; the historical severities are unchanged. Acceptance was independently blocked by missing mandatory live evidence.
- **Verified OracleB re-review ROUND 1:** local export identifier `oracle-review-2026-10-03-124352-oracleb-remediation-d3c6.md` (untracked working evidence). **CLOSE R-01/R-02/R-03** and **CLOSE R-06/R-09**; code verdict: **Approve**, with no P0/P1 reported by that lane. Remaining R-04/R-05/R-07/R-08/R-10/R-11 stayed open by election at that round; status bookkeeping is now updated, without claiming a separate Oracle closure of R-10. New **N-01…N-07 were P3 informational, with no further loop requested**: credit-balance copy, diagnostic truncation/opaque-run redaction, narrow standard admission tightening, eligibility-path consistency, standalone target-profile hardening, pre-lookup failures not recorded, and documentation bullet nesting. Its approval did not close OracleA's then-outstanding findings. The ROUND 1 R-09 standard-fence removal is superseded by ROUND 2's accepted restoration and explicit withdrawal of the objection.
- **Accepted historical-standard hardening differences:** both review lanes accept two deliberate narrow differences from pre-task HEAD, not an owner waiver of the plan or live acceptance. **Respond dispatch fence:** original HEAD `4bcc2f8a` checked standard `respond` at admission only; the initially reviewed implementation added unconditional dispatch revalidation; ROUND 1 removed the standard fence; ROUND 2 restores unconditional stale-caller revalidation with an optional expected Knowledge profile. Revoked caller identity, eligibility, or target-depth authority across the metadata await is rejected. **N-03 unhydrated profile:** an unhydrated routed standard caller without an owner-validated durable profile fails closed instead of inheriting the placeholder's default standard/depth-zero authority; the shared helper also covers `agent_manage` create/resume/fork and `agent_explore` start. **Standard delegation permissions and tool surface remain unchanged** for stable, eligible standard callers; stable external permissions remain unchanged. ROUND 1's R-09 removal is superseded; OracleB withdraws the objection under this permissions/surface interpretation.
- **Final ROUND 2 validation (parent-reported):** combined 18-suite source validation **PASSED: 298 tests, zero failures** (conductor `81ed54a6-56f6-483b-8c22-03306986e405`). `make dev-lint` passed (`86d51e89-398b-431f-8039-104cc5465bcf`); `make dev-format-check` passed (`4f3817e5-0d95-4258-b3d6-707a02010c36`). Final guardrails and `Scripts/check-agent-context` passed with the existing route-count warning (16 direct routes > 15); the negative checker passed 23 checks; `git diff --check` passed. Final list/ledger reconciliation is recorded above. This is focused source validation, not full-root or live evidence; review lanes relied on reported validation rather than independently rerunning it.

- **ROUND 2 test scope and nonblocking limitations:** `testKnowledgeRequestIDReplayRevalidatesTheCallerAfterTheRegistryLookup` covers seven scenarios; its mutation seam runs after lookup, not through a gated suspension inside the registry. It lacks an explicit recorded-failure payload case: both duplicate payload types share the revalidation branch, which is not separate failure-payload test evidence. `testStandardRespondRevalidatesTheFrozenCallerAtDispatch` covers four scenarios; stable standard/external cases negatively assert no delegation denial while tolerating broader errors, rather than asserting a specific resolution outcome. OracleA and OracleB regard these limitations as nonblocking, not surviving P1s. OracleB also notes that the nil-profile helper behavior is inferred from prior rounds and reported tests, not visible in its ROUND 2 delta. Counts and claims remain limited to current assertions.
- **Verified OracleA re-review ROUND 2:** local export identifier `oracle-review-2026-10-03-125422-oraclea-remediation-9f7d.md` (untracked working evidence). Code verdict: **Scoped remediation approved**. **CLOSE KW-02** (post-registry-await replay/disclosure authorization) and **CLOSE KW-03** (unconditional `respond` dispatch revalidation); no blocking fix-induced regression is established and no contract-dispute stop is triggered. KW-01/OR-01 remain previously closed. Acceptance verdict: **Blocked by missing mandatory live evidence**; full-root was unrun and final guardrail/list reconciliation was pending at review time. Subsequent completed reconciliation is recorded above, without treating it as live evidence.
- **Verified OracleB re-review ROUND 2:** local export identifier `oracle-review-2026-10-03-125858-oracleb-remediation-8745.md` (untracked working evidence). Code verdict: **Approve**; **CLOSE KW-02/KW-03**, no surviving P0/P1 or fix-induced regression reported. **Withdraw R-09 objection** under the standard-permissions/tool-surface interpretation, accepting the historical hardening differences recorded above. Acceptance verdict: **Still not accepted**, citing mandatory live §3/§4 and then-pending full-root/ledger reconciliation. Final ledger reconciliation is now complete with the known baseline gap; full-root remains unrun and live remains unrun/unwaived. The review's evidence caveat remains: supplied delta/static review and relayed validation, not an independent runtime check.
- **ROUND 2 minor findings and bookkeeping:** OracleB adds **N-08/N-09/N-10 P3 informational**, plus carried **N-07**: broad negative standard/external assertions; no explicit recorded-failure replay test; replacement-induced `.new` failures can be recorded under the frozen caller namespace and later replayed if that identity returns; existing doc bullet nesting. These and the test limitations above do not require another code loop. Earlier elected P3 follow-ups are not remediated here. KW-02/KW-03's two service ledger rows cover 11 scenarios; metadata readback preserved all 6,373 pre-existing rows and the baseline Pair-guidance omission. Source/tests and the Pair-controlled owning delegation document are untouched by this bookkeeping. Final staging and commit-preflight results are recorded in the session completion summary. This documentation bookkeeping performed no independent code review or new remediation loop.
- **Mandatory Oracle live acceptance (§3):** pending, not waived. No live acceptance was performed; the owner prerequisite question timed out. Evidence must show managed-tap success with the default login unavailable, a fail-closed refusal with no retry or unmanaged fallback when managed accounts are ineligible, and unchanged Agent Mode behavior.
- **Mandatory Knowledge live acceptance (§4):** pending, not waived, for both Claude and Codex roots. No live acceptance was performed; the owner prerequisite question timed out. Evidence must show two fresh Knowledge workers with real web calls and saved Knowledge profiles, no native Agent/Task delegation, worker delegation refusal, URL-citing synthesis, and unchanged standard delegation.

The original plan body below is preserved as the pre-implementation baseline, design, and acceptance requirements; current status and acceptance evidence are recorded above.

Decision process:
- Two Oracle lanes, OracleE and OracleD, received an identical brief. Its file:line evidence had been checked against the live checkout and the owner's installed `claude-rotator` shim.
- They differed on four material points (§6). One anonymous challenge round settled all four, so no second round was needed. The plan author settled the minor differences after checking the code (§7).
- OracleE's first two round-one replies failed with `oracle_failed` and no further detail. Its third attempt, in a fresh chat with its earlier positions restated, succeeded. The returned preset identities were checked: OracleE is `95F2BD07…` and OracleD is `7F177418…`.

## 1. Outcome and scope

Two independent workstreams:

1. **Oracle authenticates through the shim.** The Claude CLI executable configured in CLI Providers (`cliExecutableOverride.claude`, for example `~/.claude-rotator/shim/bin/claude`) must be the single authentication authority for both Agent Mode and Claude-backed Oracle. No separate default `claude` login may be needed.
2. **Knowledge research workers, one level only.** A Knowledge main agent can start RepoPrompt workers that research on the web, then collect and combine their findings. Workers are leaves: they cannot start sub-workers.

Non-goals:
- Knowledge sub-workers (depth 2). The owner deferred these.
- Web access for Oracle consultations. Oracle keeps blocking `WebSearch`/`WebFetch`.
- Any change to the shim. RepoPrompt does not create rotator session bindings or read rotator tokens.
- Exposing `agent_manage` or `agent_explore` to Knowledge sessions.
- Changing the standard-profile delegation contract.

## 2. Verified baseline (2026-10-03)

**Oracle launch**
- Oracle builds a fresh `ClaudeCodeProvider` for each request (`AIQueriesService.swift:330`, `DisposableProviderPool.swift:24-25`, `AIProviderFactory.swift:81-82`).
- The provider reads the configured executable (`ClaudeCodeProvider.swift:103-106`). The runner launches that exact path, with no lookup on PATH and no fallback (`CLIProcessRunner.swift:259-271`).
- Oracle runs `-p` with the prompt on stdin (`ClaudeCodeProvider.swift:34`, `:170-174`) and `outputMode: .auto(.json)`. The runner rewrites or appends `--output-format json` (`CLIProcessRunner.swift:280-289`). `CLIOutputFormat.streamJson` already exists (`CLIOutputFormat.swift:6`).
- `CLIProcessRunner.run` buffers the full stdout with no tail cap. `captureStdoutTailBytes` limits only `runStreaming` and log tails.
- Oracle blocks native tools, including `Task`, `WebFetch`, and `WebSearch` (`ClaudeCodeProvider.swift:57-87`). It does not block `Agent`.

**Oracle retry and cancellation**
- `shouldRetry` retries any exit code 1, plus matches on 429, overload, 5xx, timeout, and network text (`ClaudeCodeProvider.swift:292-303`).
- An error parsed from stdout by `extractCLIErrorDetail` is thrown before the retry check.
- `mapProcessFailure` tells the user to run `claude login` on any authentication-like stderr (`:314-315`).
- `completeMessage` does not pass `cancelChildOnTaskCancellation`. Its backoff sleep is `try?`, which swallows cancellation.

**Agent Mode launch:** `-p --verbose --output-format stream-json --input-format stream-json` (`ClaudeNativeProcessSessionController.swift:3193-3197`).

**How the installed shim classifies a call** (`~/.claude-rotator/shim/bin/claude`; outside the repository):
- `-p` with `--output-format stream-json` and no session ID is `managed-tap`. That means account selection for new work across the vault, failing closed if no account is eligible (lines 602 and 634-640, and 3735-3790). The child process gets `CLAUDE_CODE_OAUTH_TOKEN` and `CLAUDE_CONFIG_DIR` (lines 3870-3875).
- Any other `-p` call is `passthrough` with reason `plain-print`, meaning the real `claude` runs with the default login (lines 660-662 and 3533-3536).
- `--session-id` or `--resume <id>` works only for a session that already has an account binding or exactly one matching transcript. A fresh UUID fails closed (lines 3581-3597).
- Live account switching needs `--input-format stream-json` with failover enabled, and happens only at qualifying continuation points (lines 1047-1060 and 3884-3886).
- `fail()` writes to stderr and exits with status 1 (lines 97-100).

**Knowledge delegation**
- A Knowledge session cannot delegate today:
  - The positive tool ceiling `KnowledgeSessionPolicy.allowedMCPToolNames` lists only `get_file_tree`, `file_search`, `read_file`, `apply_edits`, `oracle_utils`, `ask_oracle`, and `oracle_chat_log` (`AgentSessionProfile.swift:16-24`).
  - `MCPConnectionManager` forces that ceiling for `.knowledge` (`:7622-7624`), hides other tools from the tool list (`:10011-10015`), and refuses calls to them (`:546`).
  - The Knowledge prompt forbids delegation (`AgentModePrompts.swift:248`).
  - `SystemPromptService.agentModePrompt` returns the Knowledge prompt before looking at `delegationAudience` (`SystemPromptService.swift:827-829`).
- An owner test that seemed to show Knowledge delegation actually ran in a standard session:
  - Session `D4B05D54…` is saved with `profile: "standard"` and provider `codexExec`.
  - Its two standard Codex workers each made one native `search` call.
  - Knowledge sessions do save `profile: "knowledge"`: nine such saved sessions exist.
- New MCP children are blank standard tabs (`AgentModeViewModel.swift:7973-7985`). A session's profile can change only while its tab is still an untouched placeholder (`AgentModeViewModel+TabSession.swift:245-264`).
- Under the general delegation contract, depth-0 and depth-1 non-explore sessions may delegate (`AgentDelegationPolicy.swift`). Depth-0 callers keep existing session-addressed access, and only workers are restricted to deeper targets ([bounded MCP delegation](../agent-mcp-delegation-depth.md)).
- `agent_run` operations are exactly `start`, `poll`, `wait`, `cancel`, `steer`, and `respond` (`AgentRunMCPToolService.swift:425-438`).
- `AgentSessionMetadataIndex` saves each session's profile (`AgentSessionMetadataIndex.swift:171-173`).

**Web access**
- Claude Knowledge keeps `WebSearch` and `WebFetch` (`ClaudeCodeIntegrationConfiguration.swift:72-100`).
- Claude has no RepoPrompt-side web toggle: `ClaudeAgentToolPreferences` has no web setting.
- Codex follows `CodexAgentToolPreferences.searchToolEnabled`, which is global, defaults to true, and becomes `web_search="live"` (`CodexAgentToolPreferences.swift:346-351`, `CodexNativeSessionController.swift:8100`, `CodexOverrides.swift:213-215`).
- Codex native multi-agent is off in every Codex policy (`CodexNativeSessionController.swift:8076`, `CodexCLIProvider.swift:822`, `CodexExecAgentProvider.swift:62`).
- The Claude Knowledge block list includes `Task` but not `Agent`. RepoPrompt itself treats `Agent` as the native child tool, with `Task` as an alias (`ClaudeNativeProcessSessionController.swift:2996-3006`).
- The Codex settings text says the web-search toggle searches "the project" (`AgentProviderPermissionControlsComponents.swift:226`).

## 3. Workstream 1: Claude Oracle through the shim

### Design
- All three print-mode launches in `ClaudeCodeProvider` must use the same arguments: `completeMessage`, `testConnectionWithModel` (`:561`), and `testCompatibleBackendConnection` (`:470`). Otherwise "Test connection" would check a different authentication path from the one Oracle uses.
  - Arguments: `-p --verbose --output-format stream-json`, with the prompt on stdin as plain text.
  - The CLI rejects `stream-json` in print mode without `--verbose`.
- Never pass `--session-id`, `--resume`, `-r`, `-c`, `--fork-session`, `--bare`, or `--input-format stream-json`. Each of these sends the call down a different shim branch.
- Use `outputMode: .auto(.streamJson)`. With that mode, the runner's existing `--output-format` rewrite produces the correct flag.
- Keep the configured-executable gate, prompt delivery, backend environment resolution, the empty-MCP lease, and Oracle's native-tool block list as they are. Add `Agent` next to `Task` in Oracle's block list.

### Parsing
- Split the fully buffered stdout into lines (CRLF-tolerant) and parse each non-empty line with `JSONSerialization`. Skip lines that don't parse.
- Take the last object with `type == "result"`. Decode it through `ClaudeResultMessage` first, with `parseCompletionDictionary` as the fallback. Keep the existing cache-inclusive token accounting, and never add up intermediate usage.
- Keep single-object and array JSON parsing so older test fixtures still pass.
- A result with `is_error == true` or an error subtype becomes `AIProviderError.invalidConfiguration` carrying the result text. Output with no result object becomes `invalidResponse("stream-json output contained no result message")`.
- `extractCLIErrorDetail` uses the same line splitter and returns the `result`, `error`, or `message` text from the last object that has one. Its plain-text fallback is unchanged.

### Retry, cancellation, and error copy
- Remove the blanket `exitCode == 1` retry. Retry only on timeout and on positively matched transient failures (429/rate limit, overload, 5xx/gateway, network or connection reset). Explicit authentication or admission refusals take precedence over substring matches and are surfaced immediately. That includes the shim failing closed, which prints to stderr and exits 1.
- Errors parsed from stdout keep throwing immediately (current behavior).
- Pass `cancelChildOnTaskCancellation: true` on every launch. Make the backoff sleep propagate cancellation, and call `Task.checkCancellation()` before each new attempt. A cancelled request then kills its child process and never starts another attempt.
- Record whether the executable came from an override (`commandSelection`). When it did, the authentication branch of `mapProcessFailure` names the configured executable and shows a short stderr excerpt instead of suggesting `claude login`. Never print prompts or credentials.

### Steps
1. Add a shared launch helper in `ClaudeCodeProvider.swift` that sets `verbose`, the output mode, and cancellation. Switch all three launches to it.
2. Add the line-based parser and error extraction.
3. Change retry classification, cancellation, and the override-aware error text.
4. Add `Agent` to Oracle's `disallowedTools`.

### Tests
- **Unit:** for each of the three launches, check that the argument list contains `-p`, `--verbose`, and `--output-format stream-json`, and none of the session or input flags. Parser cases:
  - a result as the last line;
  - `is_error`;
  - no result;
  - an unparseable leading line;
  - a large result (over 128 KiB);
  - CRLF line endings;
  - legacy single-object JSON.

  Also cover retry classification (shim refusal is not retried; 429 is retried), cancellation (no further attempt; child terminated), and the override-aware authentication message.
- **Integration:** a recording fake executable configured as the override. It prints canned stream-json and checks exactly what argv it received. Run it through `ask_oracle`, including the error and cancellation paths.
- **Live acceptance:**
  - Configure the shim. Make the default `~/.claude` login unavailable. An Oracle send succeeds, the shim log shows `managed-tap`, and stderr does not contain "plain -p launch is not managed".
  - Make every managed account ineligible. The shim's error is surfaced with no retry and no fallback to an unmanaged launch.
  - Agent Mode is unchanged.

## 4. Workstream 2: Knowledge research workers

### Invariants
- **K1. One level.** A Knowledge session may delegate only at a verified depth of 0. A Knowledge session at depth 1 or deeper is a leaf, which is stricter than the general depth-1 rule. Unknown, cyclic, or inconsistent lineage fails closed, as it does today.
- **K2. Tool surface.** A Knowledge root gets `agent_run` with all six operations, checked against an explicit per-operation allowlist so that a future operation cannot appear by default. Knowledge sessions never get `agent_manage` or `agent_explore`. Workers get none of the three delegation tools.
- **K3. Fresh Knowledge children only.**
  - A start routed from Knowledge always creates a new tab.
  - It rejects `tab_id` or other existing-session selectors, explicit worktree arguments, workflows, and role-label `model_id`s.
  - The child adopts `.knowledge` through `adoptSessionProfile` before its identity is bound, its parent is recorded, its lease is prepared, or its provider starts. If adoption or the commit check fails, the created tab is discarded.
- **K4. Provider and model.**
  - If `model_id` is omitted, the child inherits a frozen snapshot of the admitted parent's live provider, model, and effort. If that snapshot can't be read, the call fails closed and never falls back to the window default.
  - Explicit models must resolve to `KnowledgeSessionPolicy.supportedProviders` (Claude Code or Codex).
  - The start receipt reports the resolved provider and model.
- **K5. Web gate, local and known only.** If the resolved provider is Codex and `CodexAgentToolPreferences.searchToolEnabled == false`, reject before creating the tab and name the settings toggle. Claude is not gated because no RepoPrompt toggle exists. Never probe remote availability. WebFetch policy stays independent.
- **K6. Only the parent's own direct children can be targeted.**
  - Every session-addressed `agent_run` call from a Knowledge caller must target a session whose reconciled parent (`mcpDelegationParentLookup`) equals the caller's frozen identity, and whose profile is `.knowledge`. The profile comes from the live record or the owner-validated metadata index. This covers `steer`, `cancel`, `respond`, and `wait`/`poll` calls that name `session_id`/`session_ids`.
  - Anything else fails closed: standard sessions, siblings, roots, unknown profiles.
  - The check runs before the existing depth-0 early return in `mcpValidateDelegationTarget`, and again at every mutation or dispatch boundary (`mcpRevalidateDelegationCommit`, `mcpAdmitDelegationControl`).
- **K7. No native delegation.** Add `Agent` next to `Task` in `ClaudeCodeIntegrationConfiguration.knowledgeDisallowedTools`. Codex native multi-agent is already off; keep it off and cover that with a test.

### Steps
1. **`AgentSessionProfile.swift`:** add `agent_run` to `KnowledgeSessionPolicy.allowedMCPToolNames`, plus the per-operation allowlist. Leaf restrictions still remove `agent_run` for workers. Restrictions are checked before the ceiling, both when tools are listed and when they run.
2. **`AgentDelegationPolicy.swift`:**
   - Add a defaulted `sessionProfile` input to `decision` and `runToolPolicy`.
   - Add `Decision.knowledgeLeaf(depth:)`, checked before the general depth test, with the denial message "Knowledge research workers cannot start or control other agents."
   - An eligible Knowledge root gets `allowsAgentExternalControlTools: true`, `additionalRestrictedTools: delegationToolNames − {agent_run}`, and `promptAudience: .agentRunOnly`.
3. **`AgentModeViewModel.swift`:**
   - Pass `session.profile` through `mcpDelegationDecision`/`mcpDelegationRunToolPolicy`.
   - Add the K6 target check to `mcpValidateDelegationTarget`, `mcpRevalidateDelegationCommit`, and `mcpAdmitDelegationControl`.
   - Add a defaulted `childSessionProfile` to `mcpResolveOrCreateSessionTarget`. Adopt it in the newly created tab branch before `ensureSessionBoundToTab`. Reject it in the explicit-tab and session branches.
4. **`AgentRunMCPToolService.swift`:**
   - Look up the Knowledge source profile.
   - Enforce K2's per-operation allowlist, K3's argument rejections, K4's model inheritance and validation, and K5's gate before any target is created.
   - Pass `childSessionProfile: .knowledge`.
   - Apply K6 to `wait`/`poll` session arguments.
5. **`MCPConnectionManager.swift` and `AgentModeMCPToolPolicy.swift`:** keep the forced Knowledge ceiling, now including `agent_run`. Add a Knowledge-specific `agent_run` description that lists only the allowed behavior.
6. **Prompts:**
   - `AgentModePrompts.knowledgePrompt(agentKind:delegationAudience:)`, with `SystemPromptService.agentModePrompt` passing the audience through.
   - The root text (`.agentRunOnly`) replaces the "agent-delegation" prohibition. It says the agent may start parallel Knowledge research workers with `agent_run` (detach, then wait), each with an independent question or perspective. Omitting `model_id` uses this session's provider and model. Workers return findings with URLs or paths and their uncertainties, and the parent combines them and owns any artifacts. Workers cannot delegate.
   - The worker text (`.none`, depth 1) says it is a research worker, returns findings in its final message, and cannot start agents.
   - Both texts stay static for the life of the session (safe for the prompt cache). Do not include `pairReviewRemediationGuidance`.
7. **`ClaudeCodeIntegrationConfiguration.swift`:** add `Agent` to `knowledgeDisallowedTools`.
8. **`AgentProviderPermissionControlsComponents.swift:226`:** change the text to "Allow Codex to search the web while it works through a task."

### Tests
- **Policy unit tests:**
  - Standard behavior is unchanged.
  - A Knowledge depth-0 session is eligible, with `.agentRunOnly` and `agent_manage`/`agent_explore` restricted.
  - A Knowledge depth-1 session gets `knowledgeLeaf`.
  - Lineage failures still fail closed.
  - Explore is still a leaf.
  - The ceiling contains `agent_run`.
  - The prompt variants match their audiences.
  - The Claude Knowledge block list contains `Agent`.
- **View-model tests:**
  - A created child is `.knowledge` before its identity is bound.
  - An adoption failure discards the tab.
  - K6 rejects a standard target, a sibling root, a grandchild, an index-only target with an unknown profile, and a replacement caller after an await.
- **Socket tests** (the `PersistentAgentModeMCPReadFileConnectionTests` pattern):
  - A Knowledge root's `tools/list` includes `agent_run` and not `agent_manage` or `agent_explore`. A Knowledge worker's list has none of the three.
  - Forged calls fail with `invalidParams` and create no session: worker `agent_run` start; root start with a role label, `tab_id`, an unsupported provider, or Codex web search turned off; and root `steer`/`cancel` aimed at a standard session.
- **Live acceptance** with both a Claude Knowledge root and a Codex Knowledge root:
  - The root spawns two workers.
  - Each worker's transcript shows a real web-tool call and its saved profile is `knowledge`.
  - There is no main-line `Agent`/`Task` tool use.
  - A worker told to delegate is refused.
  - The root's synthesis cites URLs.
  - Standard-session delegation still works.

## 5. Implementation order and validation

1. Workstream 1 can ship on its own. Run `make dev-test FILTER=<new ClaudeCodeProvider suites>`, then `ClaudeCLIExecutableOverrideWiringTests`, then live acceptance.
2. In Workstream 2, land policy, construction, handler, and native-tool enforcement together. Then land the advertisement and prompt changes. Run focused suites: `AgentDelegationPolicyTests`, `AgentDelegationServiceBoundaryTests`, the new Knowledge policy and socket suites, and the Knowledge provider-policy suites. Then live acceptance.
3. Run `make dev-lint`, `make dev-format-check`, `make guardrails`, and `Scripts/check-agent-context`.
4. Update [bounded MCP delegation](../agent-mcp-delegation-depth.md) with the Knowledge depth-0-only rule, the own-child targeting rule, the per-operation allowlist, and the native-delegation block. Rule K1 deliberately departs from the general depth-1 rule, and that document must say so.

## 6. Material disagreements and resolution

Both lanes agreed from the start on:
- `stream-json` plus `--verbose` for all three launches, with no session ID;
- parsing that relies on the final `result` object;
- override-aware authentication text;
- profile as an input to the delegation policy;
- Knowledge depth-1 sessions as leaves;
- children adopting `.knowledge` before binding;
- rejecting role labels;
- Claude and Codex as the only child providers;
- own-child targeting;
- no `agent_explore`;
- blocking `Agent`;
- audience-specific prompts;
- the Codex text fix.

**M1. Oracle retry policy. Resolved in round 1.**
- One lane wanted to keep current retries: retrying a shim refusal at most twice is bounded, and a 429 might get a different account on retry.
- The other wanted to remove the blanket exit-1 retry and surface authentication and admission refusals immediately.
- The first lane conceded. A Claude-side 429 in print mode arrives on stdout as an `is_error` result, which is thrown before `shouldRetry` runs, so that benefit never existed. Meanwhile, the shim's fail-closed path (stderr, exit 1) would be retried pointlessly.
- Both lanes then added the cancellation gap to the plan (§3).

**M2. Knowledge control surface. Resolved in round 1.**
- One lane proposed `agent_run` `start`/`steer`/`cancel`/`respond` plus `agent_manage get_log`, rejecting all other operations. That would have blocked `wait`/`poll`.
- The other proposed `agent_run` with all six operations and no `agent_manage`.
- The first lane conceded. `wait`/`poll` are the existing ways to collect results from workers started with `detach`. `get_log` gives no completion signal and would open a second tool whose other operations would each need rejecting.
- Resolution: K2. `get_log` can be added later if recovering findings after compaction proves necessary.

**M3. Model when `model_id` is omitted. Resolved in round 1.**
- One lane wanted to require an explicit compound model.
- The other wanted the child to inherit the parent's provider and model, because the parent can't reliably know raw model IDs and its provider is always Knowledge-supported.
- Merged into K4: inherit a frozen snapshot of the parent's live provider, model, and effort; fail closed if it can't be read; validate explicit models; reject role labels.

**M4. Gating on web-search availability. Resolved in round 1.**
- One lane wanted to reject worker creation when web search is effectively unavailable.
- The other wanted no gate, relying on the prompt's hedge.
- Merged into K5: reject only when a locally known toggle is off (Codex `searchToolEnabled`), before the tab is created. Do no remote probing. Leave Claude ungated, since no toggle exists. Keep WebFetch independent.

No material disagreement remains open.

## 7. Minor points settled by the plan author

- **No streaming reader is needed.** One lane proposed reading the output as a stream. `CLIProcessRunner.run` already buffers the full stdout, so parsing the buffer is enough.
- **Codex native delegation.** One lane asked to turn it off. It is already off (`multiAgentEnabled: false` in every Codex policy), so the plan only adds a test.
- **Index-only targets.** One lane allowed only live targets, the other allowed owner-validated metadata. The metadata index saves the profile, so K6 accepts a live or index profile together with the reconciled parent, and fails closed otherwise. This keeps steering a finished worker possible after an app relaunch.
- **`wait`/`poll` scope.** Session-addressed `wait`/`poll` from a Knowledge caller also gets the K6 check, so a Knowledge root can't read standard sessions through observation calls.
- **Where `Agent` is blocked.** Add it to the Knowledge and Oracle block lists, which are in scope. Whether the standard Agent Mode list (`agentDisallowedTools`, which blocks `Task`) also needs `Agent` is left as a follow-up outside this plan. Live testing should record whether `--disallowedTools Task` already hides `Agent`.

## 8. Risks and open items

- The shim's classification rules belong to the shim and may change. The live acceptance test (default login unavailable, shim log showing `managed-tap`) is what detects that.
- Rule K1 departs from the general delegation contract. Documentation and tests must make that clear.
- Codex web search is controlled by one global toggle, so turning it off disables search for Knowledge roots and workers alike. K5 makes that visible at worker creation.
- Running sessions keep the tool policy they were started with. Existing Knowledge sessions see the new tools only from their next run.
