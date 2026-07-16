# Investigation: Remote Control Ticket Endpoint HTTP 404

## Summary
Investigation complete. Initially, Tailscale Serve sent the public HTTPS origin to T3 Code on `127.0.0.1:3773`, causing the ticket 404 while RepoPrompt remained healthy on `127.0.0.1:47391`. After T3 remote control was disabled and RepoPrompt was relaunched, the Serve table became empty rather than transferring the route to RepoPrompt; the client therefore changed to a pre-HTTP connection failure. Neither state is a regression from `55c784c1`.

## Symptoms
- Client UI reports: `Remote transport failed: Ticket endpoint returned HTTP 404.`
- Tailscale remains connected and otherwise functional.
- Host-side unified-log query for subsystem `com.repoprompt.agents`, category `RemoteControlClient`, over the last 30 minutes returns zero entries.
- Current branch is `feat/remote-client-native`; HEAD is `55c784c1 Fix workspace run-target status projection`.
- No source edits are requested; this investigation is read-only.

## Background / Prior Research

### Git archaeology
- No commit from `cac1560e^..55c784c1` changed the ticket path, relay route registration, listener bind/startup, gateway packaging, or app version behavior.
- `55c784c1` only changed workspace run-target status projection UI/tests/report/guardrail data.
- `d8cae488` changed WebSocket response/subscription recovery paths but not ticket HTTP routing or URL construction.
- The exact production ticket route remains `POST /api/ticket`, introduced by `7d12023f`; client URL construction appending `api/ticket` remains from `65c4b50b`.
- A matching route without a pairing relay returns `pairing relay unavailable\n`; an unmatched method/path returns `not found\n`. Production startup constructs and injects the relay.
- Historical assessment: the reported 404 is unlikely to be directly caused by the recent commit chain.

### Read-only host-state probe
- The visible RepoPrompt CE debug app is running bundle version `1.0.28 (29)`; its child `repoprompt-gateway` is listening on the configured/default `127.0.0.1:47391`.
- Direct `GET http://127.0.0.1:47391/healthz` returned HTTP 200 with `{"status":"ok","service":"repoprompt-gateway"}`.
- Tailscale is running/online, but `tailscale serve status --json` shows TCP 443 proxying to `http://127.0.0.1:3773`.
- Port 3773 is owned by `T3 Code (Alpha)`, not RepoPrompt.
- Read-only GETs through the current Tailscale HTTPS hostname returned HTML for both `/healthz` and `/api/ticket`, unlike the RepoPrompt gateway JSON health response. This conclusively identifies that hostname's current upstream as the wrong application, but does not by itself capture the failing client's stored origin or POST response.
- The current RepoPrompt gateway audit file contains no `mint_ticket` event, consistent with the client request never reaching the gateway relay.
- The host probe did not send a POST ticket request, so T3 Code's exact POST 404 response is inferred from the routing evidence rather than actively reproduced.
- No app lifecycle/settings/source changes were made.

## Investigator Findings
### 1. Failure boundary: HTTP ticket acquisition, before WebSocket admission

**Hypothesis:** Tailscale transport or the RepoPrompt WebSocket failed.

**Findings:** The native client first sends JSON with `POST <stored gatewayURL>/api/ticket`; only after a verified ticket is returned does it create the WebSocket. For a non-2xx response, the client attempts to decode JSON `error`, `message`, or `text`. Plain-text or HTML bodies do not decode, so any HTTP 404 from any responder becomes `Ticket endpoint returned HTTP 404.`, then `RemoteClientError.transport` renders the observed `Remote transport failed: …` UI string.

**Evidence:**
- HTTP response model and POST transport: `Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteHostConnection.swift:5-38`.
- Ticket request, non-2xx handling, and JSON fallback: `Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteHostConnection.swift:464-524`.
- User-visible transport prefix: `Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteClientError.swift:102-121`.

**Conclusion:** The failing path reached an HTTP responder and received an application-layer response. It failed before ticket verification, WebSocket creation/admission, hello, or session traffic. A Tailscale connectivity failure is eliminated as the direct failure mode; Tailscale can still be the routing layer that successfully delivered the request to the wrong application.

### 2. Primary cause: the current Tailscale HTTPS origin is routed to T3 Code

**Hypothesis:** The public Tailscale origin forwards to RepoPrompt's healthy gateway on `127.0.0.1:47391`.

**Findings:** A second read-only host-state check on 2026-07-14 reproduced the prior routing evidence without changing app or Tailscale state:

- `tailscale serve status --json` reports `tuans-mac.taildc6468.ts.net:443` with root handler `/` proxying to `http://127.0.0.1:3773`.
- `lsof` reports T3 Code listening on `*:3773`; `repoprompt-gateway` listens separately on `127.0.0.1:47391`.
- Process provenance resolves the 47391 listener to `~/Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/MacOS/repoprompt-gateway`, parented by that packaged RepoPrompt app.
- Direct `GET http://127.0.0.1:47391/healthz` returns `{"status":"ok","service":"repoprompt-gateway"}`.
- `GET https://tuans-mac.taildc6468.ts.net/healthz` returns HTTP 200 `text/html` and T3 page markup, not RepoPrompt's JSON identity.
- The packaged bundle reports `1.0.28 (29)`, and the running helper binary contains the `/api/ticket`, `pairing relay unavailable`, and RepoPrompt health-identity strings.

This topology matches the documented v1 architecture: the gateway defaults to loopback and depends on an external TLS terminator such as Tailscale Serve. The app launches the helper and supplies its bind address/port but does not own the external Serve table.

**Evidence:**
- Loopback defaults and external-TLS contract: `Sources/RepoPromptGateway/GatewayConfiguration.swift:4-35,65-91`; `docs/technical_implementation_reports/remote-control-gateway.md:214-220,274-287`.
- App-owned helper launch and environment: `Sources/RepoPrompt/Infrastructure/MCP/ServerController.swift:464-536`.
- RepoPrompt health response and exact HTTP dispatch: `Sources/RepoPromptGateway/Server/GatewayHTTPServer.swift:263-303`.
- Prior host-state evidence: this report's **Background / Prior Research → Read-only host-state probe**.

**Conclusion:** The current node-global Tailscale Serve configuration is definitively misrouted: HTTPS 443 reaches T3 Code on 3773 rather than RepoPrompt on 47391. This is the high-confidence cause of the client's observed ticket 404 and is not a Tailscale transport outage.

**Correlation limit:** The failing client's exact persisted `PairedHostRecord.gatewayURL`, the incident-time Serve snapshot, and T3 Code's actual `POST /api/ticket` body were not captured. Therefore the current hostname-to-wrong-upstream mapping is proven, while attribution of the specific 404 to T3 Code remains a high-confidence inference rather than a reproduced POST. Capturing the client record and sanitized response content type/body would close this gap.

### 3. Intended gateway dispatch and exact 404/audit behavior

**Hypothesis:** RepoPrompt's own pairing relay or app link returned the observed 404.

**Findings:** The intended path is:

1. `GatewayHTTPServer` removes the query from the request URI and exact-matches `POST` plus a root relay path.
2. `/api/ticket` dispatches to `GatewayPairingRelay.handle`.
3. The relay whitelists ticket fields, calls app-link tool `remote_pairing` with `op=mint_ticket` and `_rawJSON=true`.
4. `AppLinkSession` forwards the call over its authenticated app connection.
5. `MCPRemotePairingToolProvider` requires a verified gateway principal, validates the paired device/scopes, and signs the ticket.

**Evidence:**
- Exact route set: `Sources/RepoPromptGateway/Server/GatewayPairingRelay.swift:22-31`.
- Method/path dispatch, generic 404, relay response serialization: `Sources/RepoPromptGateway/Server/GatewayHTTPServer.swift:263-303,340-363`.
- Query stripping: `Sources/RepoPromptGateway/Server/GatewayHTTPServer.swift:460-463`.
- `mint_ticket` field mapping and relay call: `Sources/RepoPromptGateway/Server/GatewayPairingRelay.swift:70-114,137-172`.
- App-link forwarding: `Sources/RepoPromptGateway/AppLink/AppLinkSession.swift:149-225`.
- App-owned dispatch and ticket signing: `Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPRemotePairingToolProvider.swift:174-210,290-329`.

The distinguishable gateway outcomes are:

- Wrong method or unmatched path: HTTP 404, `text/plain`, body `not found\n`; no pairing audit.
- Matched relay path with `pairingRelay == nil`: HTTP 404, `text/plain`, body `pairing relay unavailable\n`; no pairing audit or app-link call.
- Relay app-tool rejection, including missing/revoked device: HTTP 400 JSON and `mint_ticket` audit `failure/app_tool_error`.
- App-link unavailable or relay codec failure: HTTP 503 JSON with `code=app_link_unavailable` and `mint_ticket` audit `failure/app_link_error`.
- Rate limit: HTTP 429 JSON and `mint_ticket` audit `denied/rate_limited`.
- Success: HTTP 200 JSON and `mint_ticket` audit `success`.

Production startup creates the audit log and app link, constructs `GatewayPairingRelay`, and injects it into `GatewayHTTPServer`; a nil relay is possible through the server's optional test/custom initializer, but not through the checked-in production construction path.

**Evidence:**
- Optional server initializer: `Sources/RepoPromptGateway/Server/GatewayHTTPServer.swift:9-40`.
- Production construction/injection: `Sources/RepoPromptGateway/main.swift:103-152,183-194`.
- Relay status and audit branches: `Sources/RepoPromptGateway/Server/GatewayPairingRelay.swift:118-172,198-207`.
- Best-effort JSONL writes: `Sources/RepoPromptGateway/Audit/RemoteAuditLog.swift:83-145`.

**Conclusion:** `pairingRelay` nil is a real alternate 404 shape but is low probability here; the public request currently bypasses RepoPrompt altogether, and the production path injects the relay. “Pairing relay unavailable” must not be confused with an unavailable app link—the latter is an audited 503, not a 404. The absent `mint_ticket` audit supports “request did not enter the relay” but does not prove it: generic-route and nil-relay 404s also bypass audit, and audit appends are intentionally best-effort.

### 4. Stored base-path mismatch is a latent alternate, not the leading incident cause

**Hypothesis:** The client persisted a non-root gateway URL and therefore requested a prefixed path that RepoPrompt could not match.

**Findings:** Gateway URL validation requires only `http(s)` and a nonempty host. It does not reject a path, user information, query, or fragment. The editable pairing URL is applied without origin normalization, the pairing client copies it into `PairedHostRecord.gatewayURL`, and the registry persists it verbatim. Pairing and ticket clients both use repeated `appendingPathComponent` helpers. Thus `https://host/prefix` becomes `/prefix/api/pair/*` during pairing and `/prefix/api/ticket` later, while the gateway accepts only root paths. A query does not create this route mismatch because the gateway strips it before dispatch; a URL fragment is not transmitted in an HTTP request.

**Evidence:**
- Payload decode/validation: `Sources/RepoPrompt/Infrastructure/RemoteHosts/RemotePairingPayload.swift:14-63,83-114`.
- Permissive URL validation: `Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteHostRegistry.swift:231-254`.
- Editable client URL and persistence flow: `Sources/RepoPrompt/Features/Settings/Views/RemoteHostsSettingsView.swift:309-317`; `Sources/RepoPrompt/Features/Settings/ViewModels/RemoteHostsSettingsViewModel.swift:149-156,179-245`.
- Pairing joins and verbatim record creation: `Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteHostPairingClient.swift:75-157,246-260,284-288`.
- Registry persistence/update: `Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteHostRegistry.swift:60-81,110-120`.
- Ticket join: `Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteHostConnection.swift:464-479,1005-1009`.

**Conclusion:** A stored path prefix remains the principal code-level alternate until the client record is captured. It is not the leading explanation for this incident because the probed public hostname itself demonstrably terminates at T3 Code. In addition, ordinary pairing through the same bad prefix should already fail before the record is persisted; a surviving bad prefix would more likely require legacy/directly written data or a later URL update. The existing `updateGatewayURL` method has no production caller.

### 5. Commit and deployed-helper checks do not support a source regression

**Hypothesis:** Commit `55c784c1`, or another commit in `cac1560e^..55c784c1`, changed ticket routing, startup, or packaging.

**Findings:** Independent git inspection found:

- `55c784c12bcdc7c11385590d885f56f48c36e0ee` changes only five run-target UI/test/report/guardrail files; no RemoteHosts, gateway, launch, or packaging file is present.
- In the full range, `RemoteHostConnection.swift` changes only subscription acknowledgement/reconciliation and `GatewayHTTPServer.swift` changes only post-send WebSocket `didQueueResponse` callbacks. Neither hunk touches ticket URL construction or HTTP routing.
- `Sources/RepoPromptGateway/main.swift`, `Sources/RepoPrompt/Infrastructure/MCP/ServerController.swift`, `Package.swift`, `Scripts/package_app.sh`, and `Scripts/build_swiftpm_release_products.sh` have zero changes in the range.
- The client endpoint originates in `65c4b50b`; the gateway ticket route/startup/packaging originate in `7d12023f`.
- Current source still matches `POST /api/ticket` on both sides, and the real-NIO connection test reaches app-side `remote_pairing/mint_ticket`.

**Evidence:**
- Current client/server contract: `Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteHostConnection.swift:464-524,1005-1009`; `Sources/RepoPromptGateway/Server/GatewayPairingRelay.swift:22-31,101-111`.
- Packaging contract: `Package.swift:105-113`; `Scripts/package_app.sh:232-290`.
- Real-NIO ticket flow: `Tests/RepoPromptTests/RemoteHosts/RemoteHostConnectionTests.swift:47-123`.

**Conclusion:** `55c784c1` did not introduce the failure, and reverting it would not alter Tailscale Serve state. A wrong/stale RepoPrompt helper is also not the primary cause because the public route does not reach that helper; independently, the actual 47391 listener is the packaged RepoPrompt helper, identifies itself correctly, and contains the ticket-route literals. Exact binary-to-HEAD equality was not established from the bundle version alone, and the remote client's binary provenance was not captured, but neither gap explains the proven external misroute.

### 6. Why the host-side `RemoteControlClient` log query is empty

**Hypothesis:** Zero host entries for subsystem `com.repoprompt.agents`, category `RemoteControlClient`, mean no ticket request was sent.

**Findings:** That OSLog category belongs to `RemoteAgentSessionController`, the app role consuming a remote host. Its messages concern remote starts, subscriptions, frames, transcript catch-up, and terminal state. `RemoteHostConnection.mintTicket` itself has no logger, so a failure before the session controller is active can produce the UI error without any entry in this category. The target gateway instead uses Swift Logging labels, bootstrapped to standard error, and durable/best-effort `RemoteAuditLog` JSONL; it does not emit inbound ticket activity under `RemoteControlClient`.

**Evidence:**
- Client category declaration and client-session messages: `Sources/RepoPrompt/Features/AgentMode/Runtime/Remote/RemoteAgentSessionController.swift:69-70,173-190,425-461,715-787`.
- Ticket method without logging: `Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteHostConnection.swift:464-524`.
- Gateway logging sink: `Sources/RepoPromptGateway/main.swift:103-107`.
- Pairing-relay diagnostic/audit: `Sources/RepoPromptGateway/Server/GatewayPairingRelay.swift:45-55,154-172,198-207`.

**Conclusion:** The host-side query targeted the wrong role/category and is expected to be empty. It provides no evidence for or against HTTP reachability. The gateway audit is the relevant host-side signal, subject to the pre-relay and best-effort limitations above.

### 7. Operational remediation and preventive locations

**Operational remediation:**

1. Establish one owner for the node-global Tailscale HTTPS route. Disable or reconfigure T3 Code's Serve integration if it will otherwise rewrite the root handler.
2. If RepoPrompt is to own the current 443 root origin, use the installed CLI's supported target form to point it at the loopback gateway: `tailscale serve --bg http://127.0.0.1:47391`. Do not change RepoPrompt to a wildcard bind to work around Serve.
3. If T3 Code must keep `:443 /`, give RepoPrompt a distinct Tailscale HTTPS port or Tailscale Service/virtual endpoint. Configure the client with that separate root origin; do not place RepoPrompt below a path prefix.
4. Verify `tailscale serve status --json` names `http://127.0.0.1:47391` for the chosen RepoPrompt origin, then verify `GET https://<origin>/healthz` returns JSON with `service=repoprompt-gateway`, not HTML.
5. Confirm the client record uses exactly that `http(s)://host[:port]` origin with no path/query/fragment/userinfo. Because the current UI exposes URL editing before pairing but no post-pair URL editor, use the supported forget/re-pair flow if the stored origin is wrong.
6. Run **Test Connection**. A successful path should mint a ticket, produce a `mint_ticket` audit record, complete ticket-authenticated WebSocket hello/ping, and disconnect.

Restarting the already healthy loopback helper, reverting `55c784c1`, or exposing port 47391 on a wildcard address is not remediation.

**Preventive source/test/doc locations:**

- **Origin-only URL contract:** strengthen/centralize validation near `RemoteHostRegistry.isValidGatewayURL` at `Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteHostRegistry.swift:249-254`; apply it in `RemotePairingPayload.swift:54-63,83-114`, `RemoteHostsSettingsViewModel.swift:149-156,218-245`, registry load/upsert/update, and the duplicated endpoint builders at `RemoteHostPairingClient.swift:284-288` and `RemoteHostConnection.swift:1005-1009`.
- **Gateway identity/error diagnostics:** preserve content type and a sanitized/truncated response-body signature in `RemoteHostConnectionHTTPResponse` and ticket mapping at `RemoteHostConnection.swift:5-38,464-524`; optionally probe `/healthz` before pairing/Test Connection via `RemoteHostPairingClient.swift:5-38` and `RemoteHostsSettingsViewModel.swift:300-329`.
- **Distinct gateway-local failures:** change the nil-relay outcome from ambiguous 404 to structured 503, add a stable service-identification header, and add method/path/status access diagnostics without bodies at `GatewayHTTPServer.swift:263-363`.
- **Host/public-origin separation:** stop advertising a bind-derived URL as if it were externally reachable; add an explicit advertised public origin around `RemoteControlSettingsView.swift:98-106`.
- **Tests:** add origin/path/query/fragment matrices to `Tests/RepoPromptTests/RemoteHosts/RemotePairingPayloadTests.swift:6-21`, `RemoteHostPairingClientTests.swift:7-70`, `RemoteHostsSettingsViewModelTests.swift:8-54`, `RemoteHostRegistryTests.swift:15-41`, and `RemoteHostConnectionTests.swift:47-123,543-561`. Add HTTP-level coverage for unmatched route, nil relay, HTML wrong-upstream mapping, service identity, and audit presence/absence beside `Tests/RepoPromptTests/Gateway/GatewayPairingRelayTests.swift:7-134` (or a focused new `GatewayHTTPRoutingTests.swift`).
- **Documentation/UI:** state “gateway URL is an origin only” and warn that Tailscale Serve ownership is node-global near `RemoteHostsSettingsView.swift:309-317` and the external-TLS/network-exposure sections at `docs/technical_implementation_reports/remote-control-gateway.md:214-220,274-287`.

**Ranked result:** (1) current Tailscale Serve conflict is the high-confidence root cause; (2) unknown client origin/path is the main correlation gap; (3) stored path-prefix mismatch is the principal code-level alternate; (4) nil relay/stale binary is lower probability; (5) Tailscale transport failure and a `55c784c1` routing regression are eliminated.


## Investigation Log

### Follow-up after disabling T3 remote control
**Hypothesis:** Relaunching RepoPrompt with `make dev-smoke-launch` would recreate the public Tailscale route.
**Findings:** Tailscale remains running and online, but `tailscale serve status --json` is now empty. RepoPrompt remains healthy on loopback port 47391, while the public HTTPS `/healthz` fails before HTTP with curl exit 7 / HTTP 000. T3 still listens locally on 3773 but is no longer exposed through Serve.
**Evidence:** Read-only live host probe after the user's T3 disable and RepoPrompt relaunch; `ServerController.swift:464-541` launches only the bundled loopback gateway; `GatewayConfiguration.swift:29-33` requires external TLS termination; `make dev-smoke-launch` only invokes `./conductor smoke --launch`.
**Conclusion:** Disabling T3 removed its Serve handler but did not create a RepoPrompt handler. The changed client error is expected: previously it reached the wrong HTTP server and received 404; now no server accepts the public HTTPS connection.

### Initial assessment - Failure boundary
**Hypothesis:** Tailscale connectivity itself failed.
**Findings:** The client receives an application-layer HTTP 404 from the configured ticket endpoint, which requires successful network reachability to an HTTP responder. The empty host `RemoteControlClient` category is not proof of no request because that category may be client-side only or the host may log ticket serving under a different category.
**Evidence:** User-provided client UI error and host unified-log output.
**Conclusion:** Tailscale transport failure is unlikely; route registration, URL/path construction, endpoint versioning, wrong listener/process, or stale host deployment remain plausible.

### Initial assessment - Candidate regressions
**Hypothesis:** The latest source or deployed-build change altered ticket routing or runtime configuration.
**Findings:** Recent commits are `55c784c1` (workspace run-target status projection), `d8cae488` (remote transcript delivery recovery), `dcdcaed9` (live-smoke deferred follow-ups), `be5d267a` (post-rebase remote validation gaps), and `cac1560e` (workspace-scoped remote control v1).
**Evidence:** Repository git log on 2026-07-14.
**Conclusion:** Requires commit-diff archaeology plus host runtime/version/config checks.

## Root Cause
The original failure occurred during HTTP ticket acquisition because the public Tailscale HTTPS hostname was routed to the wrong local application: T3 Code on `127.0.0.1:3773` instead of the healthy RepoPrompt gateway on `127.0.0.1:47391`. After T3 remote control was disabled, the current failure moved earlier: the Tailscale Serve table is empty, so the public connection is refused before HTTP. RepoPrompt's loopback gateway remains healthy, but no external TLS/Serve route forwards the client to it. This is an operational external-routing gap, not a checked-in regression from `55c784c1`.

Two confidence statements must remain distinct:
- The current Tailscale Serve routing conflict is proven by Serve configuration, listener ownership, and differing health-response identities.
- Attribution of the specific client-observed POST 404 to T3 Code is high confidence but not fully reproduced because the failing client's exact stored `gatewayURL`, incident-time Serve snapshot, and actual POST response were not captured.

## Recommendations
1. Before changing routing, save the current Serve status and capture the failing client's exact stored gateway origin.
2. Decide ownership of the node-global HTTPS root. If RepoPrompt should own it, first disable or reconfigure T3 Code's Serve integration, then point the chosen root origin to `http://127.0.0.1:47391`. Do not blindly reset Serve or overwrite unrelated handlers.
3. If T3 Code must retain `:443 /`, give RepoPrompt a distinct supported HTTPS port, Tailscale Service/virtual endpoint, or separate origin. Do not put RepoPrompt beneath a path prefix.
4. Keep the gateway loopback-bound. Do not switch it to a wildcard bind to bypass the proxy.
5. Verify the chosen external `/healthz` returns RepoPrompt JSON with `service=repoprompt-gateway`, and confirm the client URL is an origin only: no non-root path, query, fragment, or user information.
6. If the origin changed, use the supported forget/re-pair flow; otherwise re-pairing is unnecessary. Run **Test Connection** and verify a successful `mint_ticket` audit plus WebSocket hello/ping.
7. Recheck after T3 Code restarts to ensure its integration does not reclaim the route.

The smallest evidence needed to close the remaining correlation gap is the failing client's exact `PairedHostRecord.gatewayURL` captured alongside a Test Connection and contemporaneous Serve status. A sanitized content type/truncated body signature from the failing POST would make responder attribution definitive.

## Preventive Measures
1. Separate the loopback bind address from an explicit advertised public origin in `RemoteControlSettingsView.swift`.
2. Enforce a centralized origin-only gateway URL contract across pairing payload, settings, registry persistence, and both endpoint builders.
3. Warn in UI/docs that Tailscale Serve ownership is node-global and recommend a distinct origin—not a path prefix—for coexistence.
4. Preserve final URL/content type and only a sanitized, strictly truncated response signature for ambiguous client HTTP failures.
5. Use `/healthz` as a diagnostic before pairing/Test Connection or after ambiguous failures, not as an authentication boundary or mandatory per-ticket check.
6. Return structured HTTP 503 for a nil pairing relay and add safe method/path/status access diagnostics without request bodies.
7. Add focused HTTP-routing tests plus client HTML-404 and origin-validation matrices.

See Investigator Finding 7 for exact file and test locations.
