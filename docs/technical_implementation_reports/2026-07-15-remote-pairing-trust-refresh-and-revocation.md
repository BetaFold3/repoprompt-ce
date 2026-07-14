# Technical Implementation Report - 2026-07-15 - Remote Pairing Trust Refresh and Revocation

## Session Overview

This session diagnosed and fixed a native Remote Control onboarding failure where discovery and pairing completed successfully, but the newly paired controller was immediately persisted as **Revoked by host**. Forgetting the host and pairing again reproduced the same result.

Host gateway audit records confirmed the failure at WebSocket admission:

```json
{"code":"unknown_device","device_id":"remote:9ba3ebf2","op":"hello","outcome":"denied","ts":"2026-07-14T18:48:51.130Z"}
{"code":"unknown_device","device_id":"remote:65342414","op":"hello","outcome":"denied","ts":"2026-07-14T18:50:21.476Z"}
```

The implementation addressed both halves of the defect:

1. The gateway now refreshes its paired-device trust snapshot immediately after successful pairing instead of relying only on a 15-second poll.
2. The client no longer converts the transient `unknown_device` condition into durable host revocation.

A combined Oracle review approved the final source design. The user subsequently completed the native end-to-end pairing flow successfully.

The implementation was committed as `10429b1983feb2197eb6cf002d58620f4bf159c9` before this report was written. No app lifecycle operation or push was performed by the reporting session.

## Implementation Details

### 1. Client Revocation Classification

**Problem Statement:**

The gateway's first post-pairing WebSocket hello could return `unknown_device` while its cached trust snapshot was stale. The client classified both `unknown_device` and `device_revoked` as `.revoked`, called `markRevoked()`, persisted `revokedByHostAt`, and short-circuited every later connection.

A transient synchronization race therefore became a permanent local trust state.

**Solution Approach:**

`RemoteClientError.fromCommandError` now reserves durable revocation for the explicit `device_revoked` code. `unknown_device` is classified with other authentication failures:

```swift
switch code {
case "device_revoked":
    return .revoked(error)
case "binding_required":
    return .bindingRequired(error)
// ...
case "unknown_device",
     "invalid_ticket",
     "ticket_signature_invalid":
    return .authentication(error)
default:
    return .command(error)
}
```

`RemoteHostConnection` was updated at every sticky-revocation entrance:

- immediate WebSocket hello retry handling marks only `device_revoked`;
- uncorrelated `unknown_device` errors degrade the connection and schedule normal reconnect backoff;
- explicit `device_revoked` still fails pending work and persists revocation;
- ticket HTTP errors no longer use message substring matching.

Ticket response classification is now based only on a structured code:

```swift
static func classifyTicketHTTPError(statusCode: Int, data: Data) -> RemoteClientError {
    let object = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue
    let code = object?["code"]?.stringValue
    let message = object?["error"]?.stringValue
        ?? object?["message"]?.stringValue
        ?? object?["text"]?.stringValue
        ?? "Ticket endpoint returned HTTP \(statusCode)."

    if statusCode == 429 || code == "rate_limited" {
        return .rateLimited(message: message)
    }
    if let code {
        return RemoteClientError.fromCommandError(code: code, message: message)
    }
    return .transport(message)
}
```

This prevents unrelated prose containing words such as “revoked” from corrupting persistent trust state.

### 2. Immediate Serialized Gateway Trust Refresh

**Problem Statement:**

Pairing completion and ticket minting read fresh state from the host app, but WebSocket authentication used a gateway-local `GatewayTrustSnapshot` refreshed only by a fixed 15-second poll.

Immediately after pairing:

1. the app identity store contained the new device;
2. ticket minting succeeded;
3. the gateway authenticator still had the older snapshot;
4. the first hello was rejected as `unknown_device`.

Simply starting another asynchronous refresh was insufficient because an older periodic fetch could finish later and overwrite a newer post-pairing snapshot.

**Solution Approach:**

The new `GatewayTrustRefreshCoordinator` actor serializes the entire fetch-and-apply critical section for both periodic and event-driven refreshes:

```swift
actor GatewayTrustRefreshCoordinator {
    private let fetchSnapshot: SnapshotFetcher
    private let applySnapshot: SnapshotApplier
    private var refreshInProgress = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var stopped = false

    func refresh() async throws {
        await acquireRefreshSlot()
        defer { releaseRefreshSlot() }

        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let snapshot = try await fetchSnapshot()
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        await applySnapshot(snapshot)
    }
}
```

Gateway startup now constructs one coordinator around the existing trust fetch and revocation-aware apply logic. The periodic loop and successful pairing callback both call the same coordinator.

`GatewayPairingRelay` installs a post-completion action before the HTTP server accepts work:

```swift
await pairingRelay.setPostCompletePairingAction {
    do {
        try await trustRefreshCoordinator.refresh()
    } catch is CancellationError {
        // Gateway teardown owns cancellation.
    } catch {
        logger.warning("Remote gateway trust refresh after pairing failed: \(error)")
    }
}
```

After an app-link `complete_pairing` response succeeds, the relay awaits this action before returning HTTP success. Under normal operation, the controller cannot mint its first ticket and open its WebSocket until the paired device is visible to gateway authentication.

`stop()` marks the coordinator stopped and releases queued waiters. In-flight or queued refreshes recheck that state before applying, preventing trust publication after gateway teardown.

### 3. Structured Device Trust Errors End to End

**Problem Statement:**

Removing unsafe message heuristics exposed a separate integration gap. `mint_ticket` previously surfaced missing or revoked devices through generic MCP error prose. Without a machine-readable code, a genuinely revoked device would no longer become durably revoked on the controller.

**Solution Approach:**

`MCPRemotePairingToolProvider` now returns expected failures with explicit code and status:

```swift
guard let device = try dependencies.identityStore.device(id: deviceID) else {
    throw RemotePairingExpectedFailure(
        code: "unknown_device",
        message: "No paired device exists for \(deviceID).",
        status: 404
    )
}
guard !device.isRevoked else {
    throw RemotePairingExpectedFailure(
        code: "device_revoked",
        message: "Device \(deviceID) is revoked.",
        status: 403
    )
}
```

`GatewayPairingRelay` recognizes and preserves both expected codes:

- `unknown_device` with HTTP 404;
- `device_revoked` with HTTP 403.

The client can therefore distinguish transient absence from authoritative host revocation without interpreting human-readable text.

### 4. Trust Synchronization Observability

Trust synchronization failures were raised from debug-only logging to warning level. This addresses the original diagnostic gap where:

- the native client had no relevant `os_log` entries for the failing path;
- gateway logs were written through Swift Logging to inherited stderr;
- trust refresh failures were below the configured information threshold.

The gateway audit JSONL remains the authoritative admission record for exact hello denial codes.

## Files Modified

### Production

- `Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPRemotePairingToolProvider.swift` — emits structured `unknown_device` and `device_revoked` ticket failures.
- `Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteClientError.swift` — classifies only explicit `device_revoked` as durable revocation.
- `Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteHostConnection.swift` — removes sticky handling for `unknown_device`, removes text heuristics, and schedules normal recovery.
- `Sources/RepoPromptGateway/Auth/GatewayTrustRefreshCoordinator.swift` — adds serialized trust fetch/apply coordination and teardown guards.
- `Sources/RepoPromptGateway/main.swift` — routes periodic and post-pairing refresh through the coordinator and raises failure logging.
- `Sources/RepoPromptGateway/Server/GatewayPairingRelay.swift` — waits for post-pairing trust refresh and preserves structured trust errors.

### Tests

- `Tests/RepoPromptTests/Gateway/GatewayPairingRelayTests.swift` — covers refresh gating, denial behavior, and structured error preservation.
- `Tests/RepoPromptTests/Gateway/GatewayTrustRefreshCoordinatorTests.swift` — covers serialization, publication ordering, deterministic queueing, and stop/drain behavior.
- `Tests/RepoPromptTests/MCP/MCPRemotePairingToolProviderTests.swift` — covers structured missing-device and revoked-device ticket failures.
- `Tests/RepoPromptTests/RemoteHosts/RemoteHostConnectionTests.swift` — covers error classification, removal of text heuristics, nonpersistent `unknown_device`, trust refresh, and successful retry.

### Documentation

- `docs/investigations/remote-pairing-device-revoked-after-pairing-2026-07-15.md` — records evidence, ranked hypotheses, root-cause proof, and remediation options.
- `docs/technical_implementation_reports/2026-07-15-remote-pairing-trust-refresh-and-revocation.md` — this report.

## Bug Fixes

### Newly paired host immediately shown as “Revoked by host”

- **Symptoms:** discovery and pairing succeeded, but the host entry immediately displayed “Revoked by host,” “Last connected: Never,” and a recommendation to forget and pair again. Re-pairing reproduced the same state.
- **Root Cause:** WebSocket authentication read a gateway trust snapshot that could lag pairing completion by up to 15 seconds. Its `unknown_device` response was incorrectly treated as authoritative revocation and persisted by the client.
- **Fix Applied:** immediately refresh serialized gateway trust after pairing and classify `unknown_device` as recoverable authentication failure.

### Genuine ticket revocation lost after removing text heuristics

- **Symptoms:** source review found that a genuinely revoked ticket request was represented only by free-text MCP error output.
- **Root Cause:** the provider-to-gateway ticket failure path lacked a structured trust code.
- **Fix Applied:** propagate explicit `unknown_device` and `device_revoked` codes and HTTP statuses from the app provider through the gateway to the client.

### Relevant trust-sync failures absent from unified logs

- **Symptoms:** the supplied `log show` predicate returned no relevant client records.
- **Root Cause:** the failing code path did not emit through the queried logger, and gateway trust-sync failures were logged below the active threshold.
- **Fix Applied:** promote gateway trust-sync failures to warning level while retaining structured gateway audit records.

## Technical Decisions

1. **Only an explicit structured revocation is durable.** Transport errors, missing trust snapshots, and message prose cannot mutate persistent host trust.
2. **Fix prevention and recovery.** The gateway closes the normal staleness window; the client remains safe if synchronization still fails transiently.
3. **Serialize fetch plus apply, not only apply.** This prevents an older periodic fetch from publishing after a newer post-pairing refresh.
4. **Await refresh after successful pairing only.** Denied, expired, replayed, or otherwise unsuccessful pairing responses do not trigger trust work.
5. **Do not fail an already committed pairing solely because the follow-up refresh failed.** The failure is logged; the client remains non-poisoning and can recover on a later poll/reconnect.
6. **Preserve revocation authority.** Explicit host revocation continues to tear down connections and persist on the client.
7. **Use deterministic test gates.** Coordinator tests expose a DEBUG-only queue observation barrier rather than depending on `Task.yield()` timing.

## Challenges Encountered

### Distinguishing successful pairing from failed admission

- **Context:** pairing, ticket minting, and WebSocket authentication used different freshness boundaries. The UI symptom implied pairing rejection even though pairing had succeeded.
- **Resolution:** gateway audit evidence and code-path tracing isolated the denial to the stale WebSocket trust snapshot.

### Preventing a transient race from becoming permanent

- **Context:** fixing the gateway poll alone would reduce the race but leave the client vulnerable to future transient `unknown_device` responses.
- **Resolution:** the implementation changed both producer timing and consumer semantics.

### Avoiding stale refresh overwrite

- **Context:** an immediate refresh task could race with the existing 15-second poll.
- **Resolution:** one actor owns both fetch and apply, maintaining ordering across all refresh sources.

### Maintaining genuine revocation behavior

- **Context:** removing substring matching was necessary, but it also removed the only way generic ticket errors became sticky.
- **Resolution:** Oracle review identified the gap and the final implementation added structured provider and relay error plumbing.

### Tooling interruption during implementation

- **Context:** the root RepoPrompt MCP transport disconnected during implementation and the available worker environment exposed no shell/conductor runner.
- **Resolution:** work was split across focused client, gateway, and compile-risk workers. RepoPrompt diff artifacts and Oracle review were completed from a healthy worker session. Automated command execution was left explicitly unclaimed.

## Code Quality Improvements

- Centralized command-code classification in `RemoteClientError.fromCommandError`.
- Replaced message substring heuristics with structured protocol fields.
- Extracted trust refresh lifecycle and ordering into a focused actor.
- Reused the existing expected-failure boundary instead of introducing a parallel error envelope.
- Added deterministic concurrency test hooks compiled only in DEBUG builds.
- Added an integration regression that reproduces stale gateway trust, asserts the registry remains nonrevoked, refreshes trust, and reconnects successfully.

## Testing

### Automated regression coverage added

The implementation adds contracts for:

- `unknown_device` maps to authentication failure, not revocation;
- unstructured text containing “revoked” remains a transport error;
- structured `device_revoked` remains authoritative and sticky;
- a stale-snapshot hello does not set `revokedByHostAt`;
- refreshing trust permits a later hello to succeed;
- successful pairing waits for post-completion refresh;
- denied pairing does not refresh;
- provider and relay preserve exact trust codes and statuses;
- periodic and post-pairing refreshes cannot publish out of order;
- gateway stop prevents late snapshot publication.

### Review evidence

- Gateway-focused Oracle review: **APPROVED**, no Critical or Major findings.
- Combined client/gateway Oracle review: **APPROVE WITH FOLLOW-UPS**.
- Follow-up structured-error and deterministic-test changes: **APPROVE**, zero blocking findings.
- Final diff integrity review found no conflict markers, trailing whitespace, or unintended paths.

### Runtime acceptance

The user reran the native end-to-end flow after rebuilding and reported that the E2E test **passed**. This validates the original failing journey: host discovery, pairing, trust synchronization, and initial remote connection no longer produce the false “Revoked by host” state.

### Command-level validation limitation

The implementation workers did not have a shell/conductor execution tool, so they did not claim formatter, lint, focused XCTest, or product-build results. Those commands should be run separately if not already covered by the user's local validation:

```bash
make dev-format
make dev-lint
make dev-test FILTER=RemoteHostConnectionTests
make dev-test FILTER=GatewayTrustRefreshCoordinatorTests
make dev-test FILTER=GatewayPairingRelayTests
make dev-test FILTER=MCPRemotePairingToolProviderTests
make dev-swift-build PRODUCT=all
```

## Performance Impact

The new event-driven refresh adds one trust snapshot fetch and apply after successful pairing. Pairing is infrequent, so this cost is negligible relative to the reduction in failed tickets, rejected WebSocket handshakes, repeated forget/re-pair attempts, and delayed 15-second recovery.

Periodic trust polling remains in place. Serialization prevents overlapping refresh publication and therefore removes redundant out-of-order state transitions without adding continuous background work.

## Security Impact

The change strengthens the trust boundary:

- only machine-readable `device_revoked` can persist revocation;
- a generic service or error message cannot poison the paired-host registry;
- missing devices remain denied by gateway authentication;
- explicit host revocation remains authoritative;
- ticket errors retain exact status and code across the app-link boundary;
- shutdown guards prevent stale trust publication after gateway termination.

No cryptographic pairing, device proof, host-key pinning, ticket signature, counter, scope, or revocation authority was weakened.

## Next Steps

### Immediate TODOs

- Run the focused conductor validation matrix above if it was not already run outside this session.
- Observe warning-level trust-sync logs during future pairing failures.
- Retest explicit host-side device revocation to confirm the UI enters the intended durable revoked state.
- Consider adding request-correlated native client logging for pairing, ticket, and hello state transitions.

### Technical Debt

- Post-pair refresh failure is logged but does not change the already successful pairing HTTP response. This avoids falsely reporting committed pairing as failed, but a rare refresh outage can still produce a transient first-connection failure until the periodic poll succeeds.
- Coordinator waiters are intentionally simple and are not individually cancellation-aware. The queue is bounded by low-frequency poll/pair events, but this can be revisited if more event-driven refresh sources are added.
- Native client `os_log` coverage remains sparse for ticket and hello failures; the gateway audit file remains necessary for exact diagnosis.

## Session Metrics

- **Duration:** Multi-hour investigation, implementation, review, and E2E validation; exact wall-clock duration was not recorded.
- **Implementation Commit:** `10429b1983feb2197eb6cf002d58620f4bf159c9`.
- **Files Changed Before This Report:** 11 files, `+1,115/-61`.
- **Production Files:** 6.
- **Test Files:** 4.
- **Investigation Reports:** 1.
- **Components Affected:** host pairing provider, remote client error classification, remote host connection lifecycle, gateway pairing relay, gateway trust synchronization, gateway startup wiring, and focused regression infrastructure.
- **Runtime Result:** Native end-to-end pairing passed.

## Lessons Learned

- A successful write to authoritative host state does not imply that every cache used by the next protocol phase is current.
- Authentication absence and explicit revocation are different security states and must never share a durable UI classification.
- Human-readable error text is not a protocol contract.
- Event-driven cache refresh needs ordering against existing polling, not merely an extra task.
- The safest incident fix addresses both the race source and the client's failure semantics.
- Gateway audit records provided the decisive evidence when unified logging did not cover the relevant path.

> Generated from the implementation session on 2026-07-15 (Asia/Ho_Chi_Minh).
