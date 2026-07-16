# Technical Implementation Report - Remote Control Gateway

**Date:** 2026-07-03
**Branch prepared for commit:** `feat/remote-control-gateway`
**Base:** local `main` at `09315bb`
**Report scope:** the uncommitted Remote Control implementation covering M0–M7, three fix passes, and the P2 follow-up pass.

## Executive Summary

This implementation adds RepoPrompt CE Remote Control as a separate `repoprompt-gateway` executable, plus the app-side trust, pairing, lifecycle, MCP hardening, PWA, Web Push, packaging, and test coverage needed to operate it safely.

The core design keeps the macOS app as the sole authority and keeps remote networking out of the GUI process. The gateway is a headless SwiftPM product that exposes HTTPS/WebSocket/PWA-facing surfaces and talks to RepoPrompt.app only through the existing bootstrap UNIX-socket MCP protocol using shared `RepoPromptMCPClientKit` client plumbing. Remote commands translate to existing `agent_run` / `agent_manage` MCP operations rather than introducing a parallel app-control protocol.

The implementation also hardens remote correctness: gateway and app-side request idempotency, explicit `session_update` / `session_terminal` / authoritative-only `session_expired` / `channel_closing` semantics, app-owned P256 pairing and host-signed short-lived tickets, DPoP-lite frame signatures, scoped device records, Web Push wake-only delivery, gateway supervision, and contract-only WAN relay/companion interfaces.

## Evidence and Limitations

- **Observed in session/user direction:** final task instructions require moving the uncommitted work to a `main`-based branch, writing this report, staging precisely, running commit preflight, committing, not pushing, not using stash, and not running visible app lifecycle commands.
- **Observed in local planning docs:** `docs/plans/remote-control-implementation-plan.md` records M0–M7 status, validation evidence, deviations, oracle findings, live-fix passes, and P2 follow-up work. That file is a local-only artifact and is intentionally not staged.
- **Observed in architecture investigation:** `docs/investigations/remote-control-architecture-2026-07-02.md` records the consensus architecture basis and RepoPrompt-specific findings. That file is also local-only and intentionally not staged.
- **Observed in code:** new and modified paths include `Sources/RepoPromptGateway/`, `Sources/RepoPromptMCPClientKit/`, app RemotePairing infrastructure, MCP hardening, packaging/workflow scripts, and focused tests under `Tests/RepoPromptTests/Gateway/`.
- **Validation evidence:** this report summarizes the validation evidence recorded in the implementation plan. Post-commit build/test validation is rerun separately after the commit.
- **Limitations:** this report reconstructs the implementation from repository state and local planning/investigation artifacts, not from the full original agent transcript.

## User Intent and Scope

The user intent was to make RepoPrompt CE controllable from a remote device without turning the macOS app into a public network server or creating a second control plane. Explicit constraints included:

- keep the app as the trust authority;
- put the network edge in a separate `repoprompt-gateway` process;
- reuse the existing bootstrap UNIX-socket MCP protocol for app control;
- support pairing, scoped tickets, session observation, interaction responses, PWA installability, and wake notifications;
- avoid APNs/native companion runtime in this repo for v1;
- land relay/companion work as contracts only;
- document known trade-offs and live-validation fixes for reviewers who have not seen the local plan docs.

## Consensus Architecture Research Basis

The architecture investigation compared OpenAI Codex, T3Code, Claude Code remote-control patterns, and nearby open-source analogues. The shared lessons applied here were:

1. **Local app/source of truth:** remote clients are projections; the host owns files, credentials, policies, and execution.
2. **Same control API locally and remotely:** T3Code and Codex reliability depends on not forking a separate remote-only command model.
3. **Pairing and scoped short-lived credentials:** Codex/T3Code-style QR or challenge flows with device-bound keys, short-lived tickets, monotonic counters, and one-time WebSocket admission.
4. **Idempotent commands:** remote networks retry; mutating commands need client request IDs and duplicate-safe replay behavior.
5. **Resumable observation:** Codex and T3Code rely on durable session state or replay/catch-up; RepoPrompt v1 uses live `agent_run wait` plus `poll`/`get_log` catch-up rather than a new event journal.
6. **Explicit lifecycle events:** Claude Code remote-control reliability issues highlight that remote clients should not infer app/session death from silence.
7. **Push as wake-only:** push notifications carry identifiers, not transcript or prompt state.

## Architecture

### Process and Product Topology

- `Package.swift` now defines a third executable product, `repoprompt-gateway`, backed by `Sources/RepoPromptGateway/`.
- `RepoPromptMCPClientKit` was extracted as a shared client-kit target for bootstrap socket transport, replay policy, socket reading, and device identity code used by both `repoprompt-mcp` and `repoprompt-gateway`.
- SwiftNIO/NIOSSL dependencies are direct dependencies of the gateway target only. The app target does not become a network server and does not gain NIO dependencies.
- Packaging, release product building, conductor product selection, Xcode workspace generation, CI workflows, layout validators, and resource checks were updated so the app bundle contains RepoPrompt, `repoprompt-mcp`, and `repoprompt-gateway` consistently.

### App Leg Over Bootstrap UNIX-Socket MCP

The gateway controls the app as an MCP client through the existing bootstrap UNIX-domain socket. App-leg handshake and tool calls use shared client-kit code, and gateway-originated tool calls centrally request machine-parseable `_rawJSON` output so formatter seams cannot break gateway parsing.

Remote operations map to existing app tools:

- `agent_run`: `start`, `steer`, `respond`, `cancel`, `poll`, `wait`;
- `agent_manage`: `list_sessions`, `get_log`, and related catch-up/listing paths;
- `remote_pairing`: gateway-only pairing/ticket/list/revoke operations on the app side.

### Gateway Principal and Supervision

The app launches the gateway with a launch-scoped credential passed through environment variables, not command-line arguments. Bootstrap admission verifies that credential and marks the connection as the trusted gateway principal. Gateway-only app tools are gated on this verified principal, never on the client-supplied `clientName` string.

Gateway supervision includes:

- parent PID and process lease file configuration;
- orphan reaping before spawn;
- bounded reconnect budget;
- exponential restart backoff with crash-loop budget;
- reset after stable runtime or settings reapplication;
- keepalive defaults for gateway and `remote:*` app-leg clients without changing ordinary client behavior.

### Trust Model

The app is the sole trust authority:

- host P256 signing key is stored through Keychain-backed app infrastructure and never exported to the gateway;
- paired-device records live in a dedicated validated file store with strict owner/mode/schema checks;
- device approval is user-mediated through app UI;
- scopes are app-granted and clamped when tickets are minted;
- device revocation is app-owned and synchronized to the gateway.

The gateway enforces, but does not mint trust:

- one-time host-signed connection tickets with TTL ≤ 60 seconds;
- device public-key verification;
- DPoP-lite per-frame P256 signatures over ticket/device/counter/payload hash material;
- strict per-connection monotonic counters;
- one-time ticket persistence to reject replay across gateway restarts;
- scope enforcement for observe, operate, respond, and future workspace-read operations;
- revocation-triggered connection teardown.

### Wire Protocol and Command Ledger

The remote wire is versioned JSON frames over WebSocket. Clients send `hello` first, then signed command/observe frames. The gateway answers with `hello_ack`, `command_result`, `command_error`, `session_update`, `session_terminal`, `session_expired`, `channel_closing`, `interaction_resolved`, and `pong`-style frames.

Mutating remote frames require `request_id`. Gateway `CommandLedger` keys outcomes by device and request ID, stores canonical payload fingerprints, records durable starts before app calls, and prevents duplicate mutation replay. Duplicate same-payload requests return the recorded outcome; different payloads under the same request ID return a conflict; in-doubt crash-recovery entries do not replay mutations.

App-side MCP hardening adds optional `request_id` handling for `agent_run start` / `steer` / `respond` so duplicate starts create one session, duplicate steers do not enqueue multiple prompts, and duplicate responses can return recorded resolution without weakening live VM fencing.

### Observation Model

The gateway does not add a new app event journal. Observation is intentionally three-tier:

1. **Live:** per-device `SessionWatchManager` multiplexes `agent_run wait` over watched session IDs and emits sequenced session frames.
2. **Catch-up:** clients use `list_sessions`, `poll`, and `get_log` to recover after reconnect, sequence gaps, app-link loss, or opening transcript history.
3. **Audit:** gateway-owned JSONL audit records device, request ID, operation, session ID, outcome, and short error code.

Key semantics established by fix passes:

- `session_expired` is emitted only from an authoritative app snapshot with `status == "expired"`.
- Transport errors, app-link disconnects, tool-call failures, and empty poll results pause observation and retry instead of expiring sessions.
- App-announced closing or reconnect-budget exhaustion maps to `channel_closing`.
- Indexed archived sessions can be surfaced as completed/control-unavailable snapshots instead of being deleted from the remote UI.
- `interaction_resolved` is explicit and includes provenance such as user, CLI, or `remote:<device8>`.

### PWA, Pairing Relay, and Web Push

The gateway serves static PWA assets from `Sources/RepoPromptGateway/Resources/pwa/` with no Node/Vite build toolchain. The PWA handles pairing/ticket flow, signed WebSocket frames, sessions list, transcript catch-up, respond/steer/cancel, push subscription, and binding-required UI affordances.

The pairing relay is field-whitelisted and only forwards app-authoritative pairing/ticket operations. It does not mint credentials. Web Push uses pure CryptoKit/Foundation implementation of VAPID and `aes128gcm` payload encryption. Push payloads are wake-only and contain identifiers such as kind, session ID, and optional interaction ID; prompt text, transcript text, workspace paths, file paths, model names, and approval context stay out of push payloads.

### WAN Relay and Native Companion Contracts

M7 intentionally adds contracts only:

- `Sources/RepoPromptGateway/Relay/RemoteRelayClient.swift` defines relay DTO/protocol boundaries.
- `docs/designs/remote-relay-contract.md` documents relay modes, E2E envelope shape, app trust boundaries, and native/APNs prerequisites.

No first-party relay runtime, native companion runtime, APNs entitlement, or provisioning changes are implemented in this branch.

## Milestone Summary

### M0 — Shared MCP Client Kit

`RepoPromptMCPClientKit` was added and bootstrap transport/replay/identity/socket-reader code moved out of the CLI-only target. Bootstrap DTOs were consolidated into `RepoPromptShared/MCP/MCPBootstrapMessages.swift`. Source-layout docs, guardrails, Xcode generation, and relevant MCP tests were updated so both `repoprompt-mcp` and `repoprompt-gateway` share one client implementation.

### M1 — Gateway Product, Packaging, and Lifecycle

`repoprompt-gateway` was added as a SwiftPM executable with gateway-only NIO dependencies, loopback-default configuration, `/healthz`, WebSocket server shell, `AppLinkSession`, settings integration, token storage, packaging/release/conductor/Xcode/CI integration, and app-side supervision with gateway-principal admission.

### M2 — Wire Protocol, Ledger, Observation, and Audit

Remote wire v1, `RemoteCommandTranslator`, `CommandLedger`, durable ledger store, `SessionWatchManager`, JSONL audit log, static-token developer mode, WebSocket sessions, backpressure rules, and gateway runtime command handling were implemented. Contract tests cover frame parsing, translation, idempotency, bootstrap tool calls, wait-loop behavior, persistence, and audit logging.

### M3 — App Pairing and Trust Store

The app gained RemotePairing infrastructure: scope vocabulary, paired-device records, strict file-backed identity store, P256 crypto, host signing key access, device approval queue/UI, and gateway-only `MCPRemotePairingToolProvider` operations for begin/complete pairing, mint ticket, revoke device, and list devices.

### M4 — Ticket, Signature, Scope, and Per-Device Links

The gateway now verifies app-minted tickets, persists used ticket IDs, enforces DPoP-lite per-frame signatures and monotonic counters, applies scope checks, keeps one app-link per paired device (`remote:<device8>`), tears down revoked devices, and surfaces app capacity/admission problems as explicit channel-closing errors. Static-token auth remains only behind an explicit developer flag.

### M5 — PWA and Web Push

A static PWA, PWA resource packaging, pairing/ticket relay endpoints, push subscription frames, VAPID key store, subscription store, Web Push encryption/service implementation, wake-trigger logic, and PWA resource tests were added. The implementation uses CryptoKit/Foundation rather than introducing a new Web Push dependency.

### M6 — Correctness Hardening

The app and gateway gained optional request IDs, app-side idempotency registry, explicit `interaction_resolved`, `channel_closing` control messages, `AgentSession.origin` provenance, remote-client namespace helpers with exact per-device policy isolation, and multi-window/workspace start selectors with `binding_required` behavior instead of guessing.

### M7 — Relay and Companion Contracts

Relay/companion work is intentionally limited to source-level protocol contracts and the `docs/designs/remote-relay-contract.md` design document. This freezes the integration seam without adding relay runtime, APNs, or native companion code.

## Hardening and Live-Validation Fixes

### Oracle Fix Pass

The oracle review identified security and reliability gaps that were fixed surgically:

- revocation leak/default app-link isolation;
- orphaned gateway supervision;
- multi-session `interaction_resolved` metadata;
- corrupt command-ledger quarantine instead of bricking gateway startup;
- stale binding probes;
- stale legacy `isMCPOriginated` metadata derivation;
- reserved TLS knob documentation;
- pairing-relay rate limiting;
- counter-floor anti-replay documentation;
- smoke harness restore/switch retry handling.

### `_rawJSON` Formatter Seam Bugs

Live validation exposed two gateway-to-app parsing failures where tool results were returned as fenced markdown instead of machine JSON. `GatewayPairingRelay` and trust synchronization initially omitted `_rawJSON`, breaking PWA pairing and trust snapshot refresh. The systemic fix moved `_rawJSON` injection into `AppLinkSession.callTool` so all gateway-to-app tool calls request machine-parseable output centrally while preserving explicit caller override.

**Invariant:** gateway tool results must be machine-parseable through central `_rawJSON` injection; individual call sites should not have to remember this formatter flag.

### App-Link Drop and Mass `session_expired`

Live Tailscale/PWA validation exposed a failure where ticket-authenticated devices received `hello_ack`, then a burst of `session_expired`, followed by `channel_closing {app_link_disconnected}` and mid-call connection errors. Root causes were semantic mismatches between `list_sessions` and `poll`, gateway treatment of transport errors as expiry, app-link liveness gaps, and cached failed per-device links.

Fixes established these invariants:

- indexed sessions without live control registration are surfaced as non-expired archived/control-unavailable snapshots when possible;
- `session_expired` is authoritative-only;
- transport/tool/app-link errors pause and retry observation;
- per-device gateway links get default progress heartbeat when global keepalive is unset;
- failed cached app links are recreated rather than reused inertly.

### P2 Follow-Up Pass

The P2 follow-up pass documented disk-only session polling limits, documented indexed non-terminal states surfaced as completed/control-unavailable snapshots, shared concurrent per-device app-link admission, fixed keepalive cadence, made the PWA account for `interaction_resolved` sequence numbers, and closed a wait-loop completed-task race.

## Security Review Notes and Accepted Trade-Offs

- **Revocation latency:** accepted as a bounded synchronization SLA, approximately tied to the trust-sync poll cadence; revocation tears down active links once observed.
- **Disk-only session poll gap:** `list_sessions` can expose disk metadata that `agent_run poll` may not fully hydrate immediately. Clients should use `agent_manage get_log` for durable transcript catch-up; archived/control-unavailable snapshots prevent destructive remote UI wipes.
- **Indexed archived sessions:** indexed sessions can be rendered as completed/control-unavailable even when their raw state was non-terminal. This is a pragmatic remote contract to avoid false expiry, with raw status text preserved where available.
- **External TLS termination:** gateway configuration carries TLS paths, but the v1 supported deployment path assumes external HTTPS termination such as Tailscale Serve/cert or a tunnel; TLS handler wiring is not treated as the primary trust boundary.
- **Loopback default bind:** `127.0.0.1` remains the default bind host. Wildcard/non-loopback exposure requires explicit opt-in and still relies on app-level pairing/scopes/signatures.
- **No new event journal:** v1 relies on `agent_run wait`, `poll`, `get_log`, persisted transcripts, and gateway audit JSONL. A second app event journal is deferred to avoid dual-source-of-truth drift.
- **Relay/companion:** relay cannot mint credentials; native companion/APNs work remains future/out-of-repo unless separately authorized.

## Validation and Testing Evidence

Validation evidence recorded in the local implementation plan includes:

| Area | Evidence |
|---|---|
| Product builds | `make dev-swift-build PRODUCT=RepoPrompt`, `PRODUCT=repoprompt-mcp`, `PRODUCT=repoprompt-gateway`, and `PRODUCT=all` passed at milestone and final validation points. |
| Packaging | `make dev-build` passed with three executable helpers and PWA resource-bundle validation. |
| Gateway suites | `make dev-test FILTER=Gateway` passed after M2/M4/M5/P2; suite includes wire, ledger, bootstrap contract, wait-loop, auth E2E, pairing relay, PWA resources, push, and persistence tests. |
| Auth/scopes | `GatewayAuth`, `GatewayAuthDeviceAuthenticator`, `GatewayAuthScopeEnforcer`, and real-NIO E2E contract tests passed. |
| Pairing | `RemotePairing` and `MCPRemotePairing` suites passed. |
| App hardening | `MCPRequestIdempotency`, `AgentRunMCPToolServiceWait`, `AgentSession`, and `MCPClientIdentity` suites passed. |
| Web Push/PWA | `WebPush`, `PWAResource`, VAPID, payload redaction, push trigger, and Web Push service/vector tests passed. |
| Style/layout | `make dev-format`, `make dev-lint`, and guardrails passed via coordinated daemon paths where required. |
| Live validation | Live Tailscale/PWA pairing/observe validation found the `_rawJSON` and session-expiry/app-link issues above; subsequent fix passes and a later coordinated smoke confirmation are recorded in the plan. |

Known unrelated/pre-existing validation noise recorded in the plan includes codemap fixture flakes, some full-suite/environmental failures, and unrelated test-ledger backlog. These were not modified by the remote-control work except where remote-control ledger rows were surgically added.

Post-commit validation for this branch is rerun separately with:

```bash
make dev-swift-build PRODUCT=all
make dev-test FILTER=Gateway
```

No visible-app lifecycle validation (`make dev-run`, `make dev-smoke-launch`, `./conductor app relaunch`, or `./conductor app stop`) is part of this commit preparation because the user is actively using the app.

## Change Inventory

The implementation is large, so related files are grouped by ownership and purpose. At report creation, these changes were still in the working tree and intended for a single curated feature commit.

| Git Status | Index / Worktree State | File / Group | File Role | Purpose | Evidence / Notes |
|---|---|---|---|---|---|
| Added | Untracked before staging | `Sources/RepoPromptGateway/**` | Source + PWA resources | Gateway executable, HTTP/WS server, app link, auth, ledger, audit, push, relay contracts, PWA assets | Observed in file tree/code structure. |
| Added | Untracked before staging | `Sources/RepoPromptMCPClientKit/**` | Source | Shared bootstrap MCP client kit for CLI and gateway | Observed in file tree/code structure and `Package.swift`. |
| Added/Modified | Working tree | `Sources/RepoPrompt/Infrastructure/Security/RemotePairing/**`, `RemoteControlSettingsView`, approval overlay | Source/UI | App-owned host key, device records, pairing crypto, approval UI, settings | Observed in code structure. |
| Modified/Added | Working tree | `Sources/RepoPrompt/Infrastructure/MCP/**`, `Sources/RepoPromptShared/MCP/**` | Source/protocol | Gateway principal admission, pairing provider, request idempotency, channel closing, bootstrap DTO consolidation, remote namespace behavior | Observed in changed paths and plan status. |
| Modified/Added | Working tree | Agent Mode runtime/view-model/session files | Source | Session origin/provenance, wait/poll metadata, interaction resolution, cleanup eligibility, remote session attribution | Observed in changed paths and plan status. |
| Modified/Added | Working tree | `Tests/RepoPromptTests/Gateway/**`, `Tests/RepoPromptTests/Security/RemotePairing*`, MCP/AgentSession tests | Tests | Focused contract and regression coverage for gateway, auth, pairing, Web Push, wait loops, idempotency, origin, keepalive | Observed in test tree and validation evidence. |
| Modified | Working tree | `Package.swift` | Build config | Adds `repoprompt-gateway`, `RepoPromptMCPClientKit`, NIO deps scoped to gateway, PWA resources, test target deps | Observed in `Package.swift`. |
| Modified | Working tree | `Scripts/**`, `.github/workflows/**` | Tooling/CI/packaging | Adds third executable to build/package/release/conductor/Xcode/workflow validation paths and smoke harness retry fix | Observed in diff/status and plan status. |
| Modified | Working tree | `Scripts/Fixtures/test-suite-contract-ledger.tsv` | Test ledger | Surgical rows for remote-control tests and rename maintenance | Observed in plan validation evidence. |
| Modified | Working tree | `docs/architecture/source-layout.md` | Documentation | Documents gateway/client-kit/source placement ownership | Observed in diff/status. |
| Added | Untracked before staging; force-add required | `docs/designs/remote-relay-contract.md` | Documentation/design | M7 relay/companion contract | Plan notes that `docs/designs/` is broadly ignored and this file must be force-added. |
| Added | Untracked before staging | `docs/technical_implementation_reports/remote-control-gateway.md` | Documentation/report | Durable self-contained implementation report replacing reliance on local-only plan/investigation notes | This file. |

Unrelated local-only artifacts intentionally excluded from this feature commit include `docs/plans/**`, `docs/investigations/**`, `prompt-exports/**`, and pre-existing unrelated untracked reports in `docs/technical_implementation_reports/`.

## Operational and Integration Impact

- **Dependencies:** SwiftNIO and NIOSSL become direct package dependencies for the gateway target. The app target does not directly depend on NIO.
- **Products:** SwiftPM now builds three executables: `RepoPrompt`, `repoprompt-mcp`, and `repoprompt-gateway`.
- **Runtime config:** gateway configuration includes bind host/port, static-token developer mode, app support root, bootstrap token/socket, gateway app-leg credential, parent PID, process lease path, reconnect budget, TLS path placeholders, and wildcard/static-token opt-ins.
- **Security storage:** app host signing key is Keychain-backed; paired-device registry, used tickets, command ledger, audit log, VAPID key, and push subscriptions use validated local files where security-sensitive.
- **Network exposure:** gateway defaults to loopback. Non-loopback operation should use explicit operator opt-in and external HTTPS termination such as Tailscale Serve/cert or tunnel.
- **Wire/API contracts:** RemoteFrame v1 is additive; clients must ignore unknown server frames. Pairing, tickets, relay, push payloads, `channel_closing`, `interaction_resolved`, and remote scope names are now reviewable contracts.
- **Backward compatibility:** existing local MCP/Agent Mode behavior remains authoritative; old sessions migrate to `AgentSession.origin` defaults.

## Risks, Limitations, and Technical Debt

- Live full end-to-end PWA/Web Push/Tailscale behavior was validated during implementation, but this commit-preparation pass does not rerun visible app lifecycle checks.
- Disk-only sessions listed from persisted metadata can still have a poll hydration gap; clients should use `get_log` for durable transcript recovery.
- Indexed non-terminal sessions shown as completed/control-unavailable are an accepted contract compromise and should be visible to remote UI users.
- Revocation is not instantaneous; it depends on synchronization/polling and explicit teardown once observed.
- TLS path configuration is present but v1 relies on external TLS termination as the supported path.
- Relay runtime and native companion/APNs remain future work.
- The wait-lane load risk is covered by multiplex contract tests, not by a measured 3-devices × 5-sessions load benchmark; a dedicated `remote_wait` lane remains a possible future optimization.
- Some unrelated repository flakes/backlog are documented in the plan and should not be conflated with this feature.

## Follow-Up Work

### Immediate / PR Review

- Review the staged commit as a single large feature or slice logically by M0–M7 if maintainers request smaller PRs.
- Ensure `docs/designs/remote-relay-contract.md` remains intentionally force-added despite the broad ignore rule.
- Record post-commit validation output for `PRODUCT=all` and `FILTER=Gateway`.
- When safe for the user, rerun visible app/gateway live smoke and PWA pairing/observe/push over the intended HTTPS path.

### Future

- Decide whether to wire first-party TLS handling or keep external TLS as the only supported deployment path.
- Define native companion/APNs scope if the project chooses to build a companion app.
- Decide relay build-vs-buy strategy and implement only after preserving the invariant that the relay cannot mint app credentials.
- Consider measured remote wait-lane load testing and a dedicated `remote_wait` admission lane if needed.
- Continue reducing unrelated test-ledger backlog and pre-existing codemap/full-suite flakes separately from this feature.

## Maintainer Notes

- The gateway should remain a thin translation layer over local MCP tools. Avoid adding remote-only app APIs unless they are first-class local MCP contracts too.
- Do not authorize gateway-only app tools by `clientName`; use the verified gateway principal.
- Keep host private key material in the app keychain. The gateway receives host public key/trust snapshots and app-minted tickets only.
- Keep push payloads identifier-only.
- Treat `session_expired` as an authoritative state, not a generic failure fallback.
- Keep `_rawJSON` injection centralized in `AppLinkSession.callTool` for gateway-to-app calls.
- If future relay work is added, preserve the M7 contract boundary: relay moves encrypted envelopes and cannot grant scopes or mint RepoPrompt tickets.

## Metrics

- **Files affected:** large multi-area feature; grouped inventory above. The pre-report working tree showed 76 modified files and 85 untracked files, including unrelated local-only docs that are intentionally excluded from staging.
- **Primary components affected:** gateway executable, shared MCP client kit, MCP bootstrap/control, Agent Mode session metadata/wait/idempotency, app RemotePairing trust store/UI, PWA/Web Push, package/release/conductor/CI tooling, focused tests.
- **Duration:** unknown from available evidence.
- **Validation status:** prior milestone/fix-pass validation is documented above; branch-local post-commit validation is performed after committing.
