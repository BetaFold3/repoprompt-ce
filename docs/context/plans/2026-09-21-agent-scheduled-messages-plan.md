# Agent Mode scheduled (delayed) message sending plan

Scope: read when the task touches Agent Mode scheduled or delayed message sending, the composer schedule control, scheduled-send persistence, the scheduled-send admission coordinator, sidebar or message scheduled badges, or the Scheduled Messages dashboard.
Authority: Reference
Last-verified: 2026-09-24

Status: **Phase 1 R12 is IMPLEMENTED, VALIDATED, and ACCEPTED for the requested scoped remediation.** The identity-verified fresh OracleE R12 review closed both remaining P1 findings—cancellation-induced MCP permission restoration and complete fallback activation ownership—found no new P0/P1 established by the supplied delta, and preserved all prior closures. This acceptance does not claim visible-app, live-provider, actual provider-runner, or physical sleep/wake/lid-close validation. Phase 1 report-only P2 findings remain deferred. **Phase 2 is IMPLEMENTED, VALIDATED, and ACCEPTED by identity-verified OracleA and OracleB fresh R1 reviews**, with nonblocking follow-ups recorded below; **Phase 3 is IMPLEMENTED, VALIDATED, and ACCEPTED by identity-verified fresh OracleA and OracleB R2 reviews**; Phase 4 remains pending, so this plan stays active rather than being archived.
Decision process: the original two-lane planning and user decisions in §§1, 6, and 7 remain authoritative for the design. The accepted Phase 1 remediation outcome is summarized here; the Phase 2 implementation notes and phase status below track the incremental delivery without changing the original design decisions.

## Current Phase 1 remediation outcome (2026-09-24)

### Accepted ownership and commit contracts

- **Captured restoration authority:** removal captures the approval generation in its cleanup descriptor before suspension and passes that exact authority into MCP deactivation. A cancelled installed subscription may clear its live generation without erasing the operation's token. Captured `nil` never falls back to another generation or an unconditional shared write.
- **Owner-safe permission restoration:** shared permission restoration remains generation-conditional. After its await, deactivation revalidates the installed session plus MCP activation and registration identities before restoring local state; the captured owner's original local preference is restored independently of whether the shared-service write is accepted.
- **Complete fallback activation:** intervening prompt and subview edits are merged into the surviving tab while context overrides, selected files, expanded folders, and the remaining fallback transition still apply. Preserving one live edit no longer abandons the rest of activation.
- **Application-stage ownership:** a reusable predicate combines removal ownership, mutation ownership, the captured selection-mirror revision, and current active-tab membership. It is rechecked across fast and heavy application stages and nested file-state suspension/mutation boundaries, preventing an obsolete same-ID activation from overwriting newer prompt, subview, context, selection, expansion, codemap, or slice state.
- **Joint logical commit:** the synchronous, no-await Prompt-and-Agent logical commit remains the irreversible boundary; captured-resource cleanup follows without reopening the admitted removal or adding an asynchronous workspace lease.
- **Closures preserved:** stale-index admission, delayed approval setup, precommit-abort registration settlement, foreign-workspace index/sort protection, admission overwrite, rematerialization gap, premature recovery retirement, durable-snapshot settlement, abandoned-preflight cleanup, and all earlier reviewed P1/R3/F-series closures remain closed.

### Final R12 validation

- Agent stale-reset ownership **26 PASS**, ticket `364ee9b8-2e7a-4830-aa06-960cae1d4f91`.
- Prompt removal ownership **7 PASS**, ticket `a2a973c6-b751-41a4-a65c-323a7b702666`.
- Full root **PASS: 6,010/6,010 tests across 567/567 suites, zero final failures**, ticket `77fcde2b-f58e-4722-8830-5bedade7e1d5`. `AgentLifecycleExecutionContractTests` had one contained initial runner crash and then passed its 9-test retry; this was not a zero-retry run.
- Lint **PASS**, ticket `86fda67c-ee62-4f18-8b8a-df0cc29b0a1b`; RepoPrompt product build **PASS**, ticket `f86c71cd-ab0a-446c-a325-715d849f3167`.
- Repository guardrails **PASS**; agent-context validation reported **0 warnings** with **23 checker tests PASS**; executable contract ledger **PASS with exactly 6,105 IDs**.
- No visible-app, live-provider, actual provider-runner boundary, or physical sleep/wake/lid-close validation was performed.

### Nonblocking deferred work

- **Report-only P2:** the held application-stage regression does not independently make every inner guard observable; the epoch regression exercises both context-revision and removal-owner fencing rather than isolating each. These are test-sensitivity limitations, not established production defects, and require no further remediation round.
- The real remote-controller/event-task delivery regression and intentionally nonpersisting dirty-removal policy remain report-only P2.
- Persisted-origin projection, live `customStoragePath` migration, presentation/hydration marker separation, quit/cancel authorization, and closed-tab attention discovery remain deferred. Phase 2 supplies the sidebar/index projection described below; Phase 3 adds the dashboard described below, while custom-picker/attachment-editing work remains Phase 4.

## Current Phase 2 implementation (2026-09-24)

- The derived metadata index uses schema **7**, invalidating schema-6 caches for a rebuild from schedule-aware session stubs. Session serialization remains **7**.
- `lastScheduledDispatch` now follows the existing bounded pending summary through metadata records, sidebar entries, metadata equality, restoration, save/upsert, scheduled-state refresh, and spawn-parent index repair. `hasUnreadableScheduledSend` is computed from `scheduledSendSummary.isUnreadable`, not independently persisted as a second authority.
- Sidebar rows project pending, sending, needs-confirmation, failed, unreadable, and historical states. Pending schedules show a clock, attention states an orange marker, and accepted historical sends a dim clock. Tooltips and accessibility text distinguish Sending from Sent and retain scheduled/sent times.
- Hydrated, identity-matched live schedule and receipt values take precedence, including authoritative `nil`; unhydrated rows fall back to index metadata. Schedule state survives threaded-row copies and contributes the `scheduled` search token. Pending, unreadable, and historical records count as sidebar content.
- Focused regression coverage exercises bounded preview and metadata round-trip/equality, schema-6 invalidation and actual stub rebuild, live-versus-entry precedence, attention/history projection, search, row copying, and receipt-only titles without an index entry. Eight new executable methods and eight surgical ledger rows were added.
- Index-only refresh now reads a header stub, captures the index owner and storage path, revalidates them after suspension, then patches only schedule fields onto the current entry. Local index projection rejects unhydrated live defaults. The hydration caller sets `hasLoadedPersistedState` synchronously after `installHydratedScheduledSend`, before its scheduled normalization task can resume; this ordering must remain intact.
- This phase does not change dispatch admission, provider protocols, the existing user-message marker, or Phase 1 ownership contracts. No live-app or physical sleep/wake validation is claimed.

### Phase 2 validation and review

- Focused suites passed: `AgentSessionMetadataRecordExtensionTests` **28**, `AgentScheduledSendPersistenceTests` **34**, `AgentModeSidebarSessionBuilderTests` **13**, `RemoteSidebarBadgingTests` **15**, and `AgentScheduledSendDispatchTests` **41**. The affected sidebar, persistence, and dispatch suites were rerun after remediation.
- Full root **PASS: 6,018/6,018 tests across 567/567 suites, zero final failures**, ticket `3003e5c6-33f5-41f1-a183-0cd34a1ca35a`, with source/artifact integrity verified. Three suites passed on retry: `AgentRunResponsePresentationTests` after a timeout, `PersistentAgentModeMCPReadFileConnectionTests` after a crash, and `WorkspaceCodemapLocalGitClassificationTests` after a crash. This was not a zero-retry run.
- An earlier full-root attempt, ticket `ae0d1732-5a75-457c-8541-d09ff8a2fb0d`, executed 6,017 tests with zero final test failures but exited **67** on source-digest integrity; it is not accepted as green evidence.
- Lint **PASS**, ticket `b46f2865-cab7-481a-bb27-df976af7f9ac`; RepoPrompt product build **PASS**, ticket `b555c76d-6fdc-473a-9037-bf3466a69dba`. Initial redundant-syntax lint errors were corrected before these passes.
- Repository guardrails **PASS**; agent-context checks **0 warnings**, **23 checker tests PASS**; exact executable ledger reconciliation **PASS: 6,113 IDs**. No visible-app, provider-runner, physical sleep/wake, or lid-close validation was performed.
- **OracleA:** initial approval with a minor historical-title correction; fresh R1 explicitly closed it and approved the scoped remediation, with refresh-race coverage retained as nonblocking.
- **OracleB:** initial acceptance with no P0/P1; fresh R1 accepted the remediation and explicitly closed stale-entry write-back, unhydrated index publication, and the historical-title finding. No fix-induced regression was established. Both R1 reviews requested no further loop.

### Phase 2 nonblocking follow-ups

- **Phase 3 presentation:** an index-only `.dispatching` record can display “Sending” until hydration, and indefinitely if hydration fails or confirmation retries exhaust. Dispatch remains blocked; broader attention discovery should incorporate coordinator obligations. Closed/stashed and paged-out attention, collapsed-child aggregation, and a HUD badge remain deferred.
- **State-projection hardening:** hand-copied fields with optional defaults remain a maintenance hazard; remaining omitted schedule arguments are remote-only or DEBUG paths. Revisit before remote scheduling. Overlapping index-only disk reads have no per-session generation ordering; an older result can temporarily replace newer schedule metadata, while dispatch still revalidates hydrated authority.
- **Coverage:** deterministic suspension coverage for disk refresh and a direct unhydrated-writer guard regression remain follow-ups, as do stronger default-title, identity-mismatch, live-pending-over-empty-index, and populated legacy-index cases. The current full-root pass does not replace these targeted oracles.
- **Explicitly deferred decision:** whether conversation reset, forks, or handoffs retain/copy historical `lastScheduledDispatch` receipts. Phase 2 changes presentation, not those lifecycle policies; the pending-record preservation and non-copying contract is unchanged.
- Tooltip reason detail, VoiceOver duplication, presentation-type placement, explicit live/index branching syntax, and documenting one-time history-enrichment cost remain report-only polish. Check badge legibility and tooltips in a narrow sidebar before release.

## Current Phase 3 implementation (2026-09-24)

- The Agent session-sidebar header has a clock/count button opening the Scheduled Messages sheet. Current-workspace rows combine index hints, identity-matched hydrated state (including authoritative absence), and process-owned confirmation/recovery obligations. Historical receipts alone do not create pending rows.
- Live rows reuse the existing durable banner actions for edit/reschedule, cancel, Send now, run-alongside, unreadable discard, and persistence-only retry. Actions revalidate the dashboard workspace and the host's durable session binding; rows hold hosts weakly. Dispatch admission and provider protocols are unchanged.
- All-workspaces rows use available metadata indexes only, remain read-only, and offer Open workspace. Missing or unreadable indexes produce an explicit incomplete workspace row rather than a false empty result; the dashboard does not hydrate or rebuild foreign indexes. Current open/stashed sessions can be opened for hydration; this does not add a general closed-session restoration path.
- Reload captures workspace and index-owner identity and revalidates after suspension and before publication. Coordinator notifications are coalesced and change-aware, the badge isolates its own invalidation, and the sheet uses a cancellation-aware reload task.
- Hydrated non-nil members have a dedicated presentation path independent of dispatch-discovery candidates, so a committed attempt stays visible while recovery preparation is suspended. Model-owned workspace observation deduplicates IDs before dropping the initial replay; rerendering does not recreate the subscription.
- Dashboard presentation distinguishes a live admission from an index-only dispatching hint and accepted saving from an unconfirmed provider outcome. Recovery-only rows use phase-aware wording; confirmation reasons share readable text with the banner. The Phase 2 sidebar's index-only Sending limitation remains deferred.
- Regression coverage exercises actual dashboard reload and durable action routing, authoritative-nil reconciliation, held-read workspace fencing, explicit unavailable indexes, read-only scope, Send now with run-alongside, notification coalescing, and leave/deadline/return confirmation. Fourteen executable tests were added overall, with surgical ledger changes.

### Phase 3 validation and review

- Final focused suites: `AgentScheduledMessagesViewModelTests` **9 PASS**, ticket `f253f89b-a69b-4d02-8948-84bf5703bf35`; `AgentScheduledSendCoordinatorTests` **45 PASS**, ticket `96bc1186-f7b6-40af-b024-a5cdb7a8770b`; `AgentScheduledSendDispatchTests` **44 PASS**, ticket `5bbb3445-5ae9-4c04-bb0d-5a947b4b8aec`.
- Final full root **PASS: 6,032/6,032 tests across 568/568 suites, zero final failures**, ticket `9744b5a1-56ae-47d0-b68f-196d24126714`, with source/artifact integrity verified. `RemoteAgentSessionTests` passed on retry; this was not a zero-retry run. The preceding remediation also passed **6,030/6,030**, ticket `d7999e6c-45f0-4457-9415-6ab905644c09`, with `AgentRunWorktreeStartTests` and `MCPAskOracleLifecycleTests` passing on retry.
- Earlier full-root ticket `cef67d28-ea19-4e31-9b8b-255905d795c4` failed two worktree-start assertions (the runner labelled the suite CRASH); the same assertions were found in older runs. Its focused rerun passed **41 tests**, ticket `1cba399d-2082-407a-ac49-12c7d408513f`. Ticket `573c492d-10f8-4387-b9c5-5d083fe2bf91` had zero final test failures but exited **67** on source-digest integrity. Neither earlier full-root attempt is green evidence.
- Final lint **PASS**, ticket `97769b1e-54a9-4510-b68a-cf5872993132`; RepoPrompt product build **PASS**, ticket `ed89d350-5686-447d-9e74-97cf01d41f93`; coordinated debug packaging **PASS**, ticket `8561085b-35d1-4c43-8736-3fda3d1341e1` (no launch). Intermediate compile, assertion, and lint failures were corrected before final passes.
- Repository guardrails and staged-index secret preflight passed. Agent-context checks reported **0 warnings** with **23 checker tests PASS**; exact executable ledger reconciliation passed with **6,127 IDs**.
- Initial identity-verified OracleA and OracleB reviews requested changes. Their P1 findings covered authoritative absence, workspace/action ownership, unavailable indexes, and notification/reload churn. Fresh R1 closed the original projection, ownership, and unavailable-index findings. It identified a fix-induced disappearing in-flight row (OracleA R1-1) and retained the dashboard reload concern as a body-created workspace publisher loop (OracleB N1). Both have scoped remediation and deterministic regressions. Identity-verified fresh R2 reviews at snapshot `2026-09-24/1248` explicitly closed both: OracleA approved the scoped remediation, and OracleB accepted Phase 3, closing B2 in full. All earlier P1 closures remain intact; neither lane established a fix-induced P0/P1 or requested another loop.
- No visible-app, actual provider-runner, physical sleep/wake, or lid-close validation was performed. Phase 4 picker and attachment editing, general closed/paged-out restoration, and deferred sidebar presentation remain outside this delivery.

### Phase 3 report-only follow-ups

- A real workspace-manager/sheet integration test is still missing: held-read and stale-action tests control persistence ownership directly, and the deadline-return test uses coordinator host suppression. No rendered SwiftUI or visible-app behavior is claimed.
- Dashboard freshness does not cover every noncandidate index update, hydrated unreadable transition, or session rename. Owner changes without a workspace-ID event may clear rows without requesting another reload; actions remain guarded. Follow-up work should preserve bounded notifications rather than reintroduce unconditional refreshes.
- A row whose captured props outlive actionability may have blank fallback status. A rebuilding current-workspace disk index can show a cosmetic incomplete warning despite an authoritative in-memory index. The revoked-session filter may be broader than an exact current-session comparison.
- All-workspaces remains index-only, so process-only attention in other workspaces is not enriched there. Disk-only rows can make the badge count differ from the list. The dashboard receives the broad coordinator-host protocol; narrowing that interface and removing redundant sorting remain deferred.
- The existing ledger note for `testReservedHandoffWithoutAcceptanceBecomesAttentionAndKeepsProtection` mentions two scenarios while its scenario-count column is three; exact executable-ID reconciliation is unaffected. This is report-only metadata cleanup.
- R2 report-only follow-ups include duplicated hydrated/live projection work; possible duplicate row IDs if two tabs bind the same durable session; healthy-send wording transitions; coverage of provider-pending/accepted/no-coordinator presentation and the production workspace subscription/render path; and inferred fixture/timing/tag inaccuracies in the new held-dispatch ledger row. The shared banner's in-flight interaction behavior was not rendered or independently exercised. These are not established P0/P1 defects and do not require another remediation loop.
- The Phase 2 sidebar index-only Sending presentation and Phase 4 past-deadline picker range remain deferred. General closed/paged-out restoration, collapsed-child attention aggregation, and a HUD badge are not added.

## 1. Outcome and scope

Add Slack-style scheduled sending to Agent Mode:

1. A split control beside Send offers "send now" or a delay in 15-minute steps up to 24 hours (quick picks 15 m, 30 m, 1 h, 2 h, 4 h plus a custom stepper), always showing the resulting local time. The control stays reachable while a run is active, when Send is replaced by Cancel.
2. It works for a **new session** (first prompt) and for a **follow-up** in an existing session.
3. **One pending scheduled message per session.** Actions: edit, reschedule, cancel, send now.
4. The scheduled time is a **not-before** time. A follow-up waits until its own session's run finishes and never interrupts or answers a parked question. A scheduled new session also waits until no other session in the workspace is busy, unless the user chose **Run alongside other sessions**. Waiting on busy is ordinary deferral, not an error.
5. Nothing runs while the app is quit. A message whose deadline passed while the Mac was asleep or the app was closed moves to **needs confirmation** and is never auto-sent.
6. The sidebar shows a pending badge on the session; after dispatch a quieter historical marker remains on the session and on the specific user message ("Scheduled for 10:30 · Sent 14:34") and survives reopen.
7. A **Scheduled Messages** dashboard lists pending, waiting, needs-confirmation and failed entries (current workspace by default, all-workspaces filter) with the actions above. Send now still respects the busy gate unless the override is chosen.

Non-goals for v1: automatic subscription-quota or reset detection (the app has no such data, §2), execution while quit, multiple pending messages per session, remote-host sessions (§7 Q4), changes to provider protocols.

## 2. Verified starting points

Line references identify the checkout inspected on 2026-09-21; they are not a guarantee against later movement.

| Boundary | Evidence and consequence |
|---|---|
| Submit appends before dispatch | [`submitPreparedUserTurn`](../../../Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift#L13750) builds the user item, calls `session.appendItem` and `scheduleSave` at 13837–13847, and only then branches to remote, Codex, steering or `startAgentRun` (14110). A scheduled prompt must not enter this path until it is due. |
| Live steering and turn-boundary queue | Running sessions route through `activeProviderSteeringRoute` (14152–14164: ACP prompt or Claude native interrupt, gated on `runState == .running && pendingApproval == nil`); `.waitingForUser` resumes `instructionContinuation` with the submitted text (14089–14104); otherwise text is appended to the in-memory `session.pendingInstructions` (14132; declared in [`+TabSession.swift:269`](../../../Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+TabSession.swift#L269)). None of these may be used for scheduled dispatch. |
| Composer latch | [`AgentComposerSubmitTarget` / `AgentComposerSubmitAttempt` / `AgentComposerSubmissionLatch`](../../../Sources/RepoPrompt/Features/AgentMode/ViewModels/UI/AgentComposerUIModels.swift#L59) (59–174): one active attempt per tab; `complete(...)` decides whether the draft is cleared from the `UserTurnSubmissionResult`. |
| Cancel replaces Send | [`AgentInputBar.swift:843–858`](../../../Sources/RepoPrompt/Features/AgentMode/Views/AgentInputBar.swift#L843) renders `CancelButton` when `props.cancelTarget != nil`; [`+ComposerUI.swift:16–24`](../../../Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+ComposerUI.swift#L16) sets it when `runState.isActive && runState != .waitingForUser && runID != nil`. |
| Run outcome signal | [`startAgentRun`](../../../Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift#L15393) returns `CodexAgentModeCoordinator.NativeSendOutcome?` with `.sent`, `.queuedFallback`, `.stale`, `.cancelled`, `.failed`, or `nil` (see the Codex switch near 14006–14020). This is the acceptance signal for §3.3. |
| Terminal run states | [`AgentSessionRunState`](../../../Sources/RepoPrompt/Features/AgentMode/Models/AgentChatModels.swift#L511) distinguishes `.completed`, `.cancelled`, `.failed`, `.idle`; `isActive` covers `.running`, `.waitingForUser`, `.waitingForQuestion`, `.waitingForApproval`. |
| Session persistence | [`AgentSession`](../../../Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSession.swift#L213) is serialization v7 (214) and has no schedule fields. `pendingHandoffPayload/CreatedAt/SourceItemID/DefersProviderLockUntilSend` (325–330) is the precedent for persisted pending text outside `items`/`transcript`, hydrated at [`AgentModeViewModel.swift:4800–4806`](../../../Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift#L4800). |
| Newer versions are not rejected | [`AgentSessionDataService.swift:525`](../../../Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSessionDataService.swift#L525) rewrites only when `serializationVersion < current`; no reader rejects a newer version. A version bump therefore protects nothing against older writers (§6 P3). |
| Field-local preservation precedent | [`AgentSessionDataCodec`](../../../Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSessionDataCodec.swift#L22) captures the `providerUsage` member as raw bytes and re-inserts it on encode. |
| Immediate save | [`scheduleSave(for:)`](../../../Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift#L11945) debounces one second; `saveSession(for:)` (11992) is the immediate private async save. |
| Chat item and transcript metadata | `AgentChatItem` / `AgentChatItemPersist` ([`AgentChatModels.swift`](../../../Sources/RepoPrompt/Features/AgentMode/Models/AgentChatModels.swift#L153)) and [`AgentTranscriptActivity`](../../../Sources/RepoPrompt/Features/AgentMode/Models/AgentTranscriptModels.swift#L81) (81–97, copied at 148 and 175, second shape at 240–267) already round-trip `workflow`, `codexGoalMode`, `isLocalControlPlaneEcho`, `isUndeliveredRemoteSend`. Provenance follows the same pattern. |
| Metadata index is derived | [`rebuildMetadataIndex`](../../../Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSessionDataService.swift#L797) (797–862) scans session files and builds `AgentSessionMetadataRecord.record(from:...)`; save path uses `metadataRecord(from:)` (576). [`AgentSessionMetadataIndex`](../../../Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSessionMetadataIndex.swift#L4) is schema v6 with `decodeIfPresent` defaults. |
| Empty sessions are hidden or retitled | [`sessionIndexEntryHasConversationContent`](../../../Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeSidebarSessionBuilder.swift#L75) (`itemCount > 0 || lastUserMessageAt != nil || hasUnknownConversationContent`) and `sidebarTitle` (432–445, falls back to "New Chat"). A scheduled new session has no items, so the schedule summary must count as content. |
| Sidebar row composition | [`sidebarRow`](../../../Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeSidebarSessionBuilder.swift#L276) (276–347) reads `metadataLiveSession ?? entry` for worktree and merge attention; the scheduled badge follows the same precedence. |
| Same workspace in several windows | [`AppDeepLinkRouter.agentSessionPreferredExistingWindows`](../../../Sources/RepoPrompt/App/AppDeepLinkRouter.swift#L131) iterates every live window whose `activeWorkspace?.id` matches, so one workspace can be active in multiple windows and each has its own `AgentModeViewModel`. Admission must be app-level (§6 P1). |
| Image attachments are durable already | [`AgentAttachmentStore`](../../../Sources/RepoPrompt/Features/AgentMode/Runtime/AgentAttachmentStore.swift#L59) copies imports into managed storage under the workspace directory and `clearConsumedLocalFiles` (79) deletes them after consumption. Scheduling must defer that cleanup to dispatch or cancel. |
| Wake observation | [`ServerController.swift:228–243`](../../../Sources/RepoPrompt/Infrastructure/MCP/ServerController.swift#L228) observes `NSWorkspace.didWakeNotification`. |
| No quota or reset data | Only [`ClaudeSDKNDJSONTranslator.parseRateLimitEventMessage`](../../../Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/ClaudeSDKNDJSONTranslator.swift#L651) touches provider rate limits, and it emits status text while discarding timing. Repository-wide searches for `rateLimits`, `resetAt`, `resets_in_seconds`, `five_hour`, `seven_day` found nothing. |
| No aggregate busy helper | `isTabRunning(_:)` (AgentModeViewModel.swift:17498) is per tab; no "any run active in workspace" helper exists and one must be added. |

## 3. Design

### 3.1 Data model

New file `Sources/RepoPrompt/Features/AgentMode/Models/AgentScheduledSend.swift`:

```swift
struct AgentScheduledSendPersist: Codable, Equatable, Sendable {
    enum State: String, Codable { case scheduled, needsConfirmation, dispatching, failed }
    enum ConfirmationReason: String, Codable {
        case missedWhileClosed, missedDuringSleep, clockChanged, runNotCompleted,
             deliveryUnknown, destinationUnavailable
    }
    struct Attempt: Codable, Equatable, Sendable { let attemptID: UUID; let itemID: UUID; let startedAt: Date }

    let id: UUID                          // idempotency key
    var createdAt, updatedAt, notBefore: Date
    var state: State
    var confirmationReason: ConfirmationReason?
    var rawText: String
    var attachments: [AgentImageAttachment]
    var taggedFileAttachments: [AgentTaggedFileAttachment]
    var workflow: AgentWorkflowDefinition?
    var interviewFirst: Bool
    var isNewSessionStart: Bool
    var runAlongsideOtherSessions: Bool
    var firstEligibleAt: Date?            // informational only ("waiting since 14:00")
    var attempt: Attempt?
    var lastFailureMessage: String?
}

struct AgentScheduledSendProvenance: Codable, Equatable, Sendable {
    let scheduleID: UUID; let attemptID: UUID; let scheduledFor: Date; let sentAt: Date
}
```

- **Persisted member wrapper.** `AgentSession` stores the record through `AgentScheduledSendMember` = `.v1(AgentScheduledSendPersist)` | `.unreadable(JSON tree)`. Decode tries v1 first; on failure it captures the member as a generic JSON value, re-emits it unchanged on save, projects it to the dashboard as failed/unreadable, and never dispatches it. This is semantic preservation, not byte-for-byte; it keeps a malformed or future schedule from making the whole session undecodable and from being silently dropped by a schedule-aware build. An unknown `State` raw value decodes to `.needsConfirmation`.
- **`AgentSession` fields:** `scheduledSend: AgentScheduledSendMember?` and `lastScheduledDispatch: AgentScheduledSendProvenance?`. Update the memberwise initializer, `CodingKeys`, the custom decoder (`decodeIfPresent`), the encoder (omit when nil), `listStub()`, and the stub header read in `loadAgentSessionStub` (AgentSessionDataService.swift ≈1188) so index rebuilds keep the badge. **`currentSerializationVersion` stays 7** (§6 P3); downgrade-and-resave by an older build is documented as unsafe for pending schedules.
- **Configuration is read live at dispatch.** Agent kind, model, reasoning effort and OMP thinking selections are not snapshotted; the session's current selection is the single authority (§7 Q1, provisional). Workflow, `interviewFirst`, text and attachments are frozen in the record.
- **`TabSession`:** `@Published var scheduledSend` and `lastScheduledDispatch`, saved at the `AgentSession(...)` construction (≈12230), hydrated beside `pendingHandoff` (4800). Conversation reset leaves the record intact. Forks and handoffs never copy a pending schedule.
- **Chat items and transcript:** `AgentChatItem`, `AgentChatItemPersist` and both `AgentTranscriptActivity` shapes gain `scheduledSend: AgentScheduledSendProvenance?`, carried exactly like `codexGoalMode`. Provenance is never rendered into provider-facing or handoff text.
- **Metadata index (schema 6 → 7):** `AgentSessionMetadataRecord` gains `scheduledSendSummary { id, notBefore, stateRaw, isNewSessionStart, runAlongside, previewText (≤120 chars) }`, computed `hasUnreadableScheduledSend: Bool` (derived from `scheduledSendSummary.isUnreadable`), and persisted `lastScheduledDispatch`. Populate in `record(from:)`; a mismatched schema is already discarded and rebuilt. `sessionIndexEntryHasConversationContent` and `sidebarTitle` treat a non-nil pending summary or historical receipt as content.
- **Attachments:** images are already copied into managed storage at import; scheduling must not call `clearConsumedLocalFiles` until dispatch succeeds or the record is cancelled. Tagged files keep identity (`relativePath`) and resolve content at dispatch; a missing file fails the dispatch visibly.

### 3.2 Coordinator

`AgentScheduledSendCoordinator` in `Sources/RepoPrompt/Features/AgentMode/Runtime/Scheduling/`: a process-retained `@MainActor final class` created by the app composition root (`App/WindowState.swift` wiring only), with injected `SchedulerClock` (`now`, `sleep(until:)`, suspended-gap probe) and a weak registry of dispatch hosts.

- **Hosts.** Each `AgentModeViewModel` registers weakly as a host implementing `isBusy(tabID:)`, `hasBusySession(inWorkspace:excluding:)`, `ensureHydrated(tabID:)`, `dispatch(...)`, and `persistNow(tabID:)`. Hosts execute; the coordinator arms, times, aggregates busy state, and issues **per-session admission leases keyed by session ID**, so two windows on the same workspace cannot both dispatch one record.
- **Discovery.** Metadata-index summaries are a discovery hint only; before admission the coordinator revalidates `id`, `state` and `notBefore` against the hydrated record. If no host owns the record's workspace, the record is shown in the dashboard and needs confirmation on open; it is never routed through `currentTabID`.
- **Arming epochs.** The coordinator increments an arming epoch at launch and on every wake. For each record it keeps in-memory `armedAt` and `observedDueAwakeAt`. A record is marked *observed due awake* only when an evaluation runs while awake **and** arming has been continuous since before `notBefore` (a callback that fires after wake does not prove the deadline passed while awake).
- **Triggers** for `evaluate()`: one timer to the earliest future `notBefore`; launch and workspace load; `didWakeNotification` (plus a continuous-vs-suspending clock gap > 30 s as backstop); `runState` transitions and `tabsWithActiveAgentRun` changes; record create/edit/reschedule/cancel/confirm/send-now; hydration complete; tab close (disarms). `evaluate()` is synchronous, re-entrancy guarded (`isEvaluating`/`needsRerun`), and orders due candidates by `(notBefore, createdAt, id)`.
- **Busy set** (a session is busy if any holds): `runState.isActive` (this includes `.waitingForUser`, `.waitingForQuestion`, `.waitingForApproval`); any of `pendingApproval`, `pendingAskUser`, `pendingUserInputRequest`, `pendingPermissionsRequest` set; `pendingInstructions` non-empty; a cancellation not yet settled; a start or dispatch reservation held by another admission. A scheduled follow-up therefore never becomes the answer to a parked question (§6 P5).
- **Gates.** Follow-up: own session not busy. New session: additionally no other session in the workspace (across all hosts) is busy and no reservation is in flight; `runAlongsideOtherSessions` bypasses only that workspace condition. At most one workspace-gated new session is admitted per pass; its reservation is released by the session's first `runState` publication or the `startAgentRun` outcome.
- **Needs-confirmation rules (§6 P4, converged):**
  1. A deadline crossed while asleep or closed, or an uncertain crossing (clock jump, unknown gap), → `needsConfirmation(missedDuringSleep | missedWhileClosed | clockChanged)`.
  2. Every record overdue at relaunch → `needsConfirmation` (runs never survive process exit, so "the run finished" cannot be established).
  3. A follow-up already observed due awake and waiting on its own session captures the blocking `runID`; it may survive a sleep and auto-dispatches **only** when the coordinator observes that captured run reach `.completed` in-process with the session then inactive and no replacement run in between. `.cancelled`, `.failed`, idle normalization, or lost run identity → `needsConfirmation(runNotCompleted)`. Accepted trade-off: a follow-up such as "summarize partial results" after a failed run needs one click.
  4. A new session already observed due awake may survive a sleep and dispatches only after an atomic check-and-reserve of workspace availability.
  5. `needsConfirmation` is persisted (a clock moving backward after wake must not re-arm a missed deadline on restart). User confirmations and send-now are in-memory: a relaunch requires confirming again.
- **Mutation and saves.** Schedule mutations go through `AgentSessionDataService` with an expected `updatedAt` (stale edits are rejected) and an immediate save; pre-commit failure preserves the composer draft and attachments; post-commit index failure is still success plus index repair.

### 3.3 Dispatch

- **At-most-once attempt tracking (§6 P2).** Dispatch persists `state = .dispatching` with `Attempt(attemptID, itemID, startedAt)` and saves immediately **before** appending the optimistic user item, then appends the provenance-stamped item (deterministic `itemID`) and hands off. The `startAgentRun` outcome is the acceptance signal: `.sent` (and `.queuedFallback`, which is provider-durable) → set `lastScheduledDispatch`, clear `scheduledSend`, stamp `sentAt` on the item, save; `.failed` / `.stale` / `.cancelled` / `nil` → `state = .failed` retaining `itemID` and the message, and the unsent item is removed or marked undelivered, never labelled "Sent". No automatic retry; send-now on a failed record re-drives the same `itemID` rather than appending a second bubble. No provider-specific early-acknowledgement hook is required.
- **Restart with `.dispatching`:** if an item with `attempt.itemID` exists → `needsConfirmation(deliveryUnknown)` with an explicit duplicate-execution warning; if absent → plain `needsConfirmation(deliveryUnknown)`. A record whose `id` already appears as an item's provenance is dropped at hydration.
- **Input-source seam.** Add `enum UserTurnInputSource { case composer; case scheduled(AgentScheduledSendPersist, Attempt) }` to the prepared-turn path; the code before 13760 that derives `attachmentsToSend`, `taggedFilesToSend`, `activeWorkflow` and `interviewFirst` switches on it, and `.scheduled` neither reads nor clears composer pending state. `AgentChatItem.user(...)` gains `scheduledSend:` and an explicit `id:`. Dispatch bypasses the composer latch, always takes the idle `startAgentRun` branch (the gate guarantees idle), and must never enter steering, `pendingInstructions`, or the Codex fallback queue.
- **Entry point.** `dispatchScheduledSend(tabID:scheduleID:lease:) async -> ScheduledDispatchOutcome` (`accepted`, `deferredBusy`, `failedBeforeHandoff`, `unknownAfterHandoff`): revalidate id/state/gate → hydrate → check `canSendWithCurrentProvider` → persist `.dispatching` → submit with `.scheduled` source. `deferredBusy` returns to waiting; `failedBeforeHandoff` leaves the draft and attachments untouched.
- **Scheduled new session.** At schedule time, run the existing `createAndActivateSessionTab()` leg, name the session from the text via `AgentSessionTitleNaming`, install the record, save immediately and activate the tab, which shows an empty transcript plus the schedule banner. No greyed bubble is shown before dispatch. Explicit session deletion cancels the schedule and clears its attachments.

### 3.4 UI

- **Split control** (`ScheduleSendMenuButton`, in the trailing `HStack` of `AgentInputBar`): a clock-and-chevron `Menu` rendered after the primary button, joined to Send as a split button and detached beside Cancel. Enabled only when the draft or attachments are non-empty, `canSendWithCurrentProvider`, `renderedSubmitTarget != nil`, the tab is not latched, the session is local (§7 Q4), and no record exists (otherwise disabled with a tooltip that opens management). Items: 15 m, 30 m, 1 h, 2 h, 4 h each showing "→ 14:45"; "Custom…" opens a popover with a 15-minute stepper to 24 h, showing the resulting date-time and "tomorrow" when it crosses midnight; new-session targets add a "Run alongside other sessions" toggle.
- **Latch and results.** Reuse `latch.begin → claimSubmit`; add `actions.executeSchedule(claim, text, notBefore, runAlongside)` and `UserTurnSubmissionResult.scheduled(id:)`; `latch.complete` clears the draft for `.scheduled` only after the record is durably saved. Audit every `switch` over the result. `AgentComposerProps` gains `scheduledSend: AgentScheduledSendProps?` (status including derived waiting and the blocking session name) and `canSchedule`.
- **Banner** above the input: "Scheduled for 14:45 · waiting for run to finish" / "waiting since 14:00 · app closed"; actions Edit (in-place popover with text, time and removable attachment chips), Reschedule, Send now, Cancel; the needs-confirmation variant names the reason and offers Send now, Reschedule, Cancel, and the run-alongside override for new sessions. Before acknowledgement the state reads "Sending" or "Delivery unconfirmed", never "Sent".
- **Sidebar:** `SidebarSession.scheduledSendStatus` projects schedule and receipt from the identity-matched hydrated live session when present, including authoritative `nil`; otherwise it uses the index entry. Clock for pending, orange marker for needs-confirmation/failed/unreadable, dim clock for `lastScheduledDispatch`; add a "scheduled" search token. Collapsed-child scheduled attention aggregation, paged-out attention discovery, and a HUD badge remain deferred; the Phase 3 dashboard is the planned broader discovery surface.
- **Message marker:** caption under the user bubble, "Scheduled for 10:30 · Sent 14:34".
- **Dashboard:** `AgentScheduledMessagesViewModel` (`@MainActor ObservableObject`) opened as a sheet from a clock button with a count badge in the Agent sidebar header. Current-workspace rows are live coordinator projections with all actions and name the blocking session; all-workspaces rows come from index summaries, are read-only, and offer "Open workspace".

## 4. Phasing and tests

1. **P1 — accepted after R12 scoped remediation (see outcome above):** acceptance target remains the model, member wrapper, session fields, stub header, `TabSession` hydration/save, input-source seam, coordinator (follow-ups and new sessions with gates), composer control with quick picks, banner actions, needs-confirmation, `.dispatching` attempt tracking, and message marker. The scoped acceptance and deferred report-only limitations are recorded above.
   - `AgentScheduledSendPersistenceTests`: v1 round-trip; legacy JSON without the fields; stub header retains the fields; malformed member → unreadable and re-emitted unchanged; unknown state → `needsConfirmation`; provenance round-trips through `AgentTranscriptActivity`.
   - `AgentScheduledSendCoordinatorTests` (fake clock): not-before timing; own-session and workspace gates; override; `.waitingForUser` and non-empty `pendingInstructions` count as busy; simultaneous due items → ordered single new-session admission; sleep gap → `needsConfirmation`; already-awake-due follow-up survives sleep and dispatches only on captured run `.completed`, confirms on `.failed`/`.cancelled`; overdue at launch → confirmation; two hosts on one workspace → one lease; re-entrancy.
   - `AgentScheduledSendDispatchTests`: no item exists before dispatch; `.dispatching` is saved before the append; provenance stamped and record cleared on `.sent`; `.failed` outcome keeps `itemID` and never labels "Sent"; restart with `.dispatching` → confirmation with duplicate warning; restart with a due record performs zero submits; composer pending attachments untouched; attachment files not cleared before dispatch.
   - Latch tests gain the `.scheduled` case.
2. **P2 — implemented, validated, and accepted after fresh OracleA/OracleB R1 review:** index schema 7, sidebar badge and title/content guard, historical marker; tests for projection, rebuild, and live-versus-entry precedence. See the current Phase 2 implementation notes above.
3. **P3 — implemented, validated, and accepted after fresh OracleA/OracleB R2 review:** dashboard; tests for filtering, row actions, and a workspace-switch case that leaves, lets a record fall due, returns, and expects `needsConfirmation`. See the Phase 3 implementation and validation record above.
4. **P4 — planned:** custom picker polish and attachment editing.

Each phase validates with `make dev-lint`, `make dev-test FILTER=<Suite>`, `make dev-swift-build PRODUCT=RepoPrompt`, and `make guardrails`; the sleep/wake and lid-close paths need an approved live check of the debug app per the [validation workflow](../workflows/validation.md).

## 5. Ownership and placement

- Models: `Features/AgentMode/Models/AgentScheduledSend.swift`.
- Runtime: `Features/AgentMode/Runtime/Scheduling/AgentScheduledSendCoordinator.swift` (+ `SchedulerClock`), edits to `AgentSession.swift`, `AgentSessionDataService.swift`, `AgentSessionMetadataIndex.swift`, `AgentSessionDataCodec.swift` (member wrapper hook), `AgentChatModels.swift`, `AgentTranscriptModels.swift`.
- View models: `AgentModeViewModel{,+TabSession,+ComposerUI}.swift`, `AgentModeViewModel+ScheduledSend.swift`, `UI/AgentComposerUIModels.swift`, `AgentModeSidebarSessionBuilder.swift`, `AgentScheduledMessagesViewModel.swift`.
- Views: `AgentInputBar.swift` (control and banner), `AgentScheduledMessagesView.swift`, message bubble caption, sidebar row badge.
- Composition: `App/WindowState.swift` registers hosts with the coordinator (wiring only).
- Tests: `Tests/RepoPromptTests/AgentMode/AgentScheduledSend*Tests.swift`.

## 6. Material disagreements and resolution

| # | Point | Lane positions (anonymous) | Resolution |
|---|---|---|---|
| P1 | Coordinator ownership | App-wide coordinator with weak host registrations and metadata discovery vs. per-`AgentModeViewModel` coordinator over live `sessions`. | **Converged (round 1).** App-level arming, timer, busy aggregation and per-session admission leases; view models are weakly registered dispatch hosts; the index is a discovery hint revalidated against the hydrated record. Own verification: `AppDeepLinkRouter.swift:143` shows one workspace can be active in several windows, so the per-view-model design could double-dispatch. |
| P2 | At-most-once mechanism | Persisted `dispatching` attempt + provider-acceptance callback vs. synchronous clear-record + append-item + save with no dispatching state. | **Converged (round 1).** Persist the `.dispatching` attempt before the append; use the `startAgentRun` outcome as acceptance; a crash between append and handoff or a failed launch must never show "Sent"; failed records keep `itemID` for re-drive; no universal early-acknowledgement hook (Codex `turn/start`, Claude replay and ACP `session/prompt` differ and are not required). |
| P3 | Session serialization | Bump to v8 with byte-for-byte opaque preservation vs. keep v7 and document downgrade loss. | **Converged (round 1).** Keep v7 (own verification: `AgentSessionDataService.swift:525` never rejects newer versions, so a bump protects nothing and would lock rollback builds out of every session); bump the index schema to 7; add typed-or-unreadable member preservation so a malformed schedule neither breaks the session nor is silently dropped by a schedule-aware build; classify older-build resave as unsafe (§7 Q5). |
| P4 | Sleep while already due and waiting on busy | Blanket invalidation of arming on sleep/wake/restart vs. `observedDueAwake` records keep waiting through sleep. | **Converged (round 2).** Sleep-crossed or uncertain deadlines and all overdue-at-relaunch records need confirmation; an already-awake-due follow-up may survive sleep but dispatches only when its captured run is observed reaching `.completed` in-process (verified: `AgentSessionRunState` distinguishes completed/cancelled/failed), otherwise confirmation; a callback after wake does not prove an awake crossing; new sessions dispatch after an atomic check-and-reserve. The follow-up-after-failed-run confirmation is an accepted trade-off. |
| P5 | Busy set | `.waitingForUser` treated as idle (scheduled text would resume the parked run) vs. all instruction/question/approval waits busy plus cancellation and reservations. | **Converged (round 1).** `.waitingForUser` is busy because `submitPreparedUserTurn` would resume `instructionContinuation` with the scheduled text (14089–14104); non-empty `pendingInstructions`, unsettled cancellation and held reservations are busy; the dashboard names the blocking session and offers the override for new sessions. |

Minor points resolved by own judgment: send-now keeps the original `notBefore` for the marker and treats the record as confirmed with an effective due time of now; edits happen in place rather than pulling text back into the composer; other-workspace dashboard rows are read-only.

## 7. Provisional user decisions (questions timed out)

| Q | Question | Adopted default | Alternative |
|---|---|---|---|
| Q1 | Model/reasoning changed between schedule and send | Use the session's live selection at dispatch (single authority). | Freeze at schedule time; changing requires Edit. |
| Q2 | Already due, waiting on busy, then sleep or quit | The §3.2 rule: survive a sleep only when the captured run is observed completing; relaunch always confirms. | Always confirm after any sleep. |
| Q3 | Agent parked on ask_user / wait-for-instruction at due time | Busy; wait for the run to finish fully. | Deliver the scheduled text as the answer. |
| Q4 | Remote-host sessions in v1 | Excluded; control disabled when `session.remoteHost != nil`. | Required; adds gateway wire, host-side idle admission and correlation. |
| Q5 | Older build resaving a session with a pending schedule | Accept and document the loss; no version bump. | Bump the version so older builds refuse the file. |

## 8. Risks and follow-ups

- Attachment lifetime: confirm at implementation that no other path clears managed attachment files between schedule and dispatch.
- The stub header read (`loadAgentSessionStub`) and `listStub()` must carry the new fields or the sidebar badge disappears after an index rebuild, the same way `providerTokenUsageByTurn` was once lost.
- Empty-session cleanup and default-title logic must treat a pending schedule as content everywhere (`sessionIndexEntryHasConversationContent`, `sidebarTitle`, any restore-time pruning).
- Automatic subscription-reset scheduling stays a separate follow-up; the UI must describe delays only as "send at HH:MM", never as "after your limit resets".
- Provider-specific acceptance semantics (`.queuedFallback` for Codex) should be validated live before the historical marker is trusted for that provider.
