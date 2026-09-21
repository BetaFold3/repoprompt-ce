# Completion outcome — 2026-09-21

Claude Code Auto permission support is implemented across policy, native initialization, coordinator lifecycle evidence, truthful presentation, focused tests, and the test ledger. Auto now has one local candidacy/resolution authority, never silently widens to another permission mode, and remains distinct from the Claude Code acknowledgement for the current controller attempt. Startup-return generation evidence is fenced to the installed controller, with private fallback evidence committed at installation so obsolete returns cannot evict successor evidence. Permission diagnostics now use ordered redaction passes: quoted assignments and authorization-scheme values are redacted before free-text assignments, a free-text value stops at a later credential-key boundary, and an unterminated quoted credential redacts through the end of the message, including a dangling final backslash. Passes mark their own output with an internal placeholder derived to be absent from the raw input and recognize it case-sensitively rather than trusting literal `[redacted]` text or case variants of that internal marker, so a value such as `password=[redacted],horse` still redacts through its suffix. This covers compact JSON and credential chains while preserving noncredential prose. Live UI projection distinguishes configuration, requested mode, resolved launch request, acknowledgement, local block, initialization, failure, and pending next-turn intent without claiming continuous effectiveness or RepoPrompt MCP containment.

The original implementation plan follows intact below for historical context. Its planning-only status and validation record are superseded by this completion outcome and the durable invariants in `docs/context/claude-model-family-catalog.md`.

---

# Claude Auto permissions implementation plan

Scope: read when the task touches Claude Code Auto eligibility, permission fallback, or truthful Agent Mode permission presentation.
Authority: Reference
Last-verified: 2026-09-17

## Status and consultation record

**Planning deliverable complete; implementation not performed or authorized by this document.** OracleE's final browser response is accepted as user-confirmed planning input and incorporated below.

The user selected Claude Auto support and safe fallback, including Sonnet 5 and Fable 5, truthful permission presentation, and preservation of existing defaults. Both OracleA and OracleE received the same initial prompt in the original parallel batch. After connection/verification repairs, OracleE successfully answered the unchanged prompt. Returned preset names and IDs matched the requested presets for both successful initial replies and both first-round replies.

- OracleA: `claude-auto-plan-oraclea-FBC3AD`. Initial response and both challenge-round responses were received with matching preset identity.
- OracleE: `claude-auto-plan-oraclee-43DC23`. Initial response and challenge round 1 were received with matching preset identity. The user supplied and explicitly confirmed the final browser response as OracleE's reply, and directed that its recommendations be considered.
- **Two anonymous challenge rounds were issued, with no third round.** Each lane received the other's arguments, not its identity or metadata.
- Delivery provenance: OracleE's final reply was supplied and confirmed by the user after the integration failed to capture it. It is incorporated as user-confirmed design input, not represented as an identity-verified tool return. No further Oracle round or retry is required for this plan.

The design below is the orchestrator's recommendation grounded in repository evidence, identity-verified Oracle replies, and the user's confirmed final OracleE design input. Section 6 records the substantive challenges, final placement preferences, and their resolution. No source code, settings, defaults, or permission behavior changed during planning.

## 1. Scope and invariants

In scope:

1. Extend official Claude Code Auto eligibility beyond the current Opus aliases, using existing model parsing and family authority.
2. Prevent requested Auto from silently becoming Full Access in main or child sessions.
3. Distinguish stored configuration, profile-requested permission, resolved launch permission, and runtime acknowledgement in the session UI.
4. Handle initialization rejection, model changes, backend remapping, resume, and stale lifecycle events without misleading state or dispatch under unintended permissions.

Out of scope: Codex behavior, classifier/reviewer cost or latency reporting, changing global permission defaults, model catalog additions, general MCP ACL redesign, releases, and live app mutation.

Preserve stored model IDs, effort, unknown permission strings, provider overrides, and explicit Full Access choices. No preference migration or automatic preference rewrite. Claude Auto does not establish end-to-end RepoPrompt MCP tool containment or a sandbox for child agents.

## 2. Verified current behavior

Paths below are repository-relative; function names are the stable navigation anchors.

| Evidence | Current behavior |
| --- | --- |
| `Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/ClaudeAgentToolPreferences.swift`, `supportsAutoPermissionMode`, `resolvePermissionMode` | Auto is locally eligible only for official `.claudeCode` with parsed `opus` or `opus[1m]`. Unsupported Auto is replaced according to a fallback parameter. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/Claude/ClaudeAgentModeCoordinator.swift`, `unsupportedAutoFallback` | Parent sessions use `acceptEdits`; child sessions use `bypassPermissions`. Callers consume the effective mode rather than surfacing the replacement. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/ProviderBindings/AgentProviderPreferenceSnapshotStore.swift`, `controlsBinding`, `permissionChromeBinding` | The outer binding receives the selected model, but permission chrome uses the configured/profile permission without model eligibility. |
| `Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/SDK/ClaudeNativeProcessSessionController.swift`, `initializeIfNeeded`, `applyInitialPermissionModeIfNeeded` | Initialization applies model flags and then sends `set_permission_mode` before marking initialized. |
| Same controller, `handleControlResponse` (around line 2534) | Success returns the response dictionary; an error throws `invalidControlResponse`. This establishes acknowledgement/error handling, not a continuously observed effective permission mode. |
| Coordinator, `shouldRetryFreshStartWithoutResume` (around line 1040) | Resume errors including `invalidControlResponse` and `initializationFailed` currently permit fresh-start recovery. Permission rejection must not be mistaken for lost resume state. |
| Coordinator, `applyCurrentClaudeModelAndEffortIfPossible` (around line 247) | Calls the controller directly and logs errors; this method itself has no active-turn guard or Auto qualification. Its callers and controller behavior require coverage before choosing deferral. |
| `Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/ClaudeCodeLaunchEnvironmentResolver.swift` | Resolved backend is `defaultClaude` or `compatible(id)`, with a separate optional `effectiveModel`. This is not definitive upstream account/gateway provenance. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/ProviderBindings/AgentModeProviderBindingService.swift` | Claude preference changes rely on pre-dispatch launch revalidation rather than eager shutdown. Managed permission profiles must remain authoritative. |
| Native controller, `handleControlRequest` | RepoPrompt MCP callbacks have independent local auto-approval behavior. This plan does not change that boundary. |

The existing `ClaudeNativeApprovalAndResumeTests` covers compatible-model launch resolution, restart requirements, and MCP approval payloads, not Auto initialization. Targeted searches found no direct tests of `supportsAutoPermissionMode` or `resolvePermissionMode`.

Official [Claude Code permission-mode documentation](https://code.claude.com/docs/en/permission-modes#eliminate-permission-prompts-with-auto-mode), checked on 2026-09-17, describes model, account, organization, and gateway eligibility. API/Claude Platform AWS eligibility includes Opus and Sonnet 4.6 or later and Fable; other listed gateways have narrower older-model support, including Sonnet 5 and Opus 4.7 or later. Therefore local model qualification is only permission to attempt Auto: the CLI remains the acceptance authority. Reverify this evolving matrix before implementation.

## 3. Recommended design

### 3.1 One local eligibility authority

Keep a pure classifier in `ClaudeAgentToolPreferences`, reusing `ClaudeModelSpecifier` and `ClaudeModelFamilyCatalog`; do not introduce a parallel catalog or a paid capability-discovery loop.

Candidate categories: eligible candidate, unsupported model, unknown model, and compatible backend.

- Restrict eligibility to official `.claudeCode`.
- Parse recognized effort suffixes through the existing specifier.
- Accept app aliases `opus`, `opus[1m]`, and `sonnet`.
- Accept exact curated legacy IDs `claude-opus-4-6`, `claude-opus-4-7`, and `claude-sonnet-4-6` as candidates, not guarantees across gateways.
- Accept existing major-5 Fable, Opus, and Sonnet family anchors and strict point-release grammar, including the parser's supported dated point releases. Registry corroboration controls listing, not eligibility validation of persisted IDs.
- Treat nil, blank, and default selections as unknown; reject known unsupported Haiku/4.5 selections. Do not invent new-major support, generic context-suffix stripping, aliases, or legacy dated-ID grammar.
- Preserve exact full IDs and existing case-sensitive family validation; app aliases may remain case-insensitive.

Recheck using resolved backend and effective model before process launch and applicable live model application. Known compatible backend remapping must not bypass the policy. Preserve the selected raw ID instead of substituting a supported neighbor.

### 3.2 Explicit failure rather than silent fallback

Replace fallback-oriented resolution with a value containing requested mode, optional launch mode, and optional Auto eligibility/reason. A missing launch mode means blocked.

- Eligible Auto launches as `auto`.
- Ineligible or unknown Auto blocks dispatch with an actionable reason.
- Never silently substitute `acceptEdits` or `bypassPermissions`, regardless of parentage.
- Other explicit modes and unknown non-Auto strings retain existing pass-through behavior.
- Remove the parent/child fallback choice and obsolete fallback fields atomically with caller changes.
- Recovery uses explicit model/permission controls. Externally managed sessions recover through their owning policy, not a child-local override.
- Do not turn transport failures into claims of model incompatibility.

**Additional verified integration requirement:** permission initialization rejection currently shares a generic error category with recoverable resume failures. Preserve operation-specific failure provenance, and prevent that rejection from triggering automatic fresh-start recovery or permission fallback. Keep genuine resume recovery working. Determine the narrowest local error representation during implementation; do not expand the provider-neutral error protocol without evidence that it is necessary.

### 3.3 Truthful session presentation

Keep these values distinct:

1. Configured preference: durable settings.
2. Requested permission: profile output, including managed overrides.
3. Resolved launch permission: local model/backend-qualified request.
4. Acknowledged request: successful control response for the current controller attempt.

Represent not started, blocked, initializing, acknowledged, and failed states using one non-Codable transient property on `AgentModeViewModel.TabSession`, mutated only by the coordinator. Put runtime-domain value types beside the Claude coordinator; binding DTOs contain their presentation projection. Derive desired configuration and resolution fresh rather than storing an independently editable copy.

An immutable launch-evidence snapshot captures `ControllerLaunchSettings`, including its optional effort-free Auto validation key, plus controller identity and initialization-attempt ownership. The key contains the parsed base selection and available backend-selection comparison inputs; it does not infer upstream account topology. Effort is tracked separately as the last acknowledged flag setting. Do not persist runtime evidence or infer it from restored session data.

Settings without a session model remain configuration-only. Live session presentation should show:

| State | Meaning |
| --- | --- |
| Eligible but not initialized | Auto selected; not yet accepted |
| Local block | Auto unavailable for this selection; run blocked |
| Initializing | Auto request pending |
| Successful initialization | Auto request accepted; this is not continuous effective-mode confirmation |
| Initialization failure | Request failed, with a sanitized actionable reason |
| Selection changed during a running turn | Active acknowledged request plus pending next-turn intent |

Configured checkmarks must not masquerade as active runtime state. Do not invent provider response fields. Existing usage-provenance observations are not automatically a current permission authority.

Pass optional session status through `AgentModeProviderBindingService` and `AgentProviderPreferenceSnapshotStore` to `AgentPermissionChromeBinding`; top-level settings pass none. Explicitly call `AgentModeViewModel.updatePermissionBindingState` after relevant active-session status changes: publishing `TabSession` alone does not rebuild the cached controls binding. Render the distinction in `AgentInputBar`. Qualify configuration-only capability summaries. Preserve unknown raw permission values in presentation instead of falsely showing Require Approval as the selected mode.

### 3.4 Lifecycle rules

Recompute eligibility before start, resume, replacement, dispatch, and applicable live model changes. An initialized-controller early return only retains existing evidence; it cannot acknowledge changed settings. Missing evidence requires controlled recycling and initialization rather than inference.

Add an optional immutable Auto validation key to `ControllerLaunchSettings`, excluding effort. Capture those settings in launch evidence rather than maintaining a separate model key in the snapshot. Reuse existing launch-settings equality through one comparison path for pre-dispatch and async model updates. The installed key and freshly derived desired key detect Auto-to-Auto base-model changes; permission-mode equality alone is insufficient. Native validation must still check the actual resolved backend/model, since the key is not an upstream availability guarantee.

Reuse existing controller identity, run ID, attempt ID, teardown, and publication mechanisms. Check ownership after suspension. Late results from detached/replaced controllers cannot acknowledge or overwrite state. Clear launch evidence on termination, detach, replacement, and tab closure. Cancellation cannot promote initializing to accepted.

**No separate permission-intent revision is planned.** For A → B → A, A's acknowledgement remains applicable only if B was uninstalled pending intent and no outstanding operation can later install B. Actual Auto-sensitive base/backend changes require replacement, invalidating the old controller evidence. Capture each effort operation's value independently of the effort-free launch key.

### 3.5 Auto-sensitive model and effort changes

An operation is Auto-sensitive when either the installed launch request or current desired permission is Auto.

- During initialization, an active turn, or reserved dispatch, defer live model/backend/permission/effort changes. Existing settings retain the latest desired value; coalesce changes rather than queuing every intermediate choice. Show active evidence and pending next-turn intent without interrupting the current turn.
- At idle, re-read intent. Base model, backend, permission, or other relevant launch-setting differences use existing tracked retirement/reinitialization. Do not eagerly shut down controllers in preference observers.
- Effort-only changes require unchanged base model, backend, permission, and launch settings, including compatibility of the resolved environment. Apply the latest effort to the initialized idle controller **without restart or another permission initialization**. Await its ACK before the next user-message write.
- Show “Effort change pending — applies before the next turn.” Clear pending effort on successful application, or when intent returns to the last acknowledged setting and no conflicting operation remains. Failed application remains pending with an error; the preparation attempt must not dispatch under an unapplied request. An effort ACK does not reconfirm permissions.
- Preserve non-Auto-to-non-Auto behavior and unrelated providers. Guard both scheduling and execution, including queued MainActor tasks.

Initialization, live settings, and dispatch reservation must be serialized for a controller. MainActor/native actor isolation is reentrant across awaits and is not sufficient by itself. Reuse an existing owned preparation task if available; otherwise add only a narrow per-controller single-flight preparation operation. Concurrent callers join or wait. Reserve before awaiting, revalidate intent/ownership before dispatch, and do not block processing of incoming control responses.

In native `applyModelAndEffort`, guard before storing/sending and recheck after environment resolution. An Auto controller must reject premature/in-flight live mutation explicitly; `hasCompletedInitialFlagSettings` alone is insufficient. Base-model/backend changes require restart. Dedicated initial flag application remains part of initialization, not this live-update path.

### 3.6 Native dispatch and failure boundaries

Require both a running process and completed initialization before `sendUserMessage` encodes or writes. Failure must write nothing.

Wrap noncancellation errors from `applyInitialPermissionModeIfNeeded` in a controller-local permission-stage error preserving requested mode and underlying cause. Preserve cancellation unchanged and existing shutdown-on-startup-failure cleanup. Exclude permission-stage errors and local Auto refusals from resume recovery before generic retry classification; retain genuine resume recovery.

`NativeAgentRuntimeControllerError` is a typealias of the native controller's `ControllerError`. Prefer a local wrapper rather than enlarging a shared error contract, but audit catches, translation, and exhaustive switches so classification cannot be erased. Surface one actionable error per owned attempt; preserve prompt/transcript and explicit recovery paths. No automatic replay under another mode.

## 4. Implementation sequence and files

This is a plan for a later implementation task, not authorization to implement now. Accepting the user-confirmed design input does not establish runtime protocol behavior or replace implementation validation.

1. **Close remaining wiring gaps.** Enumerate every dispatch, preparation, teardown, and error-translation caller; identify an existing single-flight operation to reuse where possible. Establish deterministic fixtures for correlated permission success/error, malformed responses, timeout, cancellation, and process exit. The verified codec returns an empty success as ACK, not an effective-mode report.
2. **Policy and coordinator atomically.** Update `ClaudeAgentToolPreferences.swift` and `ClaudeAgentModeCoordinator.swift` together: classifier, blocked resolution, no parent/child widening, optional effort-free Auto validation key in `ControllerLaunchSettings`, and dispatch guards.
3. **Native initialization and remapping.** Update `ClaudeNativeProcessSessionController.swift`; use existing launch-environment results. Add initialized-before-send enforcement, Auto live-mutation guards, and operation-specific failure handling. Ensure rejection cleans up and cannot trigger permission fallback or inappropriate fresh resume.
4. **State, callers, and UI.** Add the transient property in `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+TabSession.swift` and runtime value types beside the coordinator, for example `ClaudePermissionSessionState.swift`. Update `AgentModeViewModel.swift` model-change and live-binding paths and `AgentModeViewModel+ProviderBindings.swift` effort-change loop. Wire `AgentProviderBindingModels.swift`, `AgentProviderPreferenceSnapshotStore.swift`, `AgentModeProviderBindingService.swift`, `AgentInputBar.swift`, and `AgentPermissionCapabilitySummaryBuilder.swift`. Couple lifecycle tests to presentation and explicit binding invalidation.
5. **Tests and owning documentation.** Extend existing native tests and add narrowly scoped policy/presentation coverage where existing suites cannot express the boundary. Update the curated XCTest ledger surgically. Update the [Claude family owner](../claude-model-family-catalog.md) only after behavior changes; update [provider architecture](../../architecture/provider-plugins.md) if its durable seam description changes.

No changes are planned to `ClaudeModelFamilyCatalog` or its rows, `AgentModel`, secure-store schema, permission-profile cases, provider-neutral runtime protocol, or the provider package. Reuse catalog grammar from permission policy. Keep the policy/resolver/coordinator/native safety changes atomic so an intermediate build cannot silently widen Auto.

## 5. Acceptance matrix and validation

| Boundary | Required evidence |
| --- | --- |
| Models | Opus/Sonnet aliases; exact legacy IDs; Fable/Sonnet/Opus major-5 anchors and point releases; supported effort suffixes; strict malformed/future-ID rejection |
| Unknown/compatible | Default and unknown selections block under the proposed policy; compatible provider and resolved-backend remapping cannot inherit official Auto eligibility |
| Permissions | Main and child Auto never silently become another mode; explicit Full Access remains unchanged; managed profiles and unknown stored strings are preserved |
| Initialization | Rejected permission request prevents user-message dispatch and cleans up; transport errors remain distinct; rejection does not trigger fresh resume |
| Lifecycle | Controller reuse, resume, replacement, cancellation, stale completion, A → B → A, duplicate initialization scheduling, queued model tasks, and next-turn revalidation |
| Launch identity | Auto base/backend changes alter launch-settings equality; effort-only changes do not; evidence captures the original key; actual resolved remapping still receives native validation |
| Effort and serialization | Initialization-time/active-turn changes coalesce; idle effort applies without restart; dispatch waits for ACK; failure retains pending intent; preparation and message write cannot race |
| Native boundary | Send-before-initialized writes nothing; live Auto flags cannot mutate during partial initialization or an active turn; actual remapping is not mistaken for effort-only |
| Presentation | Configured versus requested versus acknowledged state; settings without a model; blocked and failed states; no unsupported containment claims |
| Existing behavior | Genuine resume recovery and independent MCP approval behavior continue to pass |

Proposed new suite names, not existing tests: `ClaudeAutoPermissionPolicyTests` and `ClaudeAutoPermissionPresentationTests`. Extend existing `ClaudeNativeApprovalAndResumeTests`; use other existing lifecycle suites if they provide the appropriate fake runtime.

For implementation, run coordinated `make dev-lint` and `make dev-test FILTER=<SuiteName>` for the two proposed suites and `ClaudeNativeApprovalAndResumeTests`, plus any existing lifecycle suites changed. Run `ClaudeModelFamilyCatalogTests` or `ClaudeCompatiblePluginBridgeTests` if their boundary changes rather than broadening package coverage by default. Run `make dev-provider-test` only if the provider package changes. Documentation requires `Scripts/check-agent-context`, `Scripts/test-check-agent-context`, and `make guardrails`.

Live qualification is a separate approval gate: record CLI version, account/gateway context, exact selected/resolved model, sanitized control result, and dispatch outcome. Obtain approval before credentialed/paid probes or visible app lifecycle changes. No such probe is authorized or performed by this plan.

## 6. Material challenges and disagreement resolutions

### 6.1 Eligibility and fallback: agreement from the initial responses

Both identity-verified initial responses favor curated model candidates plus CLI acceptance, and blocking rather than automatic `acceptEdits` or `bypassPermissions`. Neither proposes making default/unknown selections implicitly eligible or changing explicit Full Access.

CLI-only eligibility reduces catalog lag; automatic edit approval improves uninterrupted completion. Those are genuine tradeoffs, but neither preserves the chosen predictable local policy as well. **Resolution:** use curated candidacy, recheck resolved backend/model, fail explicitly, and retain user intent. This was an agreed decision, not a manufactured disagreement.

### 6.2 Effort during active turns: behavioral issue resolved by verified replies

OracleA initially said to preserve existing effort-only handling. OracleE's first challenge response required initialized-and-idle application because flag intent generation does not serialize permission initialization, flag application, and dispatch.

Direct reads confirmed the active-session effort loop and the native `isInitialized || hasCompletedInitialFlagSettings` gate. The strongest argument for immediate application is responsiveness during long turns; the counterargument is unspecified turn-boundary behavior plus a verified initialization overlap.

The final challenge explicitly relayed those arguments. OracleA's identity-verified round-2 reply adopted idle-only Auto-sensitive effort updates without restart, matching OracleE's verified round-1 requirement. The user-confirmed final OracleE response additionally makes dispatch reservation, resolved-environment compatibility, pending effort, and failed-application handling explicit. Those details are included in §3.5. **Resolution:** defer and coalesce for current OR desired Auto; apply and await ACK before the next dispatch; leave non-Auto behavior unchanged.

### 6.3 Intent revision and historical model: converged safety requirements

The initial proposals differed on adding an independent intent revision and how to detect Auto-to-Auto model changes. Both first-round replies accepted immutable settings/controller/attempt ownership instead of another revision counter, provided operations are serialized. They also required retaining the historical launch model; permission-mode equality alone is insufficient.

**Resolution after round 1:** no new revision counter; retain historical model/backend comparison inputs, associate results with the captured operation, and test A → B → A plus outstanding-operation cases. Use one comparison helper and one preparation path. An already initialized controller cannot acknowledge changed settings by returning early.

### 6.4 Native dispatch and resume: evidence-led additions, not residual disagreement

OracleE made native initialized-before-send enforcement explicit. Additional evidence showed that generic permission rejection could enter fresh-start resume recovery. OracleA accepted both corrections during round 1.

**Resolution:** enforce the native send gate; preserve a permission-stage failure wrapper; exclude it from generic resume recovery; preserve cancellation and genuine resume fallback. This is necessary even when the coordinator normally orders calls correctly.

### 6.5 Remaining code-placement preferences: resolved by orchestrator judgment

These placement choices do not alter the acceptance contract. The user authorized independent resolution of minor points and explicitly adopted the final browser response as planning input. Its recommendations have been considered rather than excluded because of the delivery failure.

| Choice | OracleA's final tool-verified position | User-confirmed final OracleE input | Recommendation and repository rationale |
| --- | --- | --- | --- |
| Model candidacy owner | Pure candidacy in catalog; backend/request policy in preferences | Candidacy and request policy in preferences, using catalog grammar | Keep the single Auto classifier in preferences. No separate catalog consumer was identified; existing strict grammar can be reused without adding a permission-specific catalog trait. |
| Runtime evidence storage | Nonpersisted observable `TabSession` property, coordinator mutations | Same owner, with explicit cached-binding invalidation | Use `TabSession` for lifecycle ownership, with coordinator-only mutation and explicit binding rebuild. Its verified declaration is already `@MainActor ObservableObject`; this avoids a parallel dictionary and does not create another desired-config authority. |
| Historical model/key | Separate historical model in immutable launch snapshot, with common comparison helper | Optional effort-free Auto key in `ControllerLaunchSettings`, captured with evidence | Adopt the latter: existing `Equatable` launch settings already drive mismatch handling, so extend that single comparison authority. The snapshot captures those settings without maintaining another key. Effort remains excluded to avoid effort-driven restarts. |

The final browser input is incorporated in the policy owner, observable state, Auto validation-key placement, effort deferral, operation ordering, and native failure boundaries. The key-placement recommendation supersedes this plan's earlier separate-snapshot-key choice. No third challenge round or substitute Oracle was used.

**Remaining uncertainty:** runtime protocol/current-account behavior still requires deterministic fixtures and separately approved live qualification. There is no remaining material behavior disagreement in the selected design. Browser delivery is provenance, not an open design blocker; it is not retrospectively labeled a verified integration return.

## 7. Rollout, rollback, and maintainer check

No migration, global default change, or automatic Full Access opt-in. Explain the intentional behavior change: unsupported Auto runs that formerly continued under replacement permissions will now block under the candidate design.

An older binary restores the old fallback behavior. Do not rewrite stored Auto to facilitate rollback; prefer a forward fix and disclose the regression risk.

Maintainer-guidance check: the invariant is that requested Auto never silently widens permissions. Resolver/UI divergence is directly verified. Core policy owns local eligibility; the CLI owns acceptance. Main risks are stale acknowledgement, inappropriate resume recovery, and model-change races, not classifier performance. Reuse existing lifecycle publication and avoid polling or new paid discovery. Cost accounting and MCP ACL redesign remain separate work.

## 8. Planning validation record

This document is a planning deliverable, not proof of implemented behavior. Consultation provenance and the accepted user-confirmed final input are recorded above. The commands below are rerun after the finalized document edits; they validate documentation only.

Planning-only checks on 2026-09-17:

- `Scripts/check-agent-context`: failed with three diagnostics in unchanged documents: invalid scope header and orphan status for `2026-09-03-codex-computer-use-enablement-plan.md`, plus orphan status for `2026-09-05-codex-conversation-branching-plan.md`. No diagnostic named this plan or its owner link.
- `Scripts/test-check-agent-context`: passed, 23 tests, zero skipped or failed.
- `make guardrails`: failed on 13 existing tracked documents absent from the durable-document allowlist. This new plan is untracked; the tracked-document guard does not establish its eventual contribution readiness. Add its explicit durable-document allowlist entry when preparing it for contribution.
- `git diff --check`: passed for tracked edits. No files were staged or committed.

No Swift build, behavioral tests, or live provider qualification ran because this task changes documentation only. Unrelated existing documents and worktree files were left untouched.
