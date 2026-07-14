# Investigation: Remote Pairing Setup and Onboarding UX

## Summary
Investigation complete. Under the revised greenfield, single-user, macOS-native-to-native constraints, the primary experience should be **Find Hosts on Tailscale**, not link import: the selected RepoPrompt build reads the local policy-visible peer map, probes only fixed RepoPrompt endpoints, verifies a nonce-bound canonical response signed by the app-owned host key, shows explicit zero/one/many confirmation states, and then reuses device proof plus host approval. The first slice should use one exact-Tailscale-IP listener per build; release/debug must have distinct ports, trust/persistence/runtime namespaces, and fallback URL schemes; a short-lived signed app-instance approval context replaces client-selected `window_id` and routes approval through a host-local window picker when needed. Raw JSON, migration compatibility, PWA/browser onboarding, and human codes are not first-phase product requirements.

## Symptoms
- Pairing requires copying a verbose JSON object containing gateway URL, host fingerprint, host name, public key, kind/version metadata, and window ID.
- The user must also provide or reconcile a Tailscale-reachable URL separately.
- The flow is easy to misunderstand, awkward across devices, and highly vulnerable to copy/paste or formatting mistakes.
- T3 Code appears to accept a single URL such as `http://100.122.229.108:3773/pair#token=8KPSFFPM4VC7`.
- Codex appears to offer a short uppercase code, aided by an existing authenticated subscription/account session.
- This investigation is read-only; no source changes are requested.

## Background / Prior Research
### Codex device authorization versus Remote Control
- The familiar short code is the Codex CLI/App Server OAuth device-auth flow (`codex login --device-auth`), not current Codex Remote Control pairing. The public example is `ABCD-1234`, entered at `https://auth.openai.com/codex/device`; the server returns a separate hidden `device_auth_id`, and Codex polls with both values. Source: [Codex App Server README, device-code login](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#L2036-L2048) and [`device_code_auth.rs`](https://github.com/openai/codex/blob/main/codex-rs/login/src/device_code_auth.rs#L19-L237).
- The CLI describes the code as one-time, expires its polling flow after 15 minutes, warns against unsolicited codes, and completes OAuth/PKCE before persisting tokens. Exact alphabet/entropy, server-side rate limits, and collision/replay implementation are not public contracts.
- Account authentication is the identity and authorization layer; the short code is only a rendezvous handle. An already-authenticated ChatGPT browser session makes the UX appear nearly frictionless.
- Current Codex Remote Control instead uses authenticated, one-to-one QR pairing between a ChatGPT mobile app and a Codex host. OpenAI does not publicly document the QR payload, lifetime, replay protocol, or key derivation. Source: [ChatGPT release notes, June 25, 2026](https://help.openai.com/en/articles/6825453-chatgpt-release-notes) and [Using Codex with your ChatGPT plan](https://help.openai.com/en/articles/11369540-using-codex-with-chatgpt).

### T3 Code pairing
- The authoritative implementation is [`pingdotgg/t3code`](https://github.com/pingdotgg/t3code), audited at commit [`c1ec1915`](https://github.com/pingdotgg/t3code/commit/c1ec1915fc16f3dc1ec5d47d9a97f6210a574526); its remote flow is documented in [`REMOTE.md`](https://github.com/pingdotgg/t3code/blob/c1ec1915fc16f3dc1ec5d47d9a97f6210a574526/REMOTE.md).
- T3 builds `/pair#token=<credential>`, prints/copies it, and shows a QR code. The shared parser reads the fragment first (query fallback), normalizes the endpoint, removes the secret from the visible URL with `history.replaceState`, and redeems it. Sources: [`startupAccess.ts`](https://github.com/pingdotgg/t3code/blob/c1ec1915fc16f3dc1ec5d47d9a97f6210a574526/apps/server/src/startupAccess.ts#L92-L147), [`remote.ts`](https://github.com/pingdotgg/t3code/blob/c1ec1915fc16f3dc1ec5d47d9a97f6210a574526/packages/shared/src/remote.ts#L144-L245), and [`PairingRouteSurface.tsx`](https://github.com/pingdotgg/t3code/blob/c1ec1915fc16f3dc1ec5d47d9a97f6210a574526/apps/web/src/components/auth/PairingRouteSurface.tsx#L41-L220).
- The credential is 12 characters from a 32-symbol ambiguity-resistant alphabet (60 bits), generated with cryptographic randomness and rejection sampling; it expires after five minutes and is atomically consumed once. Sources: [`PairingGrantStore.ts`](https://github.com/pingdotgg/t3code/blob/c1ec1915fc16f3dc1ec5d47d9a97f6210a574526/apps/server/src/auth/PairingGrantStore.ts#L236-L279) and [`AuthPairingLinks.ts`](https://github.com/pingdotgg/t3code/blob/c1ec1915fc16f3dc1ec5d47d9a97f6210a574526/apps/server/src/persistence/AuthPairingLinks.ts#L158-L186).
- Redemption produces a normally 30-day session/access token. Pairing grants can carry scopes; the UI offers permission presets, expiry/scopes, copy/link/token choices, QR, and revocation.
- T3 discovers Tailscale CGNAT addresses or uses `tailscale status --json` plus Tailscale Serve/MagicDNS HTTPS. It probes a well-known endpoint before advertising readiness. Sources: [`tailscale.ts`](https://github.com/pingdotgg/t3code/blob/c1ec1915fc16f3dc1ec5d47d9a97f6210a574526/packages/tailscale/src/tailscale.ts#L142-L336) and [`tailscaleEndpointProvider.ts`](https://github.com/pingdotgg/t3code/blob/c1ec1915fc16f3dc1ec5d47d9a97f6210a574526/apps/desktop/src/backend/tailscaleEndpointProvider.ts#L26-L98).
- T3 does not carry or verify an application-level host public key/fingerprint in the pairing link. Raw `http://100.x` trust rests on Tailscale routing/node authentication; MagicDNS Serve adds normal HTTPS hostname validation. This is simpler but materially weaker than RepoPrompt's explicit host-key pinning.
- Security trade-offs: the fragment avoids initial HTTP-request and normal Referer leakage but remains visible to page JavaScript, browser state/extensions, screenshots, QR capture, and clipboard sync; anyone holding an unused link can redeem it; the raw grant is stored in SQLite; a five-minute bootstrap becomes a much longer-lived bearer/session secret; ordinary UI proof-key binding and pairing-specific rate limiting were not established.

### Revised product constraints and platform facts
- The implementation is greenfield on this branch and currently has one user. Compatibility code for legacy raw JSON, permissive stored origins, or historical pairing links is not required; resetting branch-local pairing state and re-pairing is acceptable.
- The dominant controller is another native macOS RepoPrompt build, not a phone browser. This makes in-app tailnet discovery both feasible and preferable to browser/PWA or cross-device link handoff.
- Release and debug have distinct bundle IDs—`com.pvncher.repoprompt.ce` and `com.pvncher.repoprompt.ce.debug`—but `AppBundle/Info.plist.template:23` registers the same `repoprompt-ce` URL scheme for both. Apple documents that when multiple apps register one custom scheme, the target app is undefined; bundle-ID separation does not resolve handler selection. Source: [Apple custom URL scheme documentation](https://developer.apple.com/documentation/xcode/defining-a-custom-url-scheme-for-your-app).
- Release and debug also inherit the same default gateway port `47391` (`Scripts/package_app.sh:96-106`; `GlobalSettingsManager.swift:323-326`; `GatewayConfiguration.swift:4-6`). Concurrent remote gateways therefore need distinct deterministic ports or an explicit per-channel configuration.
- Tailscale officially exposes a machine-readable visible-peer map through `tailscale status --json`, including detailed peer metadata suitable for automation. MagicDNS assigns names to tailnet devices. Visibility is policy-constrained and netmap-trimmed, so discovery sees peers the controller is allowed to know about, not necessarily every administratively registered device. Sources: [Tailscale CLI](https://tailscale.com/docs/reference/tailscale-cli), [MagicDNS](https://tailscale.com/docs/features/magicdns), and [device visibility](https://tailscale.com/docs/concepts/device-visibility).
- The Tailnet Devices administration API can enumerate registered devices but requires account/admin credentials and is the wrong boundary for ordinary local onboarding. Discovery should use the local visible-peer map and require no Tailscale API token.

## Investigator Findings

### 1. Current host artifact is a presentation choice, not a protocol requirement

**Confirmed flow.** The host directly serializes a compact JSON object containing `v`, `kind`, `window_id`, `gateway_url`, `host_public_key`, `host_fingerprint`, and `host_name`:

```swift
let object: [String: Any] = [
    "v": 1,
    "kind": "repoprompt_remote_pairing",
    "window_id": windowID,
    "gateway_url": gatewayURL,
    "host_public_key": hostPublicKey,
    "host_fingerprint": hostFingerprint,
    "host_name": hostName
]
```

Evidence: `Sources/RepoPrompt/Features/Settings/Views/RemoteControlSettingsView.swift:20-43`.

The Settings UI shows the host fingerprint and, only under **Details**, renders that raw JSON in a read-only text box and as a QR, with **Copy Pairing Payload** and **Refresh** actions (`RemoteControlSettingsView.swift:176-221,352-369`). The QR therefore contains machine-readable JSON, but it is not an actionable browser URL or RepoPrompt deep link.

The descriptor currently derives its URL as:

```swift
gatewayURL: "https://\(globalSettings.mcpRemoteGatewayBindAddress()):\(globalSettings.mcpRemoteGatewayPort())"
```

(`RemoteControlSettingsView.swift:100-106`). This conflates three different values:

1. the NIO listener bind host/port;
2. the externally advertised origin;
3. the external TLS terminator.

The listener defaults are `127.0.0.1:47391` (`Sources/RepoPrompt/Features/Settings/Models/GlobalSettingsManager.swift:323-326,1029-1069`), those exact settings launch the gateway (`Sources/RepoPrompt/Infrastructure/MCP/ServerController.swift:464-487,517-525`), and the gateway listener is normally plain HTTP with external TLS termination (`Sources/RepoPromptGateway/GatewayConfiguration.swift:26-47`). Thus the default descriptor's `https://127.0.0.1:47391` is neither remotely reachable nor an accurate description of the local listener.

**Conclusion.** The verbose JSON and current QR are UI artifacts. A versioned URI envelope can carry the same descriptor without changing the pairing protocol or reducing identity information. Eliminated hypothesis: users do not need to see or separately manipulate every JSON field for the cryptographic flow to work.

### 2. Native import, URL replacement, pinning, and persistence

The native Add Host sheet explicitly requests JSON, parses on every edit, previews the pinned host/fingerprint, and then exposes a separate editable Gateway URL. Its help text tells users to replace loopback/LAN values with a Tailscale MagicDNS hostname (`Sources/RepoPrompt/Features/Settings/Views/RemoteHostsSettingsView.swift:276-319`).

`RemoteHostsSettingsViewModel` implements the current reconciliation:

1. trim and parse raw JSON;
2. copy the embedded URL into `gatewayURLString`;
3. let the user edit it;
4. rebuild the payload through `withGatewayURL`;
5. pair and persist the returned host record  
   (`Sources/RepoPrompt/Features/Settings/ViewModels/RemoteHostsSettingsViewModel.swift:185-249`).

`RemotePairingPayload` accepts JSON only and validates version/kind, HTTP(S), canonical lowercase fingerprint syntax, a valid P-256 host key, and exact equality between the supplied fingerprint and the SHA-256 fingerprint computed from that key (`Sources/RepoPrompt/Infrastructure/RemoteHosts/RemotePairingPayload.swift:13-31,66-94,106-125`; `Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteHostRegistry.swift:256-267`).

The native network flow is:

1. `POST {gateway}/api/pair/begin`;
2. require the response's host public-key bytes and fingerprint to exactly match the imported descriptor, and recompute the fingerprint;
3. load/create a per-host P-256 client key;
4. sign the canonical pairing ID, challenge, device identity/name/key, and scopes;
5. `POST {gateway}/api/pair/complete`;
6. require completion to return the expected device ID and exact device public key;
7. persist the selected gateway URL and pinned host public key  
   (`Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteHostPairingClient.swift:80-118,124-157,199-218,223-260`; proof contract at `Sources/RepoPromptRemoteWire/RemotePairingProof.swift:34-69`).

Later connections request `/api/ticket`, parse the host-signed ticket, and verify it using the persisted host public key before creating the WebSocket (`Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteHostConnection.swift:464-505`; `Sources/RepoPromptRemoteWire/RemoteTicket.swift:79-132`). This later ticket signature cryptographically ties the pairing authority to the pinned host private key (even if an endpoint is only relaying to that authority); `begin` itself exactly matches the imported public material but is not signed.

The client private key is Keychain-backed, intentionally survives failed/uncertain completion for retry, and is deleted on Forget (`Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteClientKeyStore.swift:19-28,55-108`). The paired-host registry stores the endpoint, pinned host key, device ID, scopes, counters, and revocation state in an atomic owner-only `0600` JSON file under a `0700` directory (`Sources/RepoPrompt/Infrastructure/RemoteHosts/PairedHostRecord.swift:3-48`; `RemoteHostRegistry.swift:19-41,149-183,229-247`).

**URL gap.** `RemoteHostRegistry.isValidGatewayURL` requires only `http`/`https` and a nonempty host (`RemoteHostRegistry.swift:249-254`). It does not reject userinfo, a non-root path, query, or fragment, and there is no central origin normalizer. Pairing, ticket, and WebSocket builders append paths to the stored value (`RemoteHostPairingClient.swift:279-288`; `RemoteHostConnection.swift:1005-1037`). A stored `https://host/prefix` therefore targets `/prefix/api/...`, while the gateway registers only root routes. `updateGatewayURL` exists but has no production caller (`RemoteHostRegistry.swift:110-121`), so visible recovery is currently Forget and re-pair.

**Conclusion.** Endpoint replacement and application identity are already separate in the native model. A link/import parser can reuse the exact existing validator and handshake. The endpoint must become a normalized origin-only value, but changing it must never change the pinned key.

### 3. Gateway relay, local AppLink, PWA, deep links, and relay seams

#### Gateway and app authority

The gateway exposes exactly `POST /api/pair/begin`, `POST /api/pair/complete`, and `POST /api/ticket` (`Sources/RepoPromptGateway/Server/GatewayPairingRelay.swift:22-31`). The relay copies only operation-specific fields and calls the app's `remote_pairing` tool; arbitrary MCP arguments are not passed through (`GatewayPairingRelay.swift:57-115,175-196`). The app tool requires a verified gateway-principal connection, never a claimed client name (`Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPRemotePairingToolProvider.swift:175-209`).

The type named `AppLinkSession` is **not** an Apple Universal Link or an onboarding link. It is the child gateway's local Unix-socket MCP connection back to the desktop app. The app creates a fresh launch-scoped credential and bootstrap token in the gateway environment (`ServerController.swift:507-525`); the gateway derives reconnect session IDs and sends the app-leg credential during the local bootstrap handshake (`Sources/RepoPromptGateway/AppLink/AppLinkSession.swift:97-105,326-334,386-405,472-490`). The app compares the credential in constant time and grants the privileged gateway principal only on an exact match (`Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift:1606-1633,4287-4296`).

Those credentials are separate trust boundaries:

- the bootstrap token is local session/reconnect identity;
- the app-leg credential grants gateway-principal authority;
- neither is a remote, scoped, expiring onboarding grant;
- exposing the app-leg credential would be a privilege escalation, not a UX improvement.

#### Existing native deep links

The app bundle already registers `repoprompt-ce://` (`AppBundle/Info.plist.template:23`), and `RepoPromptApp` sends incoming URLs to `AppDeepLinkRouter` (`Sources/RepoPrompt/App/RepoPromptApp.swift:122-128`). Current scoped routing covers agent-session links; other supported-scheme links fall into legacy open/prompt handling, and no pair/import route exists (`Sources/RepoPrompt/App/AppDeepLinkRoute.swift:188-217,243-262`; `Sources/RepoPrompt/App/WindowState.swift:1219-1268`). No Associated Domains/`applinks:` entitlement exists in the checked-in app resources.

This is a reusable **routing seam**, not a pairing implementation. A future pairing route must be parsed before legacy fallback, apply input-size/duplicate-parameter limits, and fail closed.

#### Current PWA

The gateway serves the PWA at `GET /`, plus fixed assets; `/pair` is currently not mapped (`Sources/RepoPromptGateway/Server/GatewayHTTPServer.swift:263-320`). The PWA calls same-origin begin/complete directly, generates a non-extractable P-256 key, persists the key/device in IndexedDB after completion, and stores tickets only in transient JS state (`Sources/RepoPromptGateway/Resources/pwa/app.js:86-126,156-246,300-325`).

It does **not** consume the descriptor. It displays `begin.host_fingerprint` from the same origin but has no independent expected host key/fingerprint to compare or persist (`app.js:160-176`). It also omits `window_id` from completion (`app.js:194-202`), while app-side approval routing requires a positive `window_id` and the relay forwards only what the caller supplies (`MCPRemotePairingToolProvider.swift:47-59`; `GatewayPairingRelay.swift:74-101,175-177`). This is an approval-routing gap for the checked-in descriptor-free PWA path.

A fragment descriptor would let the PWA compare the returned key and carry approval context, but there is an additional trust caveat: when the candidate gateway origin itself serves the JavaScript, an actively malicious/wrong origin also controls the code that reads the fragment and claims to verify the pin. Such a page can detect accidental routing mistakes, but it is not cryptographically equivalent to the trusted native client. Equivalent browser-side host identity requires either a trusted fixed-origin RepoPrompt web client, a separately authenticated/signed application shell, or an explicit accepted reliance on the HTTPS/tailnet origin plus host confirmation. Do not claim that host-served JS alone preserves the native pinning guarantee.

#### Other candidate primitives

- `RemoteRelayClient` is contract-only: there is no runtime conformer, directory, discovery, credential minting, or rendezvous service. Its credential is explicitly transport-only and cannot grant scopes or mint tickets (`Sources/RepoPromptGateway/Relay/RemoteRelayClient.swift:7-33,35-74`).
- The Phase 0 static token is a 32-byte durable bearer in secure storage (`Sources/RepoPrompt/Infrastructure/MCP/RemoteGatewayTokenStore.swift:4-48`). Static-token WebSocket auth is disabled by default and requires explicit developer opt-in (`GatewayConfiguration.swift:42-47,96-110,187-215`; `GatewayHTTPServer.swift:762-813`). It lacks normal device proof, one-time ticket, and scope semantics and must not appear in a link or code.
- Connection tickets are for already-paired devices, last at most 60 seconds, and require the paired device private key. They cannot bootstrap a new device.
- The existing pairing challenge is endpoint-issued, at most 60 seconds, in-memory, and consumed by completion. It is not a five-minute discovery invitation or short-code directory entry.

### 4. Endpoint discovery and advertising: what the gateway can and cannot know

The checked-in product has no Tailscale endpoint discovery. A case-insensitive source/test search for `tailscale` finds only the client help text instructing manual MagicDNS replacement at `RemoteHostsSettingsView.swift:315-317`. There is no CGNAT-range enumeration, `tailscale status --json`, MagicDNS lookup, Serve-status inspection, Bonjour discovery, public-origin setting, or candidate probe.

The gateway knows only its listener configuration (`GatewayConfiguration.swift:4-49,65-111`). It cannot infer which node-global Tailscale Serve route, external HTTPS port, tunnel, or reverse proxy reaches it. The existing `GET /healthz` response is only:

```json
{"status":"ok","service":"repoprompt-gateway"}
```

(`GatewayHTTPServer.swift:263-274`). It can distinguish RepoPrompt from HTML/T3 in an accidental misroute, but it contains no host key and is not an identity boundary.

The companion 404 investigation proved why readiness must validate the exact origin: the RepoPrompt gateway was healthy on `127.0.0.1:47391`, while the node's HTTPS root was routed by Tailscale Serve to T3 Code on `127.0.0.1:3773`, returning HTML and producing no RepoPrompt `mint_ticket` audit (`docs/investigations/remote-control-ticket-endpoint-404-2026-07-14.md:22-30,47-70`).

**Required future model.**

- The selected native client invokes a local Tailscale adapter and obtains the policy-visible peer map from `tailscale status --json`; it never scans the whole CGNAT range or requests an administrative API credential.
- Candidate generation is deterministic and small: exact visible Tailscale IPs plus fixed release/debug RepoPrompt ports first; optional MagicDNS/Serve candidates later. LAN remains explicit opt-in.
- Release and debug use distinct ports, endpoints, host/client identities, persistence namespaces, and bootstrap/process resources, and identify build channel/bundle/version in discovery responses.
- The feasibility spike uses one remote gateway listener bound to the exact detected local Tailscale IP and the build-specific port. It does not simultaneously add loopback, bind wildcard/LAN, follow arbitrary ports, or mutate Serve. Model the bind as a `ListenerSpec` so a second loopback channel can be added later without changing discovery or pairing protocols. Tailscale absence and address changes produce explicit unavailable/rebind states.
- Each probe sends a cryptographically random nonce to a versioned well-known route. The app constructs—not merely signs caller-supplied bytes—a domain-separated canonical response covering `repoprompt.remote-pairing.discovery.v1`, protocol version, exact nonce, host-authoritative normalized origin, host public key and fingerprint, host name, build channel/bundle/version, capabilities, and a short-lived opaque app-instance `approval_context`.
- The advertised origin comes only from authoritative host listener configuration, never the request URL, `Host` header, forwarded headers, or another caller-controlled field. The discovery client disables redirects and requires the signed normalized origin to equal the exact candidate origin it dialed.
- The client recomputes the fingerprint, verifies the signature and canonical fields, rejects wrong nonce/version/origin/build/context, and deduplicates multiple routes by fingerprint. Independently obtained Tailscale peer identity (device/DNS/IP) is displayed separately from responder-supplied RepoPrompt metadata rather than being blended into one identity claim.
- The discovery endpoint validates a fixed-size request and nonce, applies global and per-direct-peer quotas, caps in-flight signing work, uses short timeouts, and emits redacted aggregate audit metrics. It never accepts arbitrary bytes for app-key signing.
- Zero results produces actionable diagnostics and manual fallback; one result still requires confirmation; multiple results require explicit selection.
- Discovery returns one candidate per running app instance, never one per window. The opaque `approval_context` covers a random context ID, launch-instance ID, host fingerprint, bundle/build channel, authoritative origin, discovery nonce, and issuance/expiry times. `/pair/begin` validates the signed approximately-60-second context and binds it to the pairing challenge; the context only needs to be valid when pairing begins, may be refreshed immediately before begin, and is neither a credential nor a permission grant.
- After device-proof verification, an app-wide approval coordinator resolves live host windows: zero returns a structured retryable unavailable error, one routes approval there, and multiple presents a host-local window picker. If the selected window closes, the attempt fails with a structured stale-target error rather than silently moving to another window.
- Selection then feeds the existing pairing proof, explicit host approval, and completion flow. Discovery never grants scopes or persists trust by itself.
- For an already-paired fingerprint, rediscovery may offer pin-verified endpoint recovery before `RemoteHostRegistry.updateGatewayURL`.
- Tailscale configuration remains read-only. MagicDNS plus Serve is a later HTTPS/PWA route and conflicts are surfaced rather than overwritten.

A raw `http://100.x:port` endpoint is acceptable for the first native experiment because Tailscale encrypts the transport and the nonce signature plus existing ticket signatures preserve application identity. It is not a browser/PWA secure context, so the browser track remains separate.

#### Revised native user journey

**Host Mac**

1. Enable Remote Control in the intended release or debug build.
2. RepoPrompt detects its local Tailscale address and, for the first implementation slice, runs one channel-specific listener on that exact address and port; an absent or changed address produces an explicit unavailable/rebind state.
3. Settings shows **Discoverable on Tailscale**, build channel, endpoint, and short fingerprint. Listener details and raw JSON remain developer-only.
4. When a controller selects the host, RepoPrompt verifies device proof and resolves approval through the app instance: one live window receives the approval, multiple windows show a host-local picker, and no/stale windows return a retryable error. The approval overlay still shows the requesting device, requested scopes, client key/fingerprint, and host fingerprint.

**Controller Mac**

1. Open the exact RepoPrompt build that should own the pairing.
2. Select **Find Hosts on Tailscale**.
3. RepoPrompt reports a bounded search over visible devices and then shows:
   - no result: likely offline/policy/CLI/port causes plus Search Again and Manual Setup;
   - one result: host/build/endpoint/fingerprint preview and **Request Access**;
   - multiple results: one candidate per app instance, including separate release/debug instances on one Mac—not duplicate entries per host window.
   Tailscale peer/device/DNS/IP data is labeled separately from RepoPrompt-signed host/build/fingerprint data.
4. Selection obtains a short-lived app-instance approval context and starts the existing signed device-proof and host-approval flow; the context routes approval but grants no permission.
5. Successful pairing persists the host fingerprint and selected route; later discovery can recognize the host and propose verified route recovery.

The app must never claim that “one host found” means “the intended host authenticated.” It means one live RepoPrompt key owner responded among visible candidates; user confirmation and host approval complete the intent ceremony.

### 5. Existing lifetime, replay, scope, revocation, storage, audit, and abuse controls

| Boundary | Current behavior | Evidence |
|---|---|---|
| Descriptor/QR | Contains public endpoint and host trust material; no expiry, use counter, or revocation. Replay can initiate another approval request but cannot grant scopes by itself. | `RemoteControlSettingsView.swift:20-43`; approval/persistence below |
| Pairing challenge | 32 random bytes, URL-safe base64, 1–60 second TTL, in-memory, single-consume. It is consumed before proof verification and approval, so an invalid completion can burn an attempt; app restart forgets it. | `Sources/RepoPrompt/Infrastructure/Security/RemotePairing/RemotePairingCrypto.swift:49-52,107-116,222-291`; `MCPRemotePairingToolProvider.swift:229-253` |
| Device proof | P-256 signature binds pairing UUID, challenge, device ID, name, public key, and sorted requested scopes. | `RemotePairingProof.swift:34-69`; `RemotePairingCrypto.swift:171-220` |
| Host confirmation | Explicit blocking app overlay shows device ID/fingerprint, host fingerprint, and requested scopes; user may reduce scopes; nothing persists on denial. | `Sources/RepoPrompt/Infrastructure/UI/Components/RemoteDeviceApprovalOverlayView.swift:43-134`; `MCPRemotePairingToolProvider.swift:254-287` |
| Ticket | Existing non-revoked device only; scopes are intersected with stored grants; host-signed; positive lifetime capped at 60 seconds. | `MCPRemotePairingToolProvider.swift:290-323`; `RemoteTicket.swift:9-18,79-132` |
| Ticket replay | Gateway persists ticket ID as used before WebSocket acceptance; failure is fail-closed; used IDs survive restart through expiry and then compact. | `Sources/RepoPromptGateway/Auth/DeviceAuthenticator.swift:232-305`; `Sources/RepoPromptGateway/Auth/UsedTicketStore.swift:4-14,27-72,92-130` |
| Frame replay/scope | Every frame requires the device signature and same ticket/device context; counters strictly increase; operations are scope-gated. | `DeviceAuthenticator.swift:306-339,372-410`; `Sources/RepoPromptGateway/Auth/ScopeEnforcer.swift:24-75` |
| Revocation | Host marks the device revoked and clears push metadata. Gateway synchronizes trust every 15 seconds, closes links/WebSockets, removes push state, and the next frame fails after refreshed trust. | `RemotePairingIdentityStore.swift:138-149`; `Sources/RepoPromptGateway/main.swift:207-258`; `DeviceAuthenticator.swift:306-318` |
| Secure storage | Host and native device private keys use Keychain. Host/client registries and used-ticket ledger enforce owner-only files. PWA uses a non-extractable IndexedDB key, which same-origin JS can still invoke. | `RemotePairingIdentityStore.swift:64-99,160-215,254-289`; `RemoteClientKeyStore.swift:19-28,55-108`; `app.js:86-126,207-246` |
| Audit | Pair begin/complete/ticket outcomes are owner-only JSONL, retained by launch-file count; pairing records use device `unpaired`. Appends after startup are best-effort. | `Sources/RepoPromptGateway/Audit/RemoteAuditLog.swift:83-145`; `GatewayPairingRelay.swift:136-172,198-207` |
| Rate limit | Process-local/global-per-path: 12 requests per 60 seconds for begin and ticket only. Complete is not rate-limited; no per-source, per-invitation, account, or distributed limit exists. | `GatewayPairingRelay.swift:34-38,118-134` |

**Adjacent hardening found, not the onboarding root cause.** When a caller supplies `device_id`, the host validates only the `remote:<lowercase-hex>` syntax and does not require equality with the ID derived from the submitted public key (`MCPRemotePairingToolProvider.swift:382-390`). The proof still binds that chosen ID to the caller-controlled key and the native client uses/validates the derived ID, so this does not break the native flow. Before broad public invitation/code exposure, tighten the invariant and add coverage rather than relying on the stronger comment at lines 271-274.

### 6. Reusable pieces versus separate trust boundaries

**Reusable without changing trust:**

- the complete v1 descriptor and strict key/fingerprint validation;
- `withGatewayURL` as an advanced recovery seam;
- existing begin-response exact pin check;
- device challenge proof;
- explicit host approval and scope reduction;
- host/client Keychain identities and validated registries;
- host-signed one-time tickets, durable used-ticket ledger, frame counters, and revocation;
- the existing app deep-link router as an optional fallback seam after assigning distinct release/debug schemes;
- PWA packaging and gateway HTTP routing as a later browser track, after adding a real import route and trusted pin-handling design.

**New/separate boundaries:**

- a local Tailscale CLI invocation adapter plus defensively decoded visible-peer model;
- fixed, build-channel-specific candidate endpoint conventions, distinct release/debug ports, and an explicit listener specification/lifecycle;
- build-scoped trust and persistence namespaces so release/debug host fingerprints, client keys, registries, counters, revocation state, bootstrap sockets, and process leases cannot collapse into one instance;
- a signed, nonce-bound well-known identity endpoint with canonical origin binding and host-side abuse controls;
- a short-lived app-instance approval context plus app-wide live-window approval coordinator;
- bounded candidate probing, result deduplication by host fingerprint, and zero/one/many discovery UI;
- a five-minute invitation/grant store;
- a tailnet discovery coordinator;
- a cloud/account directory;
- a fixed-origin trusted web client;
- any actual relay runtime.

**Reject these shortcuts:**

1. do not remove the host public key/fingerprint and rely only on Tailscale node identity or HTTPS;
2. do not place the static token, app-leg credential, bootstrap token, or a connection ticket in onboarding artifacts;
3. do not call the current 60-second pairing challenge a reusable invitation;
4. do not use `/healthz` as host identity;
5. do not let host-served PWA JavaScript be described as equivalent to trusted native pin verification;
6. do not silently take ownership of or overwrite Tailscale Serve routes;
7. do not implement a 7–12 character code as a stateless encoding of the descriptor;
8. do not treat the contract-only `RemoteRelayClient` as existing infrastructure;
9. do not scan the entire `100.64.0.0/10` CGNAT range—enumerate only Tailscale-visible peers;
10. do not continuously scan in the background; discovery is an explicit, bounded user action;
11. do not automatically pair when exactly one host responds; still show identity and require confirmation.

### 7. Ranked UX/security options

| Rank | Option | Effort | Risk | Recommendation |
|---:|---|---|---|---|
| 1 | **Native Tailscale discovery**: the selected build runs `tailscale status --json`, enumerates only visible peers, probes documented build-specific endpoints, verifies nonce-signed host identity, and presents zero/one/many candidates | Medium–high | Low–medium | **Primary design.** It removes JSON, URL editing, copy/paste, QR, short codes, and Launch Services ambiguity from the dominant native-to-native journey while preserving the existing pairing authority. Discovery must be explicit, bounded, cancellable, defensive against Tailscale JSON changes, and followed by user confirmation and host approval. |
| 2 | **Direct tailnet reachability with per-channel ports** | Medium | Medium operational risk | Preferred first transport experiment for native clients. For the spike, run one listener on the exact local Tailscale IP with a different release/debug port and probe `http://<peer-tailnet-ip>:<channel-port>`; do not implement dual loopback plus Tailscale listeners yet. Keep listener configuration separable so a second channel is additive later. Tailscale provides encrypted transport while the app signature proves RepoPrompt identity. Never use wildcard/LAN bind as a shortcut. |
| 3 | **MagicDNS/Tailscale Serve endpoints** | Medium–high | Medium operational risk | Later HTTPS/browser-compatible route. Discover MagicDNS names and optionally inspect Serve status, but never overwrite node-global Serve routes. Prefer a documented RepoPrompt-specific port/route and surface conflicts such as T3 occupying the node's default HTTPS origin. |
| 4 | **Build-specific native import links**: release `repoprompt-ce://pair/v1?d=...`, debug `repoprompt-ce-debug://pair/v1?d=...` | Low–medium | Low | Keep as fallback for discovery failure or non-tailnet use. Do not let both bundles register the same scheme. An in-app Paste/Import path is also unambiguous because the user has already chosen the receiving build. |
| 5 | **Pin-verified endpoint recovery** | Medium | Low–medium | Re-run discovery for an existing fingerprint, verify the nonce signature and/or a host-signed ticket, then offer Change Endpoint without re-pairing. Never change the stored host pin when routing changes. |
| 6 | **HTTPS fragment link/QR to a browser/PWA** | Medium–high | Medium–high | Defer while native macOS is dominant. A host-served verifier is not independent of the candidate origin; native-equivalent enforcement requires trusted native/fixed-origin verifier code. |
| 7 | **Tailnet-local human code** | High | Medium | Usually unnecessary once discovery works. Consider only as a selector in very large tailnets; it remains a short-lived locator returning the full descriptor, not the 256-bit identity itself. |
| 8 | **Cloud/account-backed short code** | Very high | High/new service boundary | Defer until accounts/directories are strategic. The service remains rendezvous only and must not approve devices, grant scopes, or mint tickets. |
| 9 | **Unauthenticated public code directory or static-token flow** | High | Unacceptable | Reject. |

The primary native flow becomes: open the intended RepoPrompt build → **Find Hosts on Tailscale** → review one or more signed candidates → **Request Access** → approve on the host. Links and manual endpoints remain recovery surfaces, not the product's default onboarding path.

### 8. Greenfield scope and future implementation locations

**Greenfield strategy.**

- Do not build migration machinery for historical pairing links, raw-JSON onboarding, permissive stored URLs, or branch-local paired-host state. A one-time reset and re-pair is acceptable for this sole-user branch.
- Keep the cryptographic protocol invariants, not the accidental UI/storage formats: host key/fingerprint pinning, device proof, explicit host approval, scope clamping, signed one-use tickets, counters, and revocation.
- Make discovery the canonical onboarding path. Manual origin entry and in-app descriptor import are bounded recovery tools; raw JSON may remain only as a developer diagnostic.
- Use the local Tailscale visible-peer map rather than the administrative device API and never require a Tailscale API credential.
- Define deterministic, non-conflicting release/debug network endpoints and schemes. The build that the user explicitly opened owns discovery; no OS-wide handler selection is required in the primary path.
- Replace client-supplied `window_id` with a signed, short-lived opaque app-instance `approval_context`. Pair begin binds it to the challenge; after proof verification an app-wide coordinator chooses the only live window or shows a host-local picker. Zero windows, expiry, or a selected window closing return distinct structured retryable errors. Do not expose duplicate network candidates per window.
- Existing local records that violate the new strict origin contract may be forgotten and re-paired instead of migrated. Production data outside this branch remains untouched.

**Exact source locations to modify later.**

- Build/channel identity and URL-scheme separation:
  `AppBundle/Info.plist.template:7,23`;
  `Scripts/package_app.sh:84-106,303-306`;
  register `repoprompt-ce` for release and `repoprompt-ce-debug` for debug if fallback links are retained.
- Build-scoped trust and runtime namespaces:
  `Sources/RepoPrompt/Infrastructure/Security/RemotePairing/RemotePairingIdentityStore.swift`;
  `Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteHostRegistry.swift`;
  `Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteClientKeyStore.swift`;
  and the related Keychain service/account names, Application Support paths, revocation/counter state, bootstrap sockets, and process leases.
  Release and debug need stable but distinct host fingerprints, client identities, registries, and runtime resources before simultaneous discovery; bundle identifiers alone do not prove this isolation.
- Per-channel gateway endpoints and listener lifecycle:
  `Sources/RepoPrompt/Features/Settings/Models/GlobalSettingsDocument.swift:418-439`;  
  `GlobalSettingsManager.swift:323-326,1029-1069`;
  `Sources/RepoPrompt/Infrastructure/MCP/ServerController.swift:464-525`;
  `Sources/RepoPromptGateway/GatewayConfiguration.swift:4-47`;
  `Sources/RepoPromptGateway/Server/GatewayHTTPServer.swift`.
  The feasibility spike uses one `ListenerSpec` bound to the exact detected Tailscale address and a deterministic release/debug-specific port—not simultaneous loopback, wildcard, or LAN binding. Handle Tailscale absence, address changes, explicit rebind/relaunch, and both builds running concurrently. If local loopback or Serve is required later, add a second listener channel within the same gateway runtime instead of changing the discovery protocol or starting a second gateway process.
- Tailscale process invocation: use the existing `Sources/RepoPrompt/Infrastructure/Process/CLI` substrate to locate and execute the CLI with timeout/cancellation and bounded output.
- Tailscale visible-peer DTOs and orchestration: add typed decoding, candidate generation, probing, and pairing coordination under `Sources/RepoPrompt/Infrastructure/RemoteHosts`. Decode only required fields, tolerate unknown/missing fields, expose self/peer/DNS/IP/online metadata, derive only documented release/debug endpoints, apply concurrency/time bounds, support cancellation, and deduplicate verified responses by host fingerprint.
- Signed identity contract: add shared request/response and canonicalization types under `Sources/RepoPromptRemoteWire`; add a well-known HTTP route beside `Sources/RepoPromptGateway/Server/GatewayHTTPServer.swift:263-320`; relay only a validated nonce/context to the app; and add app-authoritative response construction/signing beside `Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPRemotePairingToolProvider.swift:212-227`. The host private key remains app-owned. The signed, domain-separated payload includes protocol version, nonce, authoritative normalized origin, host key/fingerprint, host/build/capability fields, and approval context; it never derives origin from the request and never signs arbitrary caller bytes. The client disables redirects and requires the signed origin to equal the exact origin dialed.
- Discovery-endpoint admission controls: extend the gateway relay/rate-limit boundary near `Sources/RepoPromptGateway/Relay/GatewayPairingRelay.swift:34-38,118-134` with strict body/nonce limits, per-direct-peer and global quotas, a small in-flight signing cap, short app-link timeouts, and redacted metrics.
- App-instance approval routing: replace the client-selected positive `window_id` dependency around `MCPRemotePairingToolProvider.swift:212-287` with a signed approximately-60-second opaque `approval_context`, bound at pair begin. Add an app-wide coordinator that returns structured zero-window/expired/stale-target errors, routes directly for one live window, and shows a host-local picker for multiple windows. The context is not a permission grant; existing device proof and explicit approval remain mandatory.
- Native discovery UX:
  `Sources/RepoPrompt/Features/Settings/Views/RemoteHostsSettingsView.swift:276-319`;  
  `Sources/RepoPrompt/Features/Settings/ViewModels/RemoteHostsSettingsViewModel.swift:185-249`.
  Replace the default JSON sheet with Find Hosts on Tailscale and explicit searching/none/one/many/error states; keep manual endpoint/import under Advanced.
- Existing pairing authority remains:
  `Sources/RepoPrompt/Infrastructure/RemoteHosts/RemotePairingPayload.swift:66-125`;
  `RemoteHostPairingClient.swift:80-260`;
  `RemoteHostConnection.swift:464-505`;
  `RemoteHostRegistry.swift:229-267`.
- Fallback native import only:
  `Sources/RepoPrompt/App/AppDeepLinkRoute.swift:188-217`;  
  `AppDeepLinkRouter.swift:17-73`;
  `RepoPromptApp.swift:122-128`;
  add a bounded build-specific pairing route only after discovery. In-app paste/import remains preferable when both builds are installed.
- Post-pair endpoint recovery: wire `RemoteHostRegistry.updateGatewayURL` at `RemoteHostRegistry.swift:110-121` only after rediscovery matches the stored fingerprint and proves possession of the corresponding key.
- Later PWA/HTTPS track: `GatewayHTTPServer.swift:263-320`, `Resources/pwa/index.html:107-130`, and `app.js:156-246,300-325`.
- Adjacent device-ID invariant before broader exposure: `MCPRemotePairingToolProvider.swift:382-390`.

**Tests to extend/add.**

- Tailscale status parsing fixtures: normal peers, missing/unknown fields, multiple IPs, offline peers, shared peers, malformed JSON, CLI absence, timeout, and process failure. The parser must tolerate the documented subject-to-change JSON shape.
- Candidate generation: release/debug ports, direct Tailscale IPv4 selection, optional MagicDNS candidates, no arbitrary port expansion, no whole-CGNAT scan, stable ordering, and deduplication.
- Signed identity contract: deterministic domain-separated canonical bytes; exact nonce; authoritative origin; computed key/fingerprint equality; build and capability fields; approval context; valid signature; wrong key/nonce/origin/build/context; replayed or expired response; malformed/oversized response; unsupported version; redirect rejection; `Host`/forwarded-header injection; relay attempts; exact dialed-origin equality; and minimal information disclosure.
- Discovery-endpoint admission: invalid nonce/body rejected before app-link work, per-direct-peer and global quota behavior, small in-flight signing cap, app-link timeout, cancellation, no arbitrary-data signing, and redacted metrics.
- Discovery orchestration: bounded concurrency, per-candidate timeout, cancellation, zero/one/many results, multiple routes for one fingerprint, separate display of Tailscale peer identity versus RepoPrompt responder identity, offline/wrong-service candidates, and partial success.
- Approval routing: one candidate per app instance; context binding at pair begin; expiry before begin; one live window; multiple live windows with host-local picker; zero windows; selected window closing before approval; structured retry for expired/stale targets; and no silent rerouting.
- Discovery view model/UI state: searching, no hosts, exactly one confirmation, multiple-host selection, known-host labeling, build-channel labels, manual fallback, and no automatic pairing.
- Listener lifecycle: exact-address binding, no wildcard, Tailscale absent at startup, address change and explicit rebind/relaunch, deterministic per-channel ports, and a later-additive second `ListenerSpec`.
- Release/debug coexistence: distinct bundle schemes, gateway ports, Keychain service/accounts, Application Support registries, host fingerprints, client keys, counters/revocation state, bootstrap sockets, and process leases; both candidates remain separately discoverable and no Launch Services dependency exists in the primary path.
- Existing pairing regression coverage remains authoritative after selection:
  `Tests/RepoPromptTests/RemoteHosts/RemotePairingPayloadTests.swift:7-77`;
  `RemoteHostsSettingsViewModelTests.swift:8-54`;
  `RemoteHostRegistryTests.swift:8-77`;  
  `RemoteHostPairingClientTests.swift:8-118`;
  `Tests/RepoPromptTests/Gateway/GatewayPairingRelayTests.swift:7-134`.
- Preserve existing security suites for host identity, device proof, tickets, gateway admission, counters, and revocation. Add supplied-device-ID equality with the ID derived from the public key beside `MCPRemotePairingToolProviderTests.swift:9-191`.
- Live validation, only after implementation is authorized: two Macs on one tailnet; production and debug concurrently with isolated trust stores/listeners; ACL-blocked host; host offline; Tailscale unavailable; address change plus explicit rebind; multiple live host windows and picker behavior; T3 occupying default Serve HTTPS; multiple RepoPrompt hosts; IP/endpoint change; and discovery fallback to manual pairing.

There is no dedicated remote-pairing spec under the current `docs/spec` tree. If implementation begins, create `docs/spec/remote-pairing-discovery.md` as the normative visible-peer, endpoint convention, signed-identity, UI-state, security, and fallback contract. Update the external-TLS/security sections in `docs/technical_implementation_reports/remote-control-gateway.md:214-220,274-287` and keep source placement consistent with `docs/architecture/source-layout.md:90-115`.

### 9. Eliminated hypotheses and final conclusions

- **Eliminated:** the raw JSON is required by the wire protocol. It is merely the current presentation of a valid descriptor.
- **Eliminated:** the current QR is already a working PWA/deep-link flow. It encodes inert JSON; the PWA ignores it.
- **Eliminated:** the product currently discovers Tailscale peers or validates RepoPrompt identity. No implementation exists today.
- **Eliminated:** discovery requires scanning the entire Tailscale CGNAT range. The local Tailscale visible-peer map supplies a bounded candidate list.
- **Eliminated:** distinct release/debug bundle IDs make one shared custom URL scheme reliable. Apple defines multi-handler scheme selection as undefined.
- **Eliminated:** release and debug remote gateways can safely share the default port while running concurrently.
- **Eliminated:** `AppLinkSession`, bootstrap/app-leg/static credentials, tickets, or the relay contract are discovery credentials or directories.
- **Eliminated:** `/healthz` proves host identity. It proves only that some RepoPrompt gateway answered.
- **Eliminated:** a short code can statelessly contain the descriptor or its 256-bit fingerprint.
- **Downgraded:** link/QR import as the primary macOS-native flow. It remains useful fallback, but creates avoidable transfer and build-handler ambiguity.
- **Downgraded:** browser/PWA onboarding while the dominant controller is native macOS.
- **Confirmed:** native Tailscale discovery is technically feasible using `tailscale status --json`, known RepoPrompt endpoints, and a nonce-signed identity response.
- **Confirmed:** discovery can identify a live key-owning RepoPrompt instance but cannot infer user intent; even one result requires preview/confirmation and host approval.
- **Confirmed:** routing and identity remain separate. A candidate route may change; the app-owned host fingerprint must not.
- **Confirmed:** the best first implementation is a discovery feasibility spike, then zero/one/many native UI, with build-specific links/manual endpoints only as fallback.

### Maintainer-guidance check

- **User impact and invariant:** the user opens the intended RepoPrompt build, selects **Find Hosts on Tailscale**, confirms a signed candidate, and requests access while the receiver still pins the exact app-owned host key and the host still approves scopes.
- **Root-cause confidence:** confirmed. Friction comes from exposing a DTO, requiring manual routing, and conflating listener/public origin; native tailnet visibility can remove the handoff entirely.
- **Authority:** the app-owned host key, pairing provider, approval manager, and device registry remain authoritative. Tailscale supplies visible routing candidates and encrypted transport, not RepoPrompt identity or permission authority.
- **State-safety:** this greenfield branch may reset local pairings, but production/debug identities, ports, schemes, and storage must remain distinct. Endpoint recovery requires the stored fingerprint.
- **Scale and observability:** discovery is user-triggered, bounded, cancellable, rate-conscious, and limited to visible peers and documented ports. Log aggregate diagnostics, not pairing artifacts or secrets.
- **Recommended scope:** first prove peer enumeration plus signed identity over direct tailnet endpoints; then add native discovery UI and existing pairing integration. Defer Serve, PWA, invitations, and account rendezvous.
- **Validation boundary:** offline parser/crypto/orchestration tests first; then coordinated two-Mac live tailnet validation with production/debug coexistence and failure cases.

**Read-only verification note.** Three focused explore probes traced descriptor/import UI, gateway/AppLink/PWA credentials, and host-key/endpoints. Load-bearing claims above were spot-checked against the cited source. No source, settings, Tailscale state, app lifecycle, or tests were changed/run in this investigation.

## Investigation Log

### Initial assessment - Descriptor presentation versus protocol requirements
**Hypothesis:** The long JSON is an implementation/presentation choice and could be wrapped in a single importable URI without weakening the existing pinned-key/fingerprint trust model.
**Findings:** The user-provided descriptor already contains all host identity and routing fields needed for a self-contained import artifact, while the separate Tailscale URL suggests the present UI does not fully normalize the reachable endpoint into that artifact.
**Evidence:** User-provided `repoprompt_remote_pairing` v1 descriptor and separate Tailscale URL requirement.
**Conclusion:** Requires tracing descriptor generation, parsing, persistence, endpoint normalization, and onboarding UI.

### Initial assessment - Short-code feasibility
**Hypothesis:** A 7–12 character human-entered code cannot safely carry the current descriptor and instead needs server-side rendezvous, authenticated account sync, or tailnet-local discovery.
**Findings:** The current descriptor carries a URL, host public key, and fingerprint far beyond the entropy/capacity of a short code.
**Evidence:** User-provided descriptor fields and the observed Codex/T3 comparisons.
**Conclusion:** Evaluate the trust, infrastructure, expiry, replay, privacy, and recovery trade-offs of each rendezvous model.

### Initial assessment - Candidate UX tiers
**Hypothesis:** Improvements can be staged: immediate single-link/deep-link import, then QR/universal clipboard aids, then optional short-code rendezvous or tailnet discovery.
**Findings:** A single URL can hide structured data from the user without changing the underlying handshake, while short-code lookup changes the system boundary.
**Evidence:** Common URI fragment/deep-link design and the user-provided T3 URL shape.
**Conclusion:** Must be validated against the current client/server and security architecture.

### External research - Codex comparison
**Hypothesis:** Codex Remote Control achieves its UX primarily through a 7–8-character code backed by subscription login.
**Findings:** The short `ABCD-1234` code belongs to Codex device authentication, where an authenticated OpenAI service maps a visible code plus a hidden device ID into OAuth/PKCE credentials. Current Codex Remote Control uses QR pairing instead.
**Evidence:** OpenAI Codex App Server/device-auth source and June 25, 2026 ChatGPT release notes linked above.
**Conclusion:** The useful transferable patterns are authenticated rendezvous, fixed verification destinations, expiry/one-time semantics, anti-phishing messaging, and QR handoff—not an assumption that the short code itself contains host connection or trust material.

### External research - T3 Code comparison
**Hypothesis:** T3's single-link UX can be copied directly without changing RepoPrompt's security model.
**Findings:** T3 combines endpoint and a 60-bit, five-minute, one-use bootstrap token in a fragment URL and adds QR/manual-token fallbacks, but it does not pin an application-level server identity. RepoPrompt's descriptor contains additional host-key/fingerprint trust material that T3 omits.
**Evidence:** T3 source links above, especially `startupAccess.ts`, `PairingGrantStore.ts`, `AuthPairingLinks.ts`, and `onboarding.ts`.
**Conclusion:** The single-artifact and QR UX patterns transfer; the exact payload and trust shortcuts should not. RepoPrompt can retain its pinned identity by encoding a compact descriptor or using an authenticated one-time rendezvous lookup.

### Oracle synthesis - Initial link-first scope refinement
**Hypothesis:** A custom URI alone is the smallest sufficient first release, and nonce-signed endpoint identity is a prerequisite.
**Findings:** A URI alone would encode the current loopback-derived URL more conveniently, so any link-first release would also need a distinct advertised origin and strict normalization. Existing native pairing already compares the imported key and later verifies host-signed tickets; signing proves possession of the key inside an artifact, not that the artifact came from the intended host.
**Evidence:** Oracle synthesis over the curated pairing/gateway/deep-link/security selection; spot checks at `RemoteControlSettingsView.swift:20-43,100-106`, `RemotePairingPayload.swift:66-125`, `RemoteHostPairingClient.swift:80-260`, `RemoteHostConnection.swift:464-505`, and `RemoteHostRegistry.swift:110-121,249-254`.
**Conclusion:** Correct for a link-first product, but superseded as the primary recommendation after learning that the branch is greenfield, has one user, has concurrent release/debug builds, and targets native macOS controllers.

### Revised synthesis - Native tailnet discovery
**Hypothesis:** The local Tailscale visible-peer map can remove the pairing artifact handoff entirely without weakening RepoPrompt identity.
**Findings:** `tailscale status --json` provides a bounded policy-visible peer list; RepoPrompt can probe only fixed build-specific endpoints and require a nonce-signed app-key identity response. The user has already selected the intended receiving build by opening it, avoiding shared-scheme ambiguity. Selection still requires confirmation because self-consistent signatures prove a live key-owning RepoPrompt instance, not user intent. Existing begin/complete approval and signed-ticket behavior remains authoritative.
**Evidence:** Tailscale CLI/device-visibility documentation; Apple custom-scheme documentation; `AppBundle/Info.plist.template:7,23`; `Scripts/package_app.sh:84-106`; gateway defaults at `GlobalSettingsManager.swift:323-326` and `GatewayConfiguration.swift:4-6`; existing host-key verification cited above.
**Conclusion:** Make Find Hosts on Tailscale the primary native flow. First prove peer parsing, per-channel direct endpoint reachability, and signed identity in a focused spike; then add zero/one/many discovery UI and reuse existing pairing. Keep distinct-scheme links/manual endpoints only as fallback.

### Oracle architecture review - Secure discovery and coexistence contract
**Hypothesis:** The revised discovery-first design was implementation-ready after choosing visible-peer enumeration and per-channel endpoints.
**Findings:** The direction was coherent, but five contracts needed to become explicit before implementation: canonical signed-origin binding and redirect rejection; true release/debug trust-store isolation rather than bundle-ID assumptions; app-instance approval context and multi-window behavior; host-side signing admission controls; and a concrete first listener topology. The smallest non-dead-end choices are one candidate per running app instance with a short-lived approval context plus host-local window picker, and one exact-Tailscale-IP listener for the feasibility spike with an additive listener abstraction for later loopback/Serve coexistence.
**Evidence:** Oracle review over the curated report/source selection, followed by focused synthesis choosing the app-instance and single-listener options. The resulting contracts are incorporated into Required Future Model, Finding 8, Recommendations, Preventive Measures, and the test map.
**Conclusion:** These are prerequisites, not compatibility embellishments: they prevent route-relay signatures, release/debug identity collapse, stale or ambiguous window routing, signing-path exhaustion, and premature multi-listener complexity.

## Root Cause
The main friction is not cryptographic. RepoPrompt exposes its pairing DTO as raw JSON, derives a supposed remote HTTPS URL from a loopback listener setting, and requires the receiver to supply routing information manually even though both Macs already participate in a Tailscale network that exposes a bounded visible-peer map. The existing client already knows how to pin the app-owned host key, prove its device key, obtain approval, and verify signed tickets.

The original link-first remedy would hide JSON but retain an avoidable cross-app handoff and is unreliable when release and debug both register `repoprompt-ce://`. Those builds also share gateway port `47391`, creating a second coexistence problem. Under the revised native-to-native constraints, the better remedy is to discover visible peers from inside the exact receiving build, probe distinct documented endpoints, verify live possession of the RepoPrompt host key with a nonce signature, and then invoke the existing pairing flow.

A short code remains unnecessary for the primary flow and cannot encode the 256-bit fingerprint. It may later act only as a selector/locator if discovery lists become unwieldy.

## Recommendations
1. Make release/debug isolation a prerequisite: distinct gateway ports, URL schemes, Keychain service/accounts, Application Support registries, host fingerprints, client keys, counters/revocation state, bootstrap sockets, and process leases. Do not assume bundle IDs alone isolate trust state.
2. Start with a focused feasibility spike: locate the local Tailscale CLI, parse `tailscale status --json` defensively, enumerate only visible peers, derive only fixed release/debug candidates, and prove a nonce-signed identity probe between two Macs.
3. For that spike, use one `ListenerSpec` bound to the exact local Tailscale IP and build-specific port. Do not implement simultaneous loopback, wildcard/LAN, or automatic Serve configuration. Prove unavailable/address-change/rebind behavior and keep the listener/runtime seam ready for an additive second channel later.
4. Specify the discovery signature before UI work: domain-separated deterministic canonical bytes covering version, nonce, host-authoritative normalized origin, host key/fingerprint, host/build/capability metadata, and an expiring app-instance approval context. Never derive the origin from request headers, sign arbitrary caller data, follow redirects, or accept a signed origin different from the exact candidate dialed.
5. Protect the new signing endpoint with strict request/nonce limits, per-direct-peer and global quotas, a small in-flight app-signing cap, short timeouts, and redacted metrics.
6. Replace `window_id` in the remote contract with a signed short-lived app-instance `approval_context`: bind it at pair begin, then resolve one live window directly or show a host-local picker for multiple windows. Return structured unavailable/expired/stale-target errors; never silently reroute or treat the context as approval.
7. Add the native **Find Hosts on Tailscale** flow with searching, none, one-confirmation, many-selection, error, and manual-fallback states. Display Tailscale peer identity separately from RepoPrompt-signed identity. Never pair automatically; after selection, reuse device proof and explicit host approval.
8. Deduplicate multiple routes by host fingerprint and mark previously paired fingerprints. Later use rediscovery for pin-verified **Change Endpoint** recovery.
9. Keep raw JSON as a developer diagnostic only. Add bounded in-app paste/manual endpoint fallback; add build-specific custom links only after discovery works. Defer PWA/browser onboarding, one-use invitations, human codes, and account rendezvous.
10. Use the exact source/test/spec map in Investigator Finding 8 as the pre-implementation contract.

## Preventive Measures
- Preserve one app-owned trust authority: exact host key, explicit consent, scope clamping, one-time tickets, counters, and revocation.
- Enumerate only the Tailscale-visible peer map; never scan all of `100.64.0.0/10`, request an admin API token, or probe arbitrary ports.
- Make discovery explicit, bounded, cancellable, and rate-conscious. Treat offline, policy-hidden, CLI-unavailable, wrong-service, and partial-success states as normal.
- Domain-separate and canonically sign the nonce, host-authoritative exact origin, host key/fingerprint, build/capabilities, and approval context. Disable redirects, reject request-derived advertised origins, recompute every fingerprint, and use `/healthz` only for diagnostics.
- Keep release/debug ports, URL schemes, Keychain identities/accounts, registries, host/client keys, counters/revocation state, bootstrap sockets, and process leases distinct. Test simultaneous stores/listeners and require distinct stable fingerprints.
- Return one candidate per app instance, not per window. Keep the approval context short-lived and non-authorizing; resolve live windows only after device proof, surface explicit expiry/unavailable/stale-target errors, and never silently reroute.
- Protect host signing capacity with strict body/nonce validation, per-peer and global quotas, bounded in-flight work, short timeouts, and app-constructed responses rather than arbitrary-data signing.
- Never auto-pair one discovered result. Show separately sourced Tailscale route identity and RepoPrompt-signed endpoint/build/fingerprint data, then preserve host-side approval.
- Keep Tailscale discovery/configuration read-only and surface Serve conflicts instead of overwriting routes.
- Log aggregate timing/result categories without host descriptors, signatures, pairing payloads, approval contexts, or credentials.
- Tighten supplied device-ID equality with the ID derived from the submitted key before broader discovery/invitation exposure.
- Validate first with offline fixtures and crypto/orchestration tests, then coordinated two-Mac tailnet scenarios including concurrent release/debug and multi-window approval.
