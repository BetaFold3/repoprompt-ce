# Lossless restart — external-driver acceptance handoff

Scope: read when the task touches the remaining lossless restart validation, isolated live acceptance, or coordination across app stop/relaunch.
Authority: Reference
Last-verified: 2026-10-24

## Outcome and next boundary

Non-lifecycle validation was executed, **not all passed**. [Full results](pre-live-validation-2026-10-24.md): unfiltered root 7,782 tests across 657 suites, with one suite still failing after retry and focused serial reproduction; core 66/66 and provider 35/35 passed; signed scratch packaging passed. No source was changed to hide the failure. No app was launched, stopped or relaunched, no new provider prompt was sent, and production recovery gates remain off.

The remaining root failure is `MCPCodeStructureWorktreeTests.testRetainedProjectionPreloadStopsAfterIndexAdvanceAndForegroundRecoversOnce`, line 1805: projection preload did not observe the staged index change. It is a codemap-domain failure, but attribution to pre-existing code versus the restart series is **not proven**. The working tree includes an unrelated modified codemap test helper. No bisect, clean-baseline comparison or fix was done. Keep the full-suite gate failed rather than calling this a pass with exclusions. Do not modify the owner's unrelated codemap work without a scoped follow-up.

Current live CE is **not the candidate**: PID 8017 began 2026-10-20 20:18:57 at `/Applications/RepoPrompt CE Dev.app/Contents/MacOS/RepoPrompt`; live ping reports `debug-optimized-incremental`, whereas the newer installed bundle reports `8033b458`, dirty, lane `debug`. Main checked process identity and ping; the executable predates its on-disk bundle. Neither installed nor running identity qualifies source checkpoint `e7ac41e4`.

**Stop here before visible launch/stop/relaunch.** Recommended next authorization is one disposable-account bootstrap and bounded gates-off baseline launch, not a promise of full recovery acceptance or blanket crash approval. The alternative is to leave live acceptance pending. The owner need not answer a multi-part setup questionnaire now.

## What ran, what did not

- Main independently checked all five conductor outcomes, root census, package test totals, the focused failure, and scratch deep-strict signature verification.
- Plain `make dev-smoke`, ticket `4f8574d1-c14e-4645-bc0e-55e252d9274f`, failed at missing window 1 before its workspace switch. Do not retry it against the owner's real window: the script switches workspaces.
- Read-only `rpce-cli-debug` version, matching-window roots and role inventory worked; main also repeated the diagnostics ping. Ping's binding was unbound, so it proves connectivity/lane only, not tab identity.
- Full-root retries recovered five other suites; this is not a first-attempt-clean run. See the validation report for names.
- No current-source app/provider, crash-cut, shutdown-failure, UI/accessibility or recovery activation acceptance is claimed. Existing captured Claude sessions and fixtures retain their earlier limited evidence scope.
- No extra source tooling, crash hooks, qualification override, clean worktree, provider capture or performance benchmark was built just to expand validation.

## Candidate identity (packaging evidence, not live acceptance)

Scratch bundle, still unlaunched:
`/var/folders/05/h5dklt3s7nnbc4kf4r_153_40000gn/T/rpce-prelive-pkg.nX1Ney/RepoPrompt.app`.

It is temporary and may be removed by system cleanup. Rediscover and verify it before reuse; do not copy over the running app. A later acceptance candidate must be explicitly selected again.

- Source HEAD: `e7ac41e44ca8ce0d07034fd93b339a0d960ef300`; provenance `dirty: true`, debug/`Onone`, build epoch `1792838152.229955`.
- Before evidence edits, SHA-256 of `git status --porcelain=v1`: `327eab669760262d43e0ca8c95a587bed84690d85f98e52109ba573c3abeef3c`; SHA-256 of `git diff --binary HEAD`: `5474609406db94b40ec9893fab9379b06ac34c3238c823356b22fa7c77251089`. These identify the recorded dirty tracked inputs/status, not contents of every untracked file.
- Dirty paths are listed in the validation report. No production Swift was dirty; the root test artifact includes the modified codemap helper. This is not clean-HEAD full-suite acceptance.
- `Contents/MacOS/RepoPrompt` SHA-256: `081609c4d84c84e7299da9c05e45e055c9e4dda84f45c2eb6e14f0dd3f0ba98c`.
- `Contents/MacOS/repoprompt-mcp` SHA-256: `6f9fd118e052d8645b295d9fea7c6a7915fed69fd3efa189cef81f7fe6fa7329`.
- `Contents/Resources/RepoPromptDebugProvenance.json` SHA-256: `55fd48b20ef05436d6b99a735f8fa177b54e9f8a7cafd9880fae533b9116877b`.
- Apple Development signature, authorized team `AM9B9Y6HBV`, debug bundle ID `com.pvncher.repoprompt.ce.debug`; no identity or release metadata change. Package cache reuse was unavailable; normal signing and full checks passed.
- The packaging compatibility link was restored to its previous target. Main checked that link and PID 8017 afterward. The live bundle was not the package destination.

## Minimal owner work and external driver

1. **Once:** choose/create a disposable standard macOS account and sign in to the provider(s) needed for the first baseline through their normal login flows. Do not copy credentials, Keychain databases, existing CE data, private histories or absolute workspace references from the daily account.
2. Start an already available agent in a normal Terminal session **outside CE**, in that account. Pi, Claude Code or Codex CLI can be used if available and authenticated there. No preference depends on an unverified app capability.
3. Give explicit approval immediately before the identified baseline app launch. Later stop/relaunch/crash batches require fresh approval identifying their targets and stop conditions. This handoff grants none.
4. The driver performs inspection, ordinary CLI commands, evidence collection and verified lifecycle commands. Use separately available Claude.app/ChatGPT.app computer use for genuine UI checks if it can be verified there; otherwise ask only for the few UI actions that cannot be exercised through the CLI.

Claude.app and ChatGPT.app were present in the daily account; Codex.app was absent at the checked Applications location. No computer-use tool is available in this main session. Availability, automation permissions and provider authentication in the disposable account are not established. Do not promise zero manual setup or use a CE-hosted child as the sole coordinator across CE termination.

**Keep the daily CE process and data untouched.** Use account-local source/build/bundle/workspace/evidence paths. Do not modify the shared `/Applications` bundle or `/usr/local/bin/rpce-cli-debug` link. Conductor's so-called machine locks are per UID and cannot serialize cross-account writes to shared destinations.

The CE CLI is `rpce-cli-debug`, not production `rp-cli-debug`. Resolve the actual account-local executable rather than guessing a bundle filename: the debug install script points that command at `Contents/MacOS/repoprompt-mcp`. Verify its identity/version before use. Do not run the installer against the global link.

### Copyable brief for the external driver

> Do not call ask_oracle or ask_user, do not use context_builder with response_type review or plan, and do not start other agents. If you have a question or want a second opinion or a review, stop and report back to the main agent.
>
> Read this handoff and the linked validation evidence. You are an independent coordinator outside RepoPrompt CE, working only in an approved disposable macOS account. First verify your UID, account-local stores/socket/workspaces, exact candidate and CLI paths, and your independence from the CE process. Do not inspect credentials or existing owner sessions. Do not edit source, enable production gates, install shared links, push, or launch/stop/relaunch anything without the owner's fresh action-boundary approval. Complete only the specifically approved baseline scenario; gated and exact-cut scenarios below remain blocked until their prerequisites are reviewed. Persist the next action before any approved lifecycle operation and results afterward. After interruption, reobserve; never blindly retry a send, signal, or restart. Never use name-wide kill commands. Return compact evidence and unresolved items to the main agent.

## Isolation and testability prerequisites

Verified source anchors:
- UID-namespaced MCP socket and user-domain Application Support: `MCPFilesystemIdentity.swift:133–147`; socket ownership checks: `BootstrapSocketOwnership.swift:77–98`.
- Registry process UID/birth identity and marker/lineage inspection: `ProcessInspection.swift:4–18,168–169`, `AgentProcessRegistry.swift:383–445`. Cross-account unreadability is unknown, not stopped. Do not import another account's runtime records.
- Relaunch target is the current bundle and its bundled helper: `AppRelaunchCoordinator.swift:193–206`; helper validates parent containment: `ProcessRelaunchHelper.swift:560–580`.
- Per-UID conductor locks: `Scripts/conductor.py:1913–1915`; global/user CLI link chain: `Scripts/install_debug_cli.sh:5–10`.

A disposable account is the recommended isolation boundary, **not a complete runtime audit already passed**. Before a destructive case, resolve actual store, history, socket, helper and bundle paths and stop on any cross-account/shared mutable target.

Two further prerequisites are genuinely unmet:
1. **Whole-app qualification composition.** Component injection exists, but the app composition does not inject action qualification; VM677 and launch authority85 independently use production registry/qualification, and the window manager uses the default relaunch coordinator. No executable whole-app acceptance entrypoint was found. A later narrowly scoped candidate must cover these real paths consistently; changing a test flag is not proof.
2. **Exact crash/failure boundary control.** Store FileOperations and lifecycle Environment failure injection are XCTest seams. No installed-app control for every intent/ack/drain/reservation cut or Stage A/B failure was found. Sleeps or unverified debugger recipes cannot establish exact crash cuts. Review only the smallest control needed by the selected scenario; do not build a new framework now.

Normal-build production qualification remains empty/off. An isolated candidate may test an explicitly labeled hypothesis, but `supportsCompleteDiscovery=true` is then an experimental input, not observed evidence. No fixture or subset capture qualifies production.

The armed-helper policy is already resolved by Step 4c, commit `cb15d40f`: the narrowly admitted Stage B safe-restart choice is **Exit — may reopen**, with a matching request/attempt pre-arm witness. Main read coordinator888–905. Do not reopen O14; verify this policy live later.

## Ordered live checklist (all currently not run)

| Order | Scope | Expected evidence / stop point |
|---|---|---|
| Baseline | Approved isolated gates-off candidate launch and normal provider use | Bind actual PID/start/path/stat/hash/provenance and lane; verify account-local targets. This does not qualify registry or recovery actions. |
| Discovery prerequisites | Real shims, actual app permissions/MCP/hooks, foreground/background tools, markers and complete discovery | Requires a reviewed real-path candidate and evidence for each supported pair. Missing access or one failed pair leaves coupled activation off. |
| Claude | Foreground tool then new tool; background child; unanswered stdio permission; in-flight CE MCP; startup hooks; dangling tool-use resume; fresh session-ID compatibility | Exact new-session identities, owned descendants and native history; no transfer of another profile's qualification. |
| Codex | Command in progress, then thread resume | Correct thread/turn association and no duplicate command; require actual interrupted app path. |
| Intent/delivery crash cuts | Before commit; commit-before-ack; ack-before-drain; direct Send; scheduled transfer | Respectively no success ack; one recoverable intent; full payload; held/unknown delivery; no duplicate. Exact cuts need verified boundary controls. |
| Other crash cuts | Mid-stream; quit Stage A; quit Stage B; reserved-before-identity | Honest interruption/staleness and unresolved ownership. Distinguish a failed/cancelled Stage A (app remains usable) from a killed process, which cannot remain usable until relaunched. |
| Shutdown failures | Stage A failure → Cancel → interact → quit; Stage B failure → Retry flush | Preservation and truthful failure UI. Existing unit seams do not prove live fault control. |
| Survivor/helper | Let finish/watch; explicit stop; uncertain armed helper | Signal only approved owned PID/birth identity, never by name; verify the already-decided uncertain-exit policy. |
| Recovery UI | Continue; Edit first; Send saved; answer as new input; reconciliation; fresh conversation | No automatic resend; same saved-message ID/chronology; failed send remains unsent at current end. CLI success does not prove button/accessibility behavior. |
| Preservation UI | Draft/attachments/queued input, historical question/edit review and child links, busy scheduled sends | Exact restored payload and honest historical/uncertain state; no replay of expired continuations or review application. |
| Final lifecycle/performance | Restart safely; Cmd-Q with several sessions; five-active-session quit, typing and commit latency | Approved actual app lifecycle, click counts and measured method. Targets remain advisory on this shared host, not fabricated from fixtures. |

Supported-pair source inventory (13, **not credentials or live coverage**): native standard Claude; compatible GLM/Kimi/custom; headless standard/GLM/Kimi/custom; Codex app-server and exec; ACP OpenCode/Cursor/Oh My Pi. Authority: `AgentProcessRegistrySupport.supportedPairs`, `ClaudeCodeRuntimeVariant`, `ACPProviderID`. Do not narrow this set or activate only a subset without a separate owner-approved design change.

## Restart-resilient evidence without new tooling

Use ordinary account-local files outside CE Application Support, not a new service. For each scenario record: candidate revision/dirty inputs, executable+helper hashes, UID, PID/start/path, approval scope, synthetic inputs/expected IDs, last completed operation, next permitted operation, observations and pass/fail/blocked result. Write intended action first and outcome afterward. A missing outcome is unknown, never an invitation to repeat an action. Rebind after every launch and reobserve after coordinator disconnect.

Keep raw process/history/protocol captures private, minimal and bounded; publish only sanitized evidence. Never record auth values, full environments, existing conversations or unrelated window titles. After all required live rows pass, production activation is a separate reviewed source decision and validation—not an automatic effect of this checklist.

## Guidance and scope decisions

[OracleA](pre-live-guidance-oraclea.md) and [OracleB](pre-live-guidance-oracleb.md) independently accepted the final non-lifecycle stopping boundary after source-audit corrections. Full responses and superseded suggestions are retained. Main selects a baseline-launch approval first, not blanket crash permission; no clean worktree solely for ceremony, no new tooling now, no unsupported assumption about external-app computer use.

Maintainer-guidance check: protect daily user state; source/tests establish current behavior, while actual runtime ownership and fresh native history remain the authorities. Build mismatch is directly observed; full-suite failure attribution is unresolved. Keep operations observable via conductor tickets and the external driver's plain evidence file. This handoff is preparation, not live acceptance.
