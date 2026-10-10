# Telegram attention notifications — work contract

Scope: read when the task touches Telegram (or other outbound) alerts for root Agent Mode turn completion or `ask_user` questions.
Authority: Reference
Last-verified: 2026-10-10

## Goal
Send me a Telegram message when a root Agent Mode session I drive needs me — a turn finished and the session settled, or an `ask_user` question is waiting — so I can step away and return only when needed. Desktop banners never fire while the app is frontmost and never reach my phone.

## Done when
- Enabled, a root turn that completes and settles idle (no queued follow-up or provider successor taking over) sends one notification: workspace, session name, and that turn's final assistant text; long text goes in up to 3 numbered parts, the last ending with a visible truncation marker.
- A root `ask_user` sends one notification with every question, every option (with description), and the multi-select/custom-answer flags, split into numbered parts rather than dropping anything.
- Nothing is sent for children at any depth (including orphaned children whose questions fall back to me), Knowledge workers, roots under external MCP control, unknown or conflicting lineage, or cancelled/failed turns.
- The app sends each event (session + turn attempt, or session + interaction ID) at most once; a question answered, skipped, timed out or cancelled before send admission is not sent. One attempt per event; the outcome (sent, failed, unknown) is recorded, never auto-retried.
- If Mac input idle time is readable without a permission prompt, send only when idle ≥5 min at event time; otherwise always send. App focus never matters.
- A hanging or failing Telegram call never delays the run, successor start, question installation or its timeout (fenced test, no sleeps).
- The bot token stays in secure storage; a forced failing request leaves no token in logs, crash breadcrumbs or the last-error text (test). Ephemeral storage or a missing token is shown in settings.
- Settings: off by default; enable, token, chat ID, Send test, last delivery result, last suppression reason.
- Focused tests pass against a stubbed HTTP client; then, with my approval, I confirm one real completion and one real question on my phone.

## Non-goals
Remote-control link and Telegram replies/buttons (later contract); Codex native `requestUserInput`, tool/edit approvals, instruction waits; gateway Web Push changes or a gateway-hosted sink; a generic webhook framework; delivery while the app is not running; Markdown/HTML formatting.

## Boundaries (need my approval)
Any real Telegram send; visible app launch/relaunch; push; wider event coverage or message content; changes to delegation lineage, question audience, terminal-commit ordering, or gateway/remote contracts; any new macOS permission prompt.

## Budget
Advisory: about a week of focused work, a mid-sized change (notifier, settings, tests), reviewed per the review policy (initial review plus up to two re-review rounds per step). Stop and report past ~2× or if lineage itself must change.

## Facts
- Completion hook runs at terminal commit when `notifyTurnComplete` is set, after the successor kind is computed but without checking it — `AgentRunTerminalCommitBarrier.swift:289–316`; providers set that flag only for completed turns (scout-reported: `ClaudeIntegratedAgentModeRunner.swift:129–175`, `ACPIntegratedAgentModeRunner.swift:1631–1666`, `CodexAgentModeCoordinator.swift:6221–6284`, `HeadlessAgentModeRunner.swift:228–286`).
- Full final text is available; desktop truncation happens later — `AgentTranscriptServices.swift:2981–3039`, `NotificationService.swift:268–294` (scout-reported).
- `askUser` installs `pendingAskUser`, routes the delegated audience, and sends no alert — `AgentModeViewModel.swift:19075–19108`; answer/skip/timeout/cancel clear it at ~19176–19379 (scout-reported). Question audience and text rendering already exist — `AgentDelegatedQuestionAudience.swift:15`, `AgentDelegatedQuestionNotice.swift:115`.
- Claude native `AskUserQuestion` is disallowed — `ClaudeCodeIntegrationConfiguration.swift:65,100,133`; Codex `requestUserInput` bypasses `askUser` — `CodexAgentModeCoordinator.swift:6573–6574`.
- Root lineage resolves via `mcpDelegationLineage` and fails closed on unknown/conflicting parents — `AgentModeViewModel.swift:6739–6806`; `agent-mcp-delegation-depth.md` (Lineage).
- Desktop alerts return early while the app is active — `NotificationService.swift:97,119`; no app-level notification setting exists (scout search).
- Secure storage can fall back to an ephemeral store — `SecureKeyValueStorageBackend.swift:51–75`. An injectable `HTTPClient` exists — `Infrastructure/Networking/HTTPClient.swift:3–46`.
- Telegram `sendMessage`: 1–4096 chars, token in the URL path, ~1 msg/s per chat — core.telegram.org/bots/api#sendmessage, core.telegram.org/bots/faq. No Telegram/webhook code exists (repo search 2026-10-10).
- Mac idle time: CoreGraphics `CGEventSource.secondsSinceLastEventType`; unused in repo, permission need unverified (search 2026-10-10).
- The PWA can't take a link yet: gateway off by default (`GlobalSettingsManager.swift:1253–1254`), HTTP-only tailnet origin (`RemoteDiscovery.swift:88–94`), pairing posts `{}` but host requires `approval_context` (`app.js:168`, `MCPRemotePairingToolProvider.swift:303`), no structured-question UI (`app.js:525–541`).

## Directions (ranked)
1. Settled-event admission in the app: capture completion identity and text at terminal commit but admit only once successor selection settles idle; capture `ask_user` at installation and admit only while that exact pending interaction is current; reuse lineage, audience and question-text authorities; send off the main actor. Why: reuses existing authorities and covers every provider. Kill: a queued-successor chain yields an intermediate alert or misses/misattributes the final one and the fix needs terminal-commit reordering; or pause-before-send then resolve/rebind/disable still yields a POST; or a cold-started UI root resolves unknown and needs a lineage change.
2. Pure run-state observation (session becomes idle / waiting-for-user). Why: no hook edits, naturally skips intermediates. Kill: completed vs cancelled/failed is indistinguishable, the final text or interaction ID is unavailable, approval waits look like questions, or two consecutive questions collapse into one alert.

## Evidence directory
`docs/investigations/2026-10-10-telegram-attention-notifications/` (git-excluded, not committed).

## Slices

### Slice 1
Check the live settled-event direction for boundary-breaking kill results before implementing it; budget used so far: one read-only probe, no source changes.

Step 1 — done | rounds 0/2 | open: none | downgraded: none | assumed: static feasibility is not runtime acceptance | deferred: runtime kill tests in Slice 2

Slice 1 result: Source tracing found existing root, successor, question and binding authorities sufficient for a boundary-preserving admission seam, with structural checks passing and no runtime result yet, so Slice 2 tests that seam before adding transport (evidence: `slice-1-findings.txt`).

### Slice 2
Add only the settled completion/question admission seam and prove Direction 1 kill conditions with deterministic stub delivery; budget used so far: Slice 1 source probe and structural checks, no production source change.

Step 2 — done | rounds 1/2 | open: none | downgraded: none | assumed: all MCP-controlled roots are excluded; remote-host roots are eligible; provider/root coverage is fixture evidence, not live acceptance | deferred: secure transport and settings; real restore, UI-handoff and scheduled-send integration; R1 selected generic follow-up abandoned before starting stays silent; R3 rejected publication then declined duplicate does not recover an alert; R4 remote-child projection requires proof before enabling delivery

Material implementation choices: Keep one app-wide event ledger for at-most-once admission across windows, and add notification-only capture/settlement hooks without reordering existing terminal calls; preserve the owner’s five-minute event-time drop rule.

Budget used so far: about two hours elapsed including Oracle and shared-build-slot waits, one completed source slice and three scoped worker sessions; no real sends or app lifecycle actions.

Slice 2 result: The disabled admission seam passed 15 fenced stub tests, 139 lifecycle tests, 23 fallback tests and 24 delegated-question tests plus lint and structural checks, and both review lanes cleared it with no open P0/P1, so the next slice adds isolated secure Telegram delivery before settings enable it (evidence: `slice-2-parent-final-tests.txt`, `slice-2-parent-final-lint.txt`, `slice-2-review-fixes-lifecycle.txt`, `slice-2-review-fixes-fallback.txt`, `slice-2-parent-delegated-check.txt`, `slice-2-oracleA-rereview-1.md`, `slice-2-oracleB-rereview-1.md`).

Review follow-up: Static tracing found only the Codex fallback successor factory; a temporary decline leaves its queue nonempty and a successful claim starts new ownership synchronously, so neither can pass the admission fence; eligible roots publish synchronously as accepted, making R3 a synthetic noneligible publication case (evidence: `slice-2-provider-successor-search.txt`, `slice-2-publication-scope.txt`).

### Slice 3
Add isolated plain-text Telegram rendering, single-attempt HTTP delivery and noninteractive secure token storage, with stubbed failure/leak and multipart tests before production wiring; budget used so far: about two hours elapsed, one committed source slice and three scoped worker sessions.

Step 3 — done | rounds 1/2 | open: none | downgraded: none | assumed: no real HTTP calls or live-session delivery; server errors and offline drops may mean unknown delivery; full names share the completion's three-part budget | deferred: settings UI, paced pre-send admission, event-time system idle sampling, integration and phone acceptance; R1-2 capacity-filling splits can divide words

Material implementation choices: Use the existing HTTPClient and secure-storage backend, fixed Telegram endpoint and plain JSON, and keep raw URL/request/error/response details out of diagnostics; split without loss for questions and cap completions at three numbered parts with a visible marker only when truncated; treat all API server errors and offline drops as unknown rather than claim non-delivery, with no retry.

Budget used so far: about three hours elapsed including shared-slot and review waits, two completed source slices and four scoped worker sessions; no real sends, credential access or app lifecycle actions.

Slice 3 result: Isolated rendering, HTTP delivery and secure token storage passed 45 focused stub tests after a reproduced paragraph-loss regression was fixed, with lint and guardrails passing and both review lanes clearing P0/P1 in one re-review round, so the next slice joins pacing to admission while live delivery remains disconnected (evidence: `slice-3-fixes-renderer-red.txt`, `slice-3-fixes-renderer-green.txt`, `slice-3-parent-final-client.txt`, `slice-3-final-TelegramBotTokenStoreTests.txt`, `slice-3-final-SecureStorageAccountCatalogTests.txt`, `slice-3-oracleA-rereview-1.md`, `slice-3-oracleB-rereview-1.md`).

Review follow-up: Shared ephemeral storage and noninteractive reason semantics were confirmed from the existing factory and Keychain query; the redirect test checks the SDK selector and refusal directly, not a live URLSession redirect; the final cheap P3 outcome fixes were rerun without a review round solely for P3 (evidence: `slice-3-storage-authority.txt`, `slice-3-parent-final-client.txt`).

### Slice 4
Join paced single-attempt Telegram delivery to event admission behind deterministic HTTP and queue fences, keeping production disconnected; budget used so far: about three hours elapsed, two committed source slices and four scoped worker sessions.

Step 4 — done | rounds 0/2 | open: none | downgraded: none | assumed: queued events revalidate after pacing and before their first POST; admitted attempts retain their credential snapshot, with no withdrawal promise after admission; no live settings or secure-storage reads in tests | deferred: settings must share one pacer across replacements and route Send test through the same queue (B S4-1); sanitized part-failure reason for settings (B S4-4); shared test-double file move (B S4-5); settings and live wiring, root restore/handoff/schedule and remote-child integration, R1 selected follow-up abort recovery, phone acceptance

Material implementation choices: Keep the FIFO and duplicate-pending ownership inside the existing admission authority rather than add a separate permit ledger; retain one event's queue head through all its parts, so a hanging request holds later notifications only, not run or question processing; share pacing state across credential replacements, with one-second private-chat spacing and conservative three-second spacing for groups/channel usernames; keep shared test doubles together rather than introduce a support file solely for an organizational finding (planning evidence: `slice-4-plan.md`).

Budget used so far: about four hours elapsed including shared-slot and review waits, three completed source slices and five scoped worker sessions, reusing the Pair worker for fixes; no real sends, credential access or app lifecycle actions.

Slice 4 result: Paced queued admission passed 29 stub tests after the new coverage test's premature outcome read was corrected, with lint and guardrails passing and both review lanes clearing P0/P1, so the next slice proves restored and projected session eligibility and selected follow-up abort recovery before settings enable production (evidence: `slice-4-final-AttentionNotificationAdmissionTests.txt`, `slice-4-fixes-paced-delivery-run-3.txt`, `slice-4-fixes-lint-2.txt`, `slice-4-guardrails.txt`, `slice-4-oracleA-initial.md`, `slice-4-oracleB-initial.md`).

Review follow-up: Added post-admission credential-retention and snapshot-redaction tests without changing reviewed production behavior, so no round was run solely for P2/P3; the final accepted test ticket waited 22 minutes 36 seconds for another worktree's heavy slot and then passed in 13.4 seconds, not a delivery-latency measurement.

### Slice 5
Prove eligible restored, handoff and scheduled roots and ineligible projected children using existing production paths, and reproduce the selected-follow-up-abort gap before choosing a repair; budget used so far: about four hours elapsed, three committed source slices and five scoped worker sessions.

Step 5 — done | rounds 0/2 | open: none | downgraded: none | assumed: temporary-store and stub-provider integration is not live app acceptance; no lineage, question audience or terminal-order changes | deferred: R1 experiment did not reproduce pre-ownership abort because availability changed before the queued start; projected-child lineage proof uses local authorities, while actual remote event dispatch bypasses capture; remote-root classification/coverage remains unresolved; duplicated fixture helper and older fixture test ID retained (B S5-6/7); follow-up repair only after a stable reproduction; settings and live wiring, phone acceptance

Budget used so far: about five hours elapsed including review and shared-slot waits, four completed code/test slices and six scoped worker sessions, reusing the Pair worker for fixes; no real sends, secure-store access or app lifecycle actions.

Slice 5 result: Four production-construction tests added six notification scenarios and passed the 20-test admission suite plus lint and executable discovery after scope/branch assertions were tightened, but the attempted unavailable-provider experiment actually started its follow-up and did not reproduce abandonment, so the next slice resolves that experiment and remote-event authority before live wiring (evidence: `slice-5-fixes-admission-run-1.txt`, `slice-5-fixes-lint.txt`, `slice-5-dev-test-list-full.txt`, `slice-5-r1-experiment-raw.txt`, `slice-5-oracleA-initial.md`, `slice-5-oracleB-initial.md`).

Review follow-up: Both lanes cleared P0/P1, cheap coverage and wording findings were fixed without production changes or a round solely for P2/P3, and the shared data service's hydration path was confirmed to read/decode the session file rather than serve a transcript cache; the test remains a second view model in one process, not live app cold-start acceptance (evidence: `slice-5-parent-restore-authority.txt`).

## Decisions
- Commit signing: permit unsigned local commits for this contract after the Slice 4 1Password failure; owner will arrange later amendment/re-signing at the desk, with separate history-rewrite approval at that action boundary (owner answer 2026-10-10).
- Review recovery (Slice 2): authorize one additional fresh, bounded OracleB retry after the initial reply and normal retry omitted findings and a complete verdict (owner answer 2026-10-10).
- Orphaned-child questions: never notify.
- Externally MCP-controlled roots: do not notify.
- Coverage: finished turns and RepoPrompt `ask_user` only.
- Focus: prefer sending only when the Mac has been idle ≥5 min if detectable; otherwise always send.
- Long replies: numbered parts, up to 3 messages.

## Assumed
- Idle is checked at event time; an event skipped because I'm active is dropped, not re-sent later.
- One send attempt, no auto-retry; plain text only; UI-handoff, Knowledge-root and scheduled-send roots count as roots.
