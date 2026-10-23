# Lossless app restart and one-click resume — technical spec

Scope: read when the task touches persistence of composer drafts or queued input (follow-ups, Claude/ACP steering, the Codex fallback queue), durable acknowledgement of sends, quit or window-close preservation, the surviving provider-process registry, interrupted-turn state, the recovery list, or Resume after an app restart.
Authority: Reference
Last-verified: 2026-10-18

Status: Phases 1/2 and Phase 3 process-registry source are committed; Step 4a same-ID saved-message routing, Step 4b late helper-stop recovery and Phase 5 edit/merge-review and child-link preservation are source-complete and reviewed. Step 4c explicit uncertain-exit policy is source-complete and reviewed. Full Phase 4 remains blocked on Claude canonical reconciliation and installed-profile qualification; Step 4d1 outbound identity is source-complete under O15; the O19 controlled capture resolved worker-context authentication and observed one real single-text-block reply with matching live/native identity; broader Claude reconciliation and installed-profile qualification remain unfinished. Production recovery activation and live acceptance remain pending (O3/O9/O10).
Step 4d2 — done | rounds 1/2 | open: none in bounded source only; A/B initial review on snapshot2026-10-23/2057, A R1(P1) repaired on delta2026-10-23/2130 and closed by A/B re-review1 with no P0/P1/P2 ([evidence](evidence/2026-10-18-lossless-app-restart/phase4-prerequisite-resolution.md)); not yet committed | downgraded: none | assumed: coupled reader and envelope proof before deduplication; exact observed nonrendering graph nodes, not semantic irrelevance | deferred: B P2-01 proofless-cursor requalification, initial P3-04/06/07 and re-review1 P3-1–4, next live single-text carrier step, live/profile qualification, production activation and live acceptance (O3)
Step 4d-capture — done | rounds 0/2 | open: none in bounded authentication diagnosis and one-text capture ([evidence](evidence/2026-10-18-lossless-app-restart/phase4d-claude-capture.md)) | downgraded: none | assumed: O19 child-local removal of inherited CLAUDE_CONFIG_DIR; one real text envelope only; documented safe-mode boundary allows built-in metadata | deferred: broader history/profile qualification, thinking/tools/multiblock/resume, production activation and live acceptance (O3); all4approved prompts consumed
Step 4d1 — done | rounds 0/2 | open: none in bounded outbound source; checkpoint85aecb82 (unsigned O8 fallback), A/B reviewed snapshot2026-10-23/1838 with no P0/P1, cheap P2 fixes validated on repair2026-10-23/1851 ([evidence](evidence/2026-10-18-lossless-app-restart/phase4-prerequisite-resolution.md)) | downgraded: none | assumed: UUID only on new qualified admission, omit on retry, complete ordered constituents, existing owner save; claim does not prove any bytes were sent | deferred: B P3-1/3/4, all-input-path qualification, owner-approved isolated Claude capture, canonical reconciliation, activation and live acceptance (O3)
Step 4c — done | rounds 1/2 | open: none in bounded source; checkpoint cb15d40f (unsigned O8 fallback), A/B accepted repair snapshot2026-10-23/1820-2 ([evidence](evidence/2026-10-18-lossless-app-restart/phase4-prerequisite-resolution.md)) | downgraded: none | assumed: owner-delegated explicit uncertain exit, current-request/attempt pre-arm proof, existing serialized helper ownership | deferred: B P3-1 and R1 nonblocking test/wording/ack precision, production activation and live acceptance (O3)
Step 4b — done | rounds 0/2 | open: none in bounded inactive source, checkpoint 8033b458 (unsigned fallback O8); A/B initial reviews accepted snapshot 2026-10-23/1204, cheap proof-label correction validated ([implementation and reviews](evidence/2026-10-18-lossless-app-restart/phase4b-helper-stop.md), [scope and planning](evidence/2026-10-18-lossless-app-restart/pre-live-work.md)) | downgraded: none | assumed: preserve existing explicit manual Retry deadlines; include Phase 5 preservation in remaining source work | deferred: B P2 app-modal loop and remaining coverage, P3 polish; unknown-stop policy, activation and live acceptance (O3)
Step 5a — done | rounds 1/2 | open: none in bounded source, checkpoint76057942 (unsigned O8 fallback); A/B R1 cleared repair snapshot2026-10-23/1514 ([evidence](evidence/2026-10-18-lossless-app-restart/phase5a-edit-reviews.md)) | downgraded: none | assumed: included by O13; historical View/Copy/Discard only, no recovered Apply; decoded-text base and canonical target; worktree reviews isolated in Step 5c | deferred: conservative reset-race uncertainty, worktree comparison/Open/UI fixtures, growth/viewer/naming/source-guard polish, release compile, retention and live acceptance (O3)
Step 5c — done | rounds 1/2 | open: none in bounded source; A/B R1 accepted repair2026-10-23/1656, cheap neutral-wording correction validated, checkpoint ce82ac6d (unsigned O8 fallback) ([evidence](evidence/2026-10-18-lossless-app-restart/phase5c-merge-reviews.md)) | downgraded: none | assumed: same pending-review contract, existing operation/artifact authority, historical View/Copy/Discard only | deferred: remaining initial B P3 and R1 presentation/hardening/coverage, optional polish, orphan retention cleanup and live acceptance (O3)
Step 5b — done | rounds 1/2 | open: none in bounded source, checkpoint 9e508587 (unsigned fallback O8); A/B R1 cleared snapshot 2026-10-23/1327 after identity-receipt retry, cheap wording correction validated ([evidence](evidence/2026-10-18-lossless-app-restart/phase5b-child-links.md)) | downgraded: none | assumed: included by O13; existing local MCP invocation ID and admission-bound parent attempt, not provider-native attribution | deferred: existing-tab/full-submission/Open fixture limits, independent caller retry deduplication, optional polish, retention and live acceptance (O3)
Step 4a — done | rounds 1/2 | open: none; bounded inactive source implemented, validated and cleared by required A/B re-review on snapshot 2026-10-23/0845 (O12: A/B only) ([evidence](evidence/2026-10-18-lossless-app-restart/phase4a-saved-relocation.md)) | downgraded: B P1-1 to P2 test gap, closed and accepted by issuing reviewer | assumed: preserve historical canonical identities with a distinct new execution turn; real covering write before normal dispatch; conservative supported-envelope refusal | deferred: unsupported historical shapes use Edit; B P2-1, frontier fixture P2-A and P3-1/2; actual cold-load/overlapping-writer qualification; all production activation, Claude native identity, automated Restart, optional polish, retention and live acceptance (O3)
Step 4 — blocked | rounds 2/2 | open: full Claude canonical merge and installed-profile qualification remain blocked; helper-policy source prerequisite is resolved by Step4c and outbound source by Step4d1; broader O15 Claude reconciliation awaits its remaining reader/ledger/live-envelope work and supported-profile evidence; O19 resolved capture authentication by removing only the child configuration override and observed a real one-text reply, without broader qualification ([evidence](evidence/2026-10-18-lossless-app-restart/phase4-prerequisite-resolution.md)); older saved-message canonical routing source is completed by bounded Step 4a, with activation and live qualification still pending; both final reviews accept O9's inactive partial checkpoint on source tree 5f9151eb ([planning evidence](evidence/2026-10-18-lossless-app-restart/phase4-plan.md), [implementation evidence](evidence/2026-10-18-lossless-app-restart/phase4.md), [O10 source investigations](evidence/2026-10-18-lossless-app-restart/phase4-source-investigations.md)) | downgraded: none | assumed: one coupled source package; bounded Claude history baselines plus typed refusal, full canonical merge pending explicit new-baseline identity and profile-local payload-safe reconciliation; normal dispatch and history-only import; existing bundled helper private mode instead of a new product; production Resume/restart gated on qualified registry/provider behavior | deferred: live qualification; B R2-P2-1–4 and prior P2/P3 in final review evidence; optional polish, retention and live acceptance (O3)
Step 3 — done | rounds 2/2 | open: none; signed checkpoint 559ecd9d, source reviewed on tree c25b94f0; enforcement and live qualification remain pending ([planning evidence](evidence/2026-10-18-lossless-app-restart/phase3-registry-plan.md), [implementation evidence](evidence/2026-10-18-lossless-app-restart/phase3-registry.md)) | downgraded: none | assumed: one coupled worker; production activation off until family discovery is qualified; ACP generic registration included; temporary shell fixtures for CLI runner boundary tests | deferred: activation/live qualification; A P3-R13; B R2-A–D, retirement timeout and EOF-line association (see final review evidence); prior P2/P3; recovered-process signalling, fresh Claude session-ID activation, retention and live acceptance (O3)
Step 2 — done | rounds 2/2 | open: none; signed checkpoint 93af6fb5 ([planning evidence](evidence/2026-10-18-lossless-app-restart/phase2-plan.md), [implementation and reviews](evidence/2026-10-18-lossless-app-restart/phase2.md)) | downgraded: none | assumed: post-cap bounded fix validated without re-review after owner question timed out; immediate question creation writes, non-secret drafts 300 ms debounce/2 s maximum; Dismiss acknowledges cards only | deferred: optional polish/retention and documented P2/P3 limits; unknown-turn provider cleanup; Resume and registry to later phases; UI/live acceptance (O3)
Step 3-platform — done | rounds 1/2 | open: none; implementation, validation and reviews complete ([evidence](evidence/2026-10-18-lossless-app-restart/phase3-platform.md)) | downgraded: none | assumed: independent Platform primitives before registry integration | deferred: production registry, provider integration and live qualification
Step 1b-shutdown — done | rounds 2/2 | open: none; signed checkpoint 57e45120; implementation, required fixes and validation complete ([evidence](evidence/2026-10-18-lossless-app-restart/phase1b-shutdown.md)) | downgraded: none | assumed: sealed window admission; delayed clean acknowledgement is not invalid preservation; bounded post-R2 fixes validated without another review | deferred: optional polish, retired-lane removal retry and live acceptance (O3)
Step 1b-cutover — done | rounds 3/3 (O7) | open: none; signed checkpoint c9138767; final fence fix validated ([evidence](evidence/2026-10-18-lossless-app-restart/phase1b-cutover.md)) | downgraded: retention cost and instruction-wait extra confirmations P2, accepted by issuing reviewer | assumed: bounded final fix validated without a fourth review | deferred: optional polish, record retirement and history-dependent startup/per-commit cost; uncertain wait replies may delay workspace schedules until closed sessions are opened and confirmed; Phase 2 durable dismissal; live acceptance (O3)
Step 1b-recovery — done | rounds 2/2 | open: none; integrated signed checkpoint c9138767 ([evidence](evidence/2026-10-18-lossless-app-restart/phase1b-recovery.md)) | downgraded: none | assumed: final-domain storage/controller activated with the coupled production cutover | deferred: complete quit/window-close preservation; live acceptance (O3)
Step 1b-foundation — done | rounds 2/2 | open: none; integrated signed checkpoint c9138767 ([evidence](evidence/2026-10-18-lossless-app-restart/phase1b-foundation.md)) | downgraded: none | assumed: focused validated fix after review cap (owner question unanswered); durable lifecycle, exclusive creation and permanent UUID tombstones ([scope evidence](evidence/2026-10-18-lossless-app-restart/phase1-scope.md)) | deferred: complete quit/window-close preservation; live acceptance (O3)
Step 1a — done | rounds 2/2 | open: none; committed as ebd686f7 ([evidence](evidence/2026-10-18-lossless-app-restart/phase1a.md)) | downgraded: none | assumed: transcript-only scheduling/draining; embedded lifecycle identity for 1b ([scope evidence](evidence/2026-10-18-lossless-app-restart/phase1-scope.md)) | deferred: complete quit/window-close preservation to the next package; live acceptance (O3)
Step 0 — done | rounds 0/2 | open: none | downgraded: none | assumed: none | deferred: live sampling, isolated main-actor timing, quit-time loss observation, real-app crash testing (O3), and minor items in [evidence and reviews](evidence/2026-10-18-lossless-app-restart/phase0.md)
- **How it was drafted:** OracleD and OracleE each wrote an independent plan, and this spec merges them. It includes one review round from each Oracle; every P0, P1, and P2 finding is resolved below. Identity was verified for each send.
- **Evidence:** code reading, plus crash experiments that ran the real provider CLIs under a throwaway parent process. RepoPrompt itself was not killed.
- **Code:** none exists for this feature yet.

## Goal

The owner's daily harness is RepoPrompt CE on an always-on Mac Studio. The most common restart is the app itself: a debug rebuild, a crash, or a relaunch to clear sluggishness. When RepoPrompt restarts:
- nothing the user typed, or was told was queued, is lost;
- interrupted work is shown honestly;
- nothing is sent or re-run without a click;
- an interrupted turn resumes with one click once that's safe.

**What it promises:**
- Saved input survives an app restart.
- Interrupted work stays visible.
- RepoPrompt never replays tool calls itself.
- Safely recoverable Claude and Codex work continues with one action.

**What it doesn't promise:**
- Typing from the last moments before a crash.
- Provider output that neither RepoPrompt nor the provider recorded.
- Exactly-once side effects. A resumed model may still choose to repeat an action itself.

## Done when

1. Every message RepoPrompt sends or reports as queued survives an immediate app kill. That covers composer sends, follow-ups, steering, fallback, scheduled sends, and MCP calls. What survives is its text, attachments, origin, order, and a stable ID, together with whether it reached the provider.
2. After a normal quit or Restart safely, each session's latest composer state (text, images, tagged files, workflow) and every queued message are restored exactly. After a crash, at most the last 2 seconds of composer changes are lost. On healthy storage the usual window is about 300 ms.
3. A turn that was running when the app stopped is shown as **interrupted**, with its reason (crash, quit, window close, restart). It is not shown as a user cancel.
4. Relaunch never sends, drains, or resumes anything automatically. Every recovered item waits for a click. Future scheduled sends keep their existing rules (R9).
5. RepoPrompt never starts a second managed writer on a provider conversation while that conversation's previous owner process is alive or unknown. Until the process registry ships (Phase 3), sessions interrupted by a crash require an explicit "the previous run may still be running" confirmation before any send.
6. An eligible Claude or Codex interruption resumes with one click, with no copying the prompt and no re-picking the conversation. If the provider verifiably finished the turn while RepoPrompt was down, that result is imported and shown without starting another turn.
7. Recovery items are stored as data that a future remote UI can render. They stay discoverable when their tab or window is closed.
8. A quit finishes within one 8-second deadline. A failure before teardown cancels the quit and leaves the app fully usable. A failure after teardown offers Retry or Quit anyway, and is recorded so the next launch treats the affected sessions as uncertain.
9. Existing scheduled-send deadline and confirmation rules are unchanged.

## Crash contract

The guarantee covers an **app-process crash or kill** while macOS keeps running. A completed atomic file replacement is the commit point.

Out of scope:
- power-loss durability (`F_FULLFSYNC`);
- a database migration, a cloud store, and a background execution daemon.

The owner's Mac runs on battery backup, and app restarts are far more common than power loss.

**Compatibility limit.** Session serialization stays at version 7. That gives decoding compatibility only: an older build ignores the recovery records and their fences, and may resave a session without them. Before downgrading, quit cleanly and resolve recovery items.

## Evidence

### Code (verified 2026-10-18)

| Fact | Where |
|---|---|
| These live only in memory: drafts, queued follow-ups, Claude and ACP steering queues, the Codex fallback queue, pending image and tagged-file attachments, and pending edit reviews | `AgentTabSession.swift:213, 341, 390, 440, 689, 743, 755-756`. `AgentSession.swift` has no field for any of them. The persisted session built at `AgentModeViewModel.swift:14478-14515` omits them. `storeDraftText` (`AgentModeViewModel+DraftsAttachments.swift:28`) writes to memory only. |
| **Bug:** a Codex fallback instruction is reported `durablyQueued` but never saved | `enqueueCodexFallback` (`CodexAgentModeCoordinator.swift:2240-2302`) appends to the in-memory queue and resolves the MCP ack as `.durablyQueued`. It then only schedules a save, and that save doesn't contain the queue. `AgentModeViewModel.swift:16422` maps `.queuedFallback` to `.durablyQueued`, and `CodexSteerAckTracker.swift:40-47` treats it as confirmed. A scheduled send that falls back clears its own pending record on that acceptance. A crash before the queue drains therefore loses the message, with no copy anywhere. |
| Quit and window close discard queued input and don't flush saves | `prepareSessionForWindowClose` (`AgentModeViewModel.swift:3796-3830`) calls `cancelPendingInstruction`, cancels the run, and disposes providers. There is no `flushSaveDetailed` call anywhere in the close or quit path (`AppDelegate.swift:256-277`, `WindowStateManager.swift:953-967`). Saves are 1-second debounced tasks (`AgentModeViewModel.swift:14074-14096`), so the terminal state written at quit is probably lost too. That last point is an inference that Phase 0 validates. |
| Teardown is irreversible once it starts | `beginTermination` runs `signalTermination`, the termination fast path, and `MCPBackgroundModeCoordinator.resetForTermination` synchronously (`AppDelegate.swift:257-264`). `signalTermination` sets `isTerminating` and cancels subscriptions to prevent SwiftUI observation crashes, and nothing resets it (`WindowStateManager.swift:912-922`). `prepareForWindowClose` then sets `hasPreparedForWindowClose`, unregisters observers, detaches the scheduler, and stops coordinators (`AgentModeViewModel.swift:3756-3795`). Window layout is persisted after those signals but before agent shutdown (`AppDelegate.swift:266-276`). |
| The save debounce has no maximum wait | `scheduleSave` cancels and restarts its 1-second timer on every call (`AgentModeViewModel.swift:14092-14096`). Assistant text deltas are buffered for 250 ms (`enqueueAssistantDelta`, `:18923`) and don't call `scheduleSave` directly. There are 112 call sites across 17 files, so whether a busy session can go unsaved for a long time is **unverified**. Existing counters: `save.schedule.replaced` (`:14088`) and `save.session.invoked` (`:14194`). |
| Cold restore can't tell an interruption from a cancel | `AgentSessionRestoreSupport.swift:61-122` turns active run states into `.idle` and open turns into `.cancelled`. |
| Quit already warns about active work | `AppDelegate.swift:161-180`, gated by the warn-before-quit setting. |
| Scheduled sends already model durable intent | `docs/context/agent-scheduled-messages.md`: a `dispatching` attempt is written before handoff; an uncertain restart becomes `needsConfirmation(deliveryUnknown)`; nothing is auto-sent after a closed-app deadline; an unaccepted optimistic item is never marked Sent. |
| Provider processes start in their own process group | `ProcessLauncher.swift:228-267`: `setpgroup 0`, SIGPIPE default, close-on-exec default, stdio pipes. Claude runs as `claude -p --verbose --output-format stream-json --input-format stream-json --permission-prompt-tool stdio [--resume id]` (`ClaudeNativeProcessSessionController.swift:3220-3236`). Codex runs as `codex app-server`. Nothing records spawned processes across launches. |
| Large sessions are expensive to serialize | The transcript-refresh performance spec measured a running session of about 1,500 source items (`2026-10-12-agent-mode-transcript-refresh-performance-spec.md`). |

### Crash experiments (2026-10-18)

A throwaway Python parent launched each process exactly as `ProcessLauncher` does, then was killed with `kill -9` mid-turn. The real CLIs ran through the owner's shims, the same chain RepoPrompt uses:
- a Node `claude-rotator` shim that launches the real `claude`;
- a Node `codex-auth-switcher` shim that launches `codex`.

The environment matched RepoPrompt's. In particular, `CLAUDE_CONFIG_DIR` must be unset, or the shim skips its login.

| Case | Result after the parent died |
|---|---|
| A silent shell command | Kept running (reparented to launchd) and finished |
| A command printing to stdout | Died on its next write (broken pipe) |
| A provider-like process with a background child | The writer died; the child survived and finished |
| A process blocked on stdin | Saw end-of-input and kept going |
| **Claude 2.1.302** | **Kept working.** It finished the running 20-second foreground command. 19 s after the kill it ran a **new** command (`touch m2`), wrote its final answer, and exited. Its session JSONL recorded every step. In another run it waited for a backgrounded task, made another model request, answered, and exited. |
| **Codex 0.162 app-server** | **Stopped cleanly.** It exited within 3 s and stopped its running command, so neither marker file was created. Its rollout recorded `turn_aborted` with reason `interrupted`, plus a note telling the model the turn was cut off. |

Both providers ran their tool commands in a **process group separate from their own**: Claude was in group 40019 and its tool shell in group 40328. Signalling the provider's group doesn't reach its tools.

Claude's session JSONL was found at `~/.claude/projects/<cwd>/<sessionID>.jsonl`, even though the shim selects a profile under `~/.claude-rotator/profiles/`. The JSONL root is therefore not simply the selected profile directory (R6).

**Not yet tested:**
- Claude with an unanswered stdio permission request.
- Claude calling a RepoPrompt MCP tool when RepoPrompt dies. That server lives inside the app, so the call would fail.
- Claude startup hooks.
- ACP and Oh My Pi providers.
- A real kill of the RepoPrompt app (see O3).

## Decisions

Where a decision chose between the two plans, it records why the alternative lost.

### R1. Where state lives: one small recovery record per session, next to the transcript

| Data | Authority |
|---|---|
| Transcript and existing session settings, plus a new optional turn-level `interruption` record (R5) | The existing `AgentSession` JSON, serialization version 7, unchanged |
| Pending schedules | The existing `AgentScheduledSendPersist` record |
| Composer snapshot; every sent or queued message ("intent") and its dispatch evidence; run-attempt records; pending-question snapshots; recovery decisions | **New** per-session recovery record, `…/RepoPrompt CE/AgentRecovery/v1/sessions/<sessionID>.json` |
| Provider process ownership | **New** runtime records, `…/AgentRecovery/v1/runtimes/<runtimeID>.json` |
| Launch instance and clean-exit mark | **New** `…/AgentRecovery/v1/launch-state.json` |
| File checkpoints | The checkpoint spec's private store |

- Paths come from the app's existing Application Support resolver; there is no new hard-coded root.
- One app-scoped `AgentRecoveryStore` actor is the only writer. It does atomic replacement, revision checks, idempotency, and tombstones.
  - Revision checks use an opaque revision token, as `scheduledSend.updatedAt` does.
  - It takes and returns immutable `Sendable` values, never `AgentTabSession` or controllers.
- **Why a separate record** (OracleE's choice over OracleD's new session-JSON fields):
  1. An acknowledgement shouldn't wait on re-serializing a large transcript on the main actor.
  2. Composer state changes on every keystroke.
  3. The record must stay writable during teardown, independently of view-model debounce tasks.

  OracleD's atomicity concern is handled two ways: the reconciliation rules in R1a, and the receipt transfer in R9. The scheduled-send clear still needs a session save, so that route keeps the transcript-write cost.
- **Schema and corruption handling.** `schemaVersion: 1`, using the typed-or-unreadable pattern from scheduled sends.
  - An unknown version keeps the original file, which is never executed or overwritten.
  - Unknown members are preserved.
  - A corrupt file is kept and shown as "recovery status unknown".
  - A missing record for a legacy idle session means "nothing pending". A missing record that a summary or runtime record refers to is an error, not an empty queue.
- **Contents.**
  - `composer`: one `composerRevision` covering text, managed image references, tagged-file references, workflow, and `interviewFirst`.
  - `intents`: every message (R2).
  - `attempts`: run-attempt identity, dispatch and terminal evidence, and a shutdown or close reason when known.
  - `questions`: pending `ask_user`, user-input, and elicitation snapshots, each with any partial answer.
  - `recoveryDecisions`.
- **Ownership and lifecycle.**
  - Each record stores the session's existing durable incarnation (its reset/delete generation) in canonical serialized form. Implementation first locates that authority in `AgentSessionDataService`; no new counter is invented.
  - Reset keeps unsent intents as held "from the previous conversation" input and never retargets them.
  - Delete writes a tombstone before cleanup; late writes then fail the generation or tombstone check.
  - A record is deleted once it holds no unresolved items, which keeps the launch scan small.
- **A durable session stub exists before the first intent.** A new session's first send writes its normal session file first, so a recovery record never points at a session that exists only in memory.
- **Attachments.** Images must already be in managed storage before a message is acknowledged. The attachment cleanup's reference set grows to cover composer snapshots, intents, and held items.
- **Metadata index.** Schema goes from 7 to 8 and adds a bounded recovery hint: state, reason, unsent count, and whether a draft exists. It is a discovery hint only; recovery discovery scans its own records.

### R1a. Reconciling the two files after a crash

The recovery record can be newer than the session JSON, or exist before any saved turn.

- **Join keys.** Session incarnation, intent ID, the deterministic user-item ID carried by the intent, run-attempt ID, and transcript turn.
- **An intent without acceptance evidence** shows its user bubble as "not sent", using the deterministic item ID; it is never shown as Sent. *Send* reuses that item ID, so it never appends a second bubble. This is the scheduled-send rule.
- **An intent with acceptance evidence but no saved bubble** gets its bubble restored from the intent.
- **An attempt with terminal evidence while the saved transcript still shows the turn open** displays as "completed; transcript tail may be missing", not "interrupted". In Phase 4, the provider-history import fills the tail.
- **An attempt that exists only in the recovery record** (a crash before the first transcript save) is still discoverable and gets an interrupted card.
- **Cold restore prefers per-attempt evidence** (an attempt's recorded quit or close reason) over the global launch mark. A missing clean mark proves only an unclean exit, not its cause.

### R2. Durable acknowledgement for every send

- **Rule.** Every provider handoff, direct or queued, first commits the message as an intent together with a `dispatching` attempt, in one record write. RepoPrompt may report a message as **queued** only after its intent is committed, and as **accepted** only on affirmative provider acceptance.
  - This covers first prompts and direct follow-ups as well as queues, so a crash just after Send never loses the message.
  - A crash during `dispatching` becomes `deliveryUnknown`.
- **Intent delivery states.**

  | State | Meaning |
  |---|---|
  | `queued` | Saved; no handoff has begun |
  | `dispatching` | Handoff may have happened |
  | `providerAccepted` | The provider acknowledged it (not "completed") |
  | `deliveryUnknown` | Sending again might duplicate it |
  | `failed` | Verified rejection or pre-handoff failure; the payload is kept |
  | `withdrawn` | The user removed it explicitly |

- **Holds.** A hold blocks automatic draining without changing delivery state. Hold reasons are `staleTarget`, `missingAttachment`, and `previousInstance`. The last is **derived** by comparing the record's app-instance ID with the current launch, never written at relaunch, so a crash before that write can't leave an unheld queue.
- **Outcomes by boundary.**
  - The intent commit fails: the caller gets `.failed`, the optimistic row is removed, and the composer is restored.
  - The intent commits, but the target run ends during the suspension: the caller gets `.stale`, not "queued". The committed intent stays as held input under the same ID.
  - Handoff may have happened, but recording acceptance fails: the payload is kept as `deliveryUnknown`. RepoPrompt doesn't claim rejection and doesn't restore a retryable draft.
- **Codex fix** (OracleE's design).
  - `enqueueCodexFallback` becomes `async`. It reserves the queue ID so concurrent callers join one operation, then commits the intent and revalidates the session and target after the suspension. Only then does it project the entry into the live queue and resolve the MCP acknowledgement.
  - `NativeSendOutcome.queuedFallback` and `CodexSteerAckTracker.TerminalState.durablyQueued` carry the store-issued receipt. Neither acknowledgement producer can then report success without persistence evidence. Both producers land together.
  - `CodexFallbackQueueEntry` is not made `Codable`, because its controller identities mean nothing after a restart. Its `id` becomes the intent ID.
- **Other queues.**
  - `pendingInstructions: [String]` becomes identifiable values carrying intent IDs, and the Claude and ACP steering projections get the same association.
  - Every site that reports "queued" or "instruction delivered" must hold a receipt first. Inventorying those sites is Phase 0 work.
  - On lifecycle shutdown, the "preserve" disposition still fails any waiting MCP `instructionContinuation`, because a continuation can't survive a restart.
- **After a restart.** Recovered intents become **held recovered input** and never return to live queues, because their run and controller targets no longer exist. For MCP callers, "durably queued" therefore means the message survives a restart as a visible item that needs one click. That is the same rule as closed-app scheduled sends.
- **Composer writes.**
  - Any change to text, images, tagged files, or workflow advances `composerRevision`.
  - Writes are coalesced with a 300 ms debounce and a **2-second maximum delay** from the first unsaved change. They also happen on tab switch and at shutdown.
  - A write failure is shown in the composer. There is no permanent Saving/Saved indicator.
  - On send, the composer clears optimistically, as it does today. The intent commit also records the composer snapshot's removal. On commit failure the composer is restored, keeping any typing that happened meanwhile.

### R3. Transcript saves get a maximum wait

- **Keep the 1-second debounce, and add a 10-second maximum delay.** The clock starts at the canonical transcript mutation point: the session's dirty mark or a source-items revision change, not only `scheduleSave` callers. It resets only when a save commits.
- **Drain buffered assistant text before cleanup.** It is applied before any destructive cleanup and before every final snapshot, so teardown never discards text still in the 250 ms buffer.
- **Send-path state goes to the small recovery record.** Run-attempt start, dispatch, and terminal evidence are written there, not through forced whole-session saves.
- **Phase 0 measurements:**
  - whether a busy session goes unsaved, using `save.schedule.replaced`, `save.session.invoked`, and a new `save.session.written` counter that records successful saves, on a long text-only stream;
  - the main-actor cost of serializing a large session, since a 10-second maximum delay re-serializes it periodically.

  The maximum wait ships either way; its interval is tuned from the measured cost.

### R4. Quit, window close, and Restart safely

Quit uses one absolute 8-second deadline covering all windows, with sessions handled concurrently. It runs in two stages, separated by a point of no return.

**Stage A — reversible.** Any failure here cancels the quit and leaves the app fully usable.
1. Persist window layout before any agent shutdown, as today (`AppDelegate.swift:266-270`).
2. Freeze admission synchronously, before the first `await`. That covers manual starts, the scheduler, queue pumps, and MCP starts.
3. Commit composer snapshots, held queues, question snapshots, and each active attempt's shutdown reason to the recovery records. Mark the launch state as "shutdown in progress".
4. Flush every dirty, fully hydrated session. A session whose load never finished is skipped, so a partial in-memory state never overwrites its file; implementation names the existing load and save-commit guard that enforces this.

If any step fails or times out, admission unfreezes and the user sees the affected sessions with Retry and Cancel quit. Nothing irreversible has happened yet.

**Point of no return.** Only now do `signalTermination`, the termination fast path, the background-mode reset, and `prepareForWindowClose` run. Those steps currently run first in `beginTermination` (`AppDelegate.swift:262-264`); they move after Stage A.

Moving `signalTermination` later means Stage A runs while SwiftUI observation is still live. That is the normal running state, so it should be safe, but implementation must confirm that no Stage A step triggers the shutdown-time observation crashes the flag guards against. If one does, add a separate, reversible "quit pending" flag for Stage A rather than setting `isTerminating` early.

**Stage B — teardown.**
1. Stop runtimes with the existing teardown, using the *preserve* disposition (R2).
2. Flush sessions dirtied by the terminal commits.
3. On success, mark the launch state clean and exit. If a flush fails or the deadline passes, offer only Retry flush or Quit anyway. The launch state stays unclean, so the next launch treats those sessions as uncertain. Cancel quit is not offered here, because the view models are already torn down.

- **Non-cooperative tasks.** The deadline must not hang on one. Such tasks are owned explicitly, and late results fail ownership checks.
- **Unanswered quit.** At logout, macOS kills an app that doesn't answer the quit request, and 8 seconds is inside that allowance.

**Window close** uses the same two stages for that window only. Preserve-versus-withdraw lives inside `prepareSessionForWindowClose`, which window close and quit share, not in `AppDelegate`. A window close records its reason on that window's attempts and **never** marks the launch clean; only app termination does that.

**Preserve versus withdraw.** `cancelPendingInstruction`, the steering cleanups, and the fallback cleanups get an explicit disposition:
- *preserve* on lifecycle shutdown;
- *withdraw* only when the user explicitly cancels the item.

**Quit confirmation.** The wording changes from "will terminate" to "will be interrupted; you can resume after relaunch". Unsent items and drafts are listed for information only.

**Restart safely** (Phase 4) is a menu command that runs the same pipeline with reason `safeRestart`.
- A short-lived helper then waits for the old process to exit and opens the bundle. The helper does no agent work.
- It fails visibly unless state is committed and every managed process is verifiably stopped.
- Deferred to Phase 5 as an experiment: OracleD's option to detach Claude instead of stopping it. The orphan would lose RepoPrompt's MCP tools and its permission channel.

### R5. Honest interruption

`AgentTranscriptTurn` gains an optional `interruption` record:

| Field | Values |
|---|---|
| `reason` | `appCrash`, `appQuit`, `windowClose`, `safeRestart`, `providerProcessLost`, `unknown` |
| Times | `observedAt` and `lastConfirmedActivityAt` |
| Identity | `runAttemptID` and the provider conversation identity |
| Optional context | a pending-question summary and a runtime reference |
| `resolution` | `importedCompleted`, `resumed`, `dismissed` |

`terminalState` stays `.cancelled`, so every existing switch and v7 reader keeps working. Both Oracles rejected adding an `.interrupted` case to `AgentSessionRunState`: it would ripple through every exhaustive switch and through the index and sidebar projections.

**When it is written:**
- On cold restore, before open spans are sanitized. The reason comes from per-attempt evidence first (R1a), then from the launch state.
- From the runner's existing provider-loss path, with `providerProcessLost`.

Phase 1 records shutdown reasons only in the recovery record's attempts. Phase 2 projects them into this turn-level record.

**Display:**
- The sanitizer's inferred `completedAt` is never presented as a real provider completion.
- The UI distinguishes six states: interrupted; provider still running; ready to resume; completed while RepoPrompt was closed; cancelled by you; status unknown.
- An action interrupted mid-way (decision `continueRequested` with no outcome) shows "Resume was interrupted; status unknown". Resume is offered again but never retried automatically.

### R6. Surviving-process registry

**Owner.** `AgentProcessRegistry`, an app-scoped AgentCore actor. OS inspection lives in a new Platform helper, `ProcessInspection.swift`, which wraps `proc_pidinfo`, `proc_pidpath`, `sysctl(KERN_PROCARGS2)`, and `getpgid`, and imports no session types.

**Runtime record.** It describes a process lifetime, not a turn, and holds:
- runtime ID and owning app-instance ID;
- provider kind and provider home (below);
- root PID, process group, and birth identity;
- the observed shim-to-CLI chain;
- the sessions, run attempts, and native conversation IDs it serves. A Codex app-server can serve several threads; whether today's controller shares one isn't claimed;
- worktree bindings and permission mode;
- observed descendants;
- state: `reserved`, `live`, `exited`, `stopped`, `detachedAtQuit`, or `unknown`.

Full environments and command lines are never persisted.

**Process identity** is the combination of boot session, PID, start time (seconds and microseconds), and UID. Executable path and process group are supporting evidence. Any mismatch means `exited`. A changed boot session proves the process is gone.

**Marker.** `ProcessLauncher` gains an optional environment marker, `RPCE_RUNTIME_ID=<runtimeID>`, inherited by the shim, the CLI, and its tools. The name avoids `KEY`, `TOKEN`, and `SECRET`, which Codex's default `shell_environment_policy` strips from tool environments. Propagation through both shims, Claude's Bash tool, and Codex's sandboxed commands is a live validation gate.

**Registration order.** This replaces both original proposals. OracleE showed that the "never given work" rationale fails, because Claude can run startup hooks before its first message.
1. Commit a small `reserved` record (runtime ID, session, marker) **before spawn**.
2. Spawn.
3. Fill in the birth identity and mark the record `live` before the first user message.

If the reservation write fails, the run aborts visibly; RepoPrompt never sends work to an unregistered process. A crash between spawn and step 3 leaves a `reserved` record. Discovery then finds the process by its marker and keeps ownership unresolved. A suspended launch isn't needed.

**Provider home.** RepoPrompt can't pass `CLAUDE_CONFIG_DIR` through the rotator shim, so it learns the home in two ways:
- at registration and at discovery, by reading the real `claude` descendant's `CLAUDE_CONFIG_DIR` through `KERN_PROCARGS2`. Only that one value is kept;
- for history import, by finding `<sessionID>.jsonl` across the known Claude config roots, including `~/.claude/projects`. Session IDs are UUIDs, so the match is unambiguous.

**Claude session IDs are preallocated in Phase 3** with `--session-id`, gated on a compatibility check of 2.1.302 through the shim. They are never combined with `--resume`. The runtime record then has the conversation ID before any output arrives. Until then, a live runtime bound to a session blocks Resume on that session even if its conversation ID is unknown.

**Discovery** runs at launch, before Stop, before Resume, and when an exit event fires.
- It takes one same-UID process inventory, follows parent links from registered roots, and matches the marker. That also finds tools reparented to launchd and tools in separate process groups.
- No continuous polling. OracleE proposed polling once per second, but the owner's CPU and main-thread budget matter.
- `kqueue` `NOTE_EXIT` watches **every** identified live writer, launcher, and blocking tool, not just the root, and each exit triggers rediscovery. A Refresh action covers missed events.
- Denied or incomplete inspection means `unknown`, never `exited`.

**Launch-time UI.** Processes left by the previous instance appear as recovery items. Each shows provider, session, worktree, elapsed time, permission mode, and its discovered descendants. The actions are:
- **Let finish** (default): record the choice and keep watching.
- **Stop**: show the processes about to be signalled. Revalidate identity immediately before each signal, then send SIGTERM to every verified process group. Wait 3 seconds and escalate to SIGKILL. Finally, run a fresh family discovery to verify.

Processes are never signalled by name. `EPERM` or an identity mismatch leaves the item unresolved. Nothing is killed automatically (O1).

**Two-writer rule.** RepoPrompt refuses another managed writer for a conversation while any of its recorded writers or launcher shims is alive, reserved, or unverifiable. The conversation key is provider kind, provider home, and native conversation ID.
- **Tool-only survivors** (for example, a dev server Claude started) are not conversation writers. They don't block same-conversation Resume, but they keep the worktree busy for automatic work and set the checkpoint spec's `unresolvedPriorExecution` flag. Resuming while one is alive needs a confirmation that lists it.
- **Unverifiable ownership** disables same-conversation Resume. The card offers Stop. "Continue in a new conversation" (the existing handoff) is also offered, but it needs Stop or an explicit confirmation, because a live orphan could still edit the same worktree. There is no force override.

**Remote-host sessions** have no local process. Composer snapshots and intents apply to them; the registry and Resume don't.

### R7. One-click Resume

`AgentRecoveryCoordinator` (main actor) runs each Resume as one reserved action, keyed by recovery-item ID, expected revision, and action ID. Repeated clicks join the same action.

1. Persist the decision. Then validate session ownership, provider identity, worktree binding, and the R6 fences.
2. Reconcile the provider's own history (below). Persist imported transcript rows before advancing the history cursor; a crash between the two causes only a harmless re-import.
3. If verified terminal evidence shows the interrupted turn finished, display the result and stop without sending anything.
4. If the original message was never handed off, the action becomes **Send saved message**, which sends the saved payload under its existing item ID.
5. Otherwise:
   - create one continuation intent and a new run attempt;
   - obtain the shared pre-dispatch permit, which includes the checkpoint spec's fresh start capture;
   - dispatch once through the normal start path.

   The continuation text is shown in the card and can be edited. Default: "RepoPrompt restarted during the previous turn. Check the current state before repeating any action, then continue."

Other held follow-ups stay visible and are **not** bundled into the continuation (OracleE). OracleD proposed joining them, but silent bundling changes what they mean.

**Claude:**
- **History import.** A read-only adapter reads only the exact session JSONL, located as in R6. It parses complete lines only and deduplicates by native message, tool-use, and parent IDs. It stores the file identity and the byte offset of the last complete line, and rescans after a replacement or truncation. Rows are imported through a history-only path that cannot invoke tools, approvals, or old continuations, and they are labelled "recovered".
- **Completion test.** The test is stricter than "the last message ended its turn". A Stop hook can continue after an assistant response, and accepted steering separates a response from the attempt. A turn therefore counts as finished only with version-validated terminal evidence bound to the interrupted request. Without it, the card says "Last answer recovered; completion unconfirmed" and keeps Continue.
- **Continuing.** Start a new process with the existing `--resume <id>`, recreating current MCP endpoints and permission routing.
- **Open behavior.** How `--resume` treats a dangling `tool_use` must be tested live. If it refuses, fall back to "Continue in a new conversation".

**Codex:**
- Reuse the existing thread and turn reconciliation in the Codex controller; don't write a parallel reader.
- Read with the observational APIs. Once ownership is safe and the user has clicked, run `thread/resume` and then a new `turn/start`.
- Record the native `turn_aborted interrupted` evidence on the turn. Codex has already told the model about the interruption, so the continuation text is optional.
- Pin the adapter to the tested app-server schema.

**ACP and Oh My Pi.** Input and interruption data are preserved from Phase 1. Recovery stays context-only (the existing handoff) until each provider's transport-loss, history, and resume behavior has been tested live.

### R8. The recovery list is data

**Catalog.** `AgentRecoveryCatalog` is app-scoped, like the scheduled-send coordinator. It derives items from:
- recovery records;
- runtime records;
- the metadata-index hint, for sessions that aren't hydrated;
- scheduled sends in `needsConfirmation`.

Each item records its kind, session, workspace, reason, available actions, and blockers.

| Item kind | Introduced |
|---|---|
| Interrupted turn | — |
| Surviving process | — |
| Saved unsent input | — |
| Unanswered question | — |
| Scheduled send needing confirmation | — |
| Pending edit review | Phase 5 |

Decisions (`pending`, `continueRequested(actionID)`, `dismissed`, `resolved`) are stored in the session's recovery record.

**Startup order (Phase 1).** At launch, recovery discovery runs **before** the scheduler evaluates and before any queue pump starts.

**Rendering.** The Mac UI renders from the catalog: a per-session banner, plus a "Needs attention" sheet modelled on the Scheduled Messages sheet. A future remote UI reads the same catalog.

**Dismiss** acknowledges the card only. It never:
- discards saved input;
- answers a question;
- stops a process;
- confirms an overdue schedule;
- releases an unknown owner.

Removing saved input is a separate, explicit action, which first offers to move the text into the composer.

### R9. Interactions with other features

**Scheduled sends.** Ownership transfers by receipt (OracleE):
1. Commit the existing `dispatching` attempt with its deterministic item ID.
2. If delivery falls back, commit an intent that carries the schedule, attempt, and item IDs.
3. Commit the schedule receipt and clear its pending record.
4. Release attachment ownership only once the intent holds the attachments.

A crash after step 2 is repaired by matching the receipt. Because the startup barrier ships in the same phase, the repair runs before the scheduler could surface a second confirmation.

- **Receipts.** Historical receipts gain an acceptance kind: `providerAccepted`, `savedInQueue`, or `legacyUnknown`.
- **Busy aggregation** adds unresolved interruptions, unresolved processes, and Resume reservations. `runAlongsideOtherSessions` cannot bypass them.
- **Never auto-confirmed.** Dismiss and Resume never confirm an overdue schedule.
- **Future schedules unchanged.** A schedule whose deadline is still in the future keeps its documented behavior once these gates pass.

**Pending questions.** The question text, its options, and any partial answer are saved; continuations are not. After a restart the old request is historical and its transport has expired. The user's typed answer becomes the Resume or Send text, and any fresh request needs fresh routing.

**Pending edit reviews** (Phase 5):
- The proposal is persisted before it is shown, and `applicationStarted` is committed before applying.
- After a crash, current file fingerprints are revalidated and nothing is reapplied automatically.
- Approving after a restart can't return a tool result to the dead provider, and the card says so.

**MCP callers and `agent_run` children** (Phase 5):
- Persist the parent session and attempt, the tool-call identity, and the child session before child dispatch. A parent's recovery then finds its child instead of replaying `agent_run`.
- Old RPC continuations and permission scopes expire at restart.
- A stable client operation ID is deferred. Until then, the contract explicitly excludes deduplication across an MCP caller's own new retry: persisted intent IDs recover that intent, but they don't give exactly-once behavior across separately submitted requests.

**Turn checkpoints** (`2026-10-18-turn-worktree-checkpoints-spec.md`). This spec supplies only:
- the shared run-attempt ID;
- opaque checkpoint outcome references in the recovery record;
- the `unresolvedPriorExecution` flag from the registry;
- pinning of unresolved interrupted turns;
- the interrupted-turn card that hosts the checkpoint section.

The shared pre-dispatch gate runs this spec's ownership check before the checkpoint's 2-second capture. File review is never a prerequisite for Resume, Resume never restores files, and a missing checkpoint never blocks an otherwise safe Resume.

## Owner decisions

Decision O3 (2026-10-20): Defer real-app crash testing; proceed with instrumentation and code validation, leaving live acceptance pending.
Decision O6 (2026-10-21): Use the configured 1Password signer for reviewed local checkpoints; no unsigned signing bypass is authorized.
Decision O7 (2026-10-21): Authorize one additional independent OracleA/OracleB re-review of Phase 1b input integration after the remaining fixes, beyond the normal two re-review rounds.
Decision O8 (2026-10-22): Retry signing now; unsigned local commits are authorized if signing remains unavailable, then continue implementation. This supersedes O6's prohibition on an unsigned fallback.
Decision O9 (2026-10-22): Preserve the architecture and checkpoint the reviewed inactive partial Phase 4 source; keep the older-message requirement and full Phase 4 explicitly blocked, and do not enable features.
Decision O10 (2026-10-22): Persist the OracleD/OracleE guidance and proceed with the recommended bounded source-only investigations of older saved-input canonical ownership and Claude native identity; keep automated Restart, activation, polish, retention and live acceptance deferred.
Decision O11 (2026-10-22): Implement moving or reconstructing the same unsent message at the conversation's current end, preserving its ID and saved chronology; if sending fails, leave it unsent at that new position.
Decision O12 (2026-10-23): Use OracleA and OracleB for reviews; never use OracleC unless the owner explicitly asks.
Decision O13 (2026-10-23): Continue until all work is finished before the final live verification.
Decision O14 (2026-10-23): Accept the recommendation to keep full Phase 4 blocked pending authoritative Claude history-identity evidence and resolution of the armed-helper-stop policy, with recovery activation off and live acceptance pending; use OracleA and OracleB for guidance when uncertain.
Decision O15 (2026-10-23): Proceed now to resolve the remaining Claude history-identity and armed-helper-stop prerequisites, using delegated judgement and OracleA/OracleB guidance.
Decision O16 (2026-10-23): Approve the isolated Claude session capture described in the question: configured authentication, a few trivial prompts in a temporary directory with tools disabled, reading only its new test-session history and retaining sanitized evidence; no recovery activation or app lifecycle action.
Decision O17 (2026-10-23): Select “Use my normal CLI (Recommended)” for the capture authentication prerequisite; no custom command or credentials were supplied.
Decision O18 (2026-10-23): Confirm `/Users/tnguyen/.local/bin/claude` works manually and request a dedicated worker to diagnose why the capture differs and how to correct it.
Decision O19 (2026-10-23): Approve one additional isolated prompt with only `CLAUDE_CONFIG_DIR` removed from the child's environment, using the same CLI, safe-mode/tools-disabled flags, 120-second deadline and $0.50 cap; no login changes or credential inspection.

Each has a recommended default; none blocks Phase 1.

- **O1 — Surviving processes at launch.** Default: *Let finish* and keep watching, with no automatic stop. A dev-rebuild restart shouldn't destroy a Claude turn that is still finishing.
- **O2 — What a Resume click does.** Default: send immediately, with the continuation text visible and editable in the card. A secondary *Edit first* action puts it in the composer instead.
- **O3 — How to test against a real app kill.** About ten stores hard-code `Application Support/RepoPrompt CE`, so a second instance would share live data. The options:
  - (a) a DEBUG-only Application Support root override honored by every store, which needs an audit of those stores, the MCP socket paths, and the Keychain service;
  - (b) a disposable macOS test account, which needs no code but does need the provider CLIs, shims, and logins set up there.

  Recommendation: (b) for the first acceptance pass, and (a) only if repeated runs justify it.
- **O4 — Composer durability.** Default: a 300 ms write debounce with a 2-second maximum delay, and no Saving/Saved indicator.
- **O5 — What "durably queued" means to MCP callers.** Default: the item survives a restart as held input that needs one click. It is never auto-sent.

## Phasing

0. **Measure and prepare** (no behavior change):
   - Add the save counters and measure starvation and serialization cost (R3).
   - Locate the session-incarnation authority (R1).
   - Inventory every queued/delivered acknowledgement site and every provider handoff route.
   - Check whether any controller spawns `claude --resume` eagerly when a session hydrates. If one does, a relaunch could start a second writer next to a surviving orphan before Phase 3, so that path joins Phase 1's crash hold.
   - Settle O3.
1. **Stop losing what's typed and queued.** This splits into two independently shippable parts:
   - **1a (small):**
     - the 10-second transcript maximum wait, with buffered text drained before cleanup;
     - flushing dirty, fully hydrated sessions before teardown, with a second pass after terminal commits;
     - window-close preservation inside `prepareSessionForWindowClose`.
   - **1b:**
     - the recovery store and records, and the durable session stub;
     - composer persistence;
     - intents for **every** send route;
     - the Codex fix with receipt-gated acknowledgements, landed together;
     - the scheduled-send receipt transfer **with** the startup barrier;
     - preserve-versus-withdraw;
     - the two-stage quit with its point of no return;
     - the R1a reconciliation rules;
     - held recovered input with *View* / *Edit* / *Remove*;
     - a **crash hold**: in a session whose last attempt was open at an unclean exit, every send route (composer, MCP, scheduled) requires a confirmation that "the previous run may still be running" until Phase 3 replaces it with the registry.
2. **Honest interruption:** launch state, the turn `interruption` record, the recovery catalog and banner, index schema 8, and question snapshots. No Resume yet.
3. **Process registry:**
   - the pre-spawn reservation, marker, and birth identity;
   - Claude `--session-id` preallocation;
   - discovery, exit watching, Let finish, and Stop;
   - the two-writer rule, which replaces the crash hold;
   - live gates for marker propagation and startup hooks.
4. **One-click Resume:** Claude history import, Codex reconciliation, the Resume action and dispatch permit, the checkpoint card seam, and Restart safely.
5. **Later:**
   - pending edit-review persistence;
   - `agent_run` parent/child linkage;
   - ACP and Oh My Pi qualification;
   - the Claude detach-on-restart experiment;
   - durability hardening, shared with the checkpoint spec's Phase 3.

## Validation

### Unit tests

New suites go under `Tests/RepoPromptTests/AgentMode/Recovery/`. They cover:
- record round-trips, including unknown versions, unknown members, and corrupt files;
- revision conflicts, tombstones, and reset retargeting;
- the R1a joins: unaccepted intent with a saved bubble; accepted intent with no bubble; terminal evidence against an open turn; an attempt that exists only in the recovery record;
- acknowledgement outcomes at each boundary: commit failure, stale target after the commit, and bookkeeping failure after handoff;
- a concurrent same-ID enqueue producing one intent;
- the composer maximum delay and the transcript maximum wait under a fake clock;
- cold restore writing the per-attempt reason, without touching turns the user cancelled;
- registry classification with faked inspection: a reused PID with a different start time, a descendant found by marker, a `reserved` record without a process, and denied inspection classified as unknown;
- two-writer refusal, and tool-only survivors not blocking;
- the catalog snapshot matching rendered rows;
- the scheduler treating a session with an unresolved interruption as busy.

### Crash cuts

These need O3. Kill RepoPrompt at each point and check the result:

| Kill point | Expected after relaunch |
|---|---|
| Before an intent commit | No success acknowledgement was sent |
| After the intent commit, before the acknowledgement | One recoverable intent |
| After the acknowledgement, before the queue drains | The full payload survives |
| Just after a direct Send | The message is held, or `deliveryUnknown` |
| Between scheduled-send transfer steps | No duplicate |
| Mid-stream | Interruption recorded; transcript staleness within the measured maximum wait |
| During quit Stage A, then during Stage B | Stage A: the app stays usable. Stage B: the next launch treats the sessions as uncertain |
| After a `reserved` record, before identity is filled | Ownership unresolved |

### Shutdown-failure tests

- A Stage A failure followed by Cancel quit, more interaction, and another quit.
- A Stage B failure followed by Retry flush.

### Live acceptance

Run through the real shims, using O3's isolated instance:
- a Claude foreground tool followed by a new tool;
- Claude with a background child;
- Claude with an unanswered stdio permission request (this decides O1's advice);
- Claude mid-call to a RepoPrompt MCP tool;
- Claude startup hooks;
- `claude --resume` with a dangling `tool_use`;
- a Codex command in progress, then `thread/resume`;
- marker propagation through both shims and both providers' tools;
- Cmd-Q with several running sessions, recording quit latency.

Record process identities, recovery records, transcript IDs, marker files, and click counts. The throwaway-parent experiments above are design evidence only; they must not be cited as passing these tests.

### Performance

On the owner's Mac:
- intent commit latency p95 ≤ 50 ms;
- composer writes never block typing;
- a quit with 5 active sessions finishes in ≤ 8 s.

## Owning seams

**New in AgentCore:**
- `AgentMode/Models/AgentRecoveryModels.swift`;
- under `AgentMode/Runtime/Recovery/`: `AgentRecoveryStore.swift`, `AgentRecoveryCoordinator.swift`, `AgentProcessRegistry.swift`, and `AgentProviderRecoveryAdapter.swift`;
- `AI/Providers/ClaudeCode/SDK/ClaudeSessionHistoryReader.swift`;
- `AgentMode/Runtime/Codex/CodexRecoveryAdapter.swift`, a facade over the existing reconciliation.

**New in Platform:** `Infrastructure/Process/ProcessInspection.swift`. `ProcessLauncher.swift` also gains the optional environment marker and returns the birth identity.

**Changed in AgentCore:**
- `Runtime/Session/AgentTabSession.swift`: identifiable queue values with intent IDs, held recovered input, `composerRevision`;
- `Runtime/Codex/CodexAgentModeCoordinator.swift` and `CodexSteerAckTracker.swift`: async enqueue and receipts;
- `ClaudeNativeProcessSessionController.swift`: reservation, registration, `--session-id`;
- `Runtime/AgentSession.swift`: the turn `interruption` record;
- `AgentSessionRestoreSupport.swift`: the recovery context, with per-attempt reasons recorded before sanitizing;
- `AgentSessionMetadataIndex.swift`: schema 8;
- `Runtime/Scheduling/AgentScheduledSendCoordinator.swift`: the startup barrier and busy inputs.

**App:**
- `AgentModeViewModel.swift`: send and composer integration, preserve-versus-withdraw inside `prepareSessionForWindowClose`, the flush before teardown, the maximum wait, delta draining;
- `AgentModeViewModel+ScheduledSend.swift`: the receipt transfer;
- new `AgentModeViewModel+Recovery.swift`;
- `AppDelegate.swift` and `WindowStateManager.swift`: the two-stage, bounded shutdown;
- `WindowCloseCoordinator` and the quit confirmation wording;
- new recovery banner, Needs-attention sheet, and `AppRelaunchCoordinator.swift`.

**Docs:** when this lands, update `docs/context/agent-scheduled-messages.md` for queued-versus-accepted semantics and the recovery admission contract.

## Review record

**Round 1, 2026-10-18 (OracleD and OracleE, identity verified).**
- *P0 fixed: cancelling quit after teardown.* Both Oracles found that a failure after teardown could not safely cancel the quit. Fixed with R4's two stages and point of no return.
- *P1s resolved:*
  - durable intents for direct sends (R2);
  - composer coverage and its maximum delay (R2, O4);
  - two-file reconciliation (R1a);
  - the scheduler barrier moved into Phase 1 alongside the receipt transfer;
  - an admission hold for crash-interrupted sessions in Phase 1;
  - how the provider home is learned (R6);
  - window close never marking the launch clean (R4);
  - outcomes by boundary (R2);
  - a pre-spawn reservation replacing both registration proposals (R6);
  - a stricter Claude completion test (R7);
  - the transcript maximum-wait hook and delta draining (R3).
- *P2s resolved:*
  - window-layout order;
  - optimistic composer clear;
  - tool-only survivors;
  - stale target after a commit;
  - skipping partially hydrated sessions;
  - remote-host scope;
  - `--session-id` moved to Phase 3;
  - Phase 1 versus Phase 2 interruption data;
  - the window-close seam;
  - the eager `--resume` check;
  - exit watching for every member.
- *P3 corrections applied:* line references fixed, the existing save counter cited, the `previousInstance` hold made derived, and record lifecycle, registration failure, and the Stop preview specified.
- *Rejected alternatives the reviewers accepted as sound:* no continuous polling; no bundling of follow-ups into Resume; detach deferred; no Saving/Saved indicator; the interruption record kept in session JSON.
