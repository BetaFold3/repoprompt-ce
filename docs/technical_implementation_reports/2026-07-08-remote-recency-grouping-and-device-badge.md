# Technical Implementation Report - 2026-07-08 - Remote Session Recency Grouping + Friendly Device Badge (S-A/S-B)

## Session Overview

Investigation → implementation → oracle-review cycle for two symptoms found during the 2026-07-08 remote-control e2e pass on `feat/remote-client-native`:

- **S-A (bug)**: a freshly started remote session grouped under "Previous" (not "Today") in the client sidebar, appearing under "Today" only transiently while streaming.
- **S-B (feature)**: the host-side "remote-controlled" session badge showed the raw 8-hex device ID ("cfb77037") instead of a friendly device name.

A deep investigation (context builder + pair investigator + oracle pressure-test; local artifact `docs/investigations/remote-session-recency-grouping-and-device-badge-2026-07-08.md`) produced root causes with file:line evidence. Implementation was fanned out across three delegated engineer workers in two file-disjoint waves (workers barred from building; orchestrator validated centrally via the conductor daemon). Two oracle review rounds: first returned **0 blockers / 3 majors / 5 minors**; all majors plus two cheap minors were fixed by the orchestrator; the follow-up review returned **"Approve — all three P1s closed, no new defects."**

## Implementation Details

### S-A — Remote sessions stuck under "Previous" (synthetic epoch timestamps)

**Problem Statement:**
`RemoteTranscriptProjector.item(from:logIndex:sequenceIndex:)` stamped every projected transcript row with `Date(timeIntervalSince1970: TimeInterval(sequenceIndex))` — January 1970. `applyTranscriptRows` then unconditionally recomputed `session.lastUserMessageAt` from item timestamps. A one-shot optimistic-timestamp rescue survived only the first projection: every re-projection (parked mid-run re-fetches and the settle-time complete page — guaranteed per run, confirmed in client logs) replaced the rescued row by deterministic ID with a fresh epoch copy. Since the sidebar bucket date is `threadActivityDate ?? lastUserMessageAt ?? activityDate`, the non-nil ~1970 value short-circuited every fresher fallback (`savedAt`/`lastActivityAt`), and the poisoned value persisted to disk (save paths recompute from item timestamps; cold restore trusts the non-nil field). Client-remote-only, including remote child sessions; host-side and local sessions unaffected.

**Solution Approach (three layers, oracle-pressure-tested):**
1. **Projector max-merge** (`RemoteTranscriptProjector.upserting`): when replacing an existing item by deterministic ID, keep `max(existing.timestamp, projected.timestamp)` via the new model-side `AgentChatItem.replacingTimestamp(_:)`. Preserves the optimistic-rescue timestamp across re-projections and self-heals old data if real wire timestamps ship later. "Always keep existing" was rejected because it would freeze already-poisoned items forever.
2. **Coordinator floor-filtered recompute** (`RemoteAgentModeCoordinator.applyTranscriptRows`): `lastUserMessageAt` recompute now ignores timestamps below `AgentSessionRecencySanity.syntheticTimestampFloor` and keeps the current value when nothing plausible remains. A blanket monotonic max was rejected (would pin after failRemoteSend/clear).
3. **Display floor** (new `AgentSessionRecencySanity`, floor = fixed literal 2020-01-01 UTC, `Date(timeIntervalSince1970: 1_577_836_800)`): applied to BOTH `freshestDate` inputs at the single choke point in `AgentModeSidebarSessionBuilder.sidebarRow` — the only protection for never-rescued rows (text-key rescue misses) AND the repair for already-poisoned persisted sessions. Deliberately NOT applied upstream: `sortDateByTabID[tab.id] != nil` doubles as `hasSentUserMessage` for row titles and must keep seeing raw values.

**Rejected alternative:** stamping projected rows with page-fetch time — the settle-time complete page would either regress (epoch) or falsely bump reconnect catch-ups to "Today", and varying stamps defeat the `updatedItems != previousItems` change guard, causing save churn.

### S-B — Friendly device name on the host badge (display-only)

**Problem Statement:**
The badge rendered the bare 8-hex from `AgentSessionOrigin.remote(deviceID:)` with no lookup. A durable friendly name exists host-app-side — `PairedDeviceRecord.displayName`, client-sent at pairing (defaults to the client's computer name) — but it is keyed by the `remote:`-prefixed ID while the badge carries the bare 8-hex, and every `RemotePairingIdentityStore` read paid Keychain get + lstat + full JSON decode with no cache. No fresher per-connection name crosses the wire (websocket hello payload is ticket-only).

**Solution Approach:**
- **Store memoization** (`RemotePairingIdentityStore`): validated registry cached under the existing recursive lock; installed on successful `save()` (the written registry just passed `validateRegistry`), nil'd on save failure; failed loads never cached; all security validation intact; multi-instance staleness trade-off documented.
- **Gated, TTL-cached VM map** (`pairedDeviceDisplayNameByBareIDForSidebar()`): only touches the store when a `.remote`-origin session is actually observed (live `sessions` ∪ `ownerValidatedSessionIndex`) — critical because the store's first Keychain access **mints the host signing key**, which a read-only render path must never trigger for users who never used remote control. Results (including failed loads — negative caching) memoized 30s in `sidebarPairedDeviceNamesCache`, keyed by the observed-device-ID set (mirrors the `sidebarRegisteredRemoteHostsCache` pattern).
- **Carrier/render threading**: `SidebarSession.remoteControlDeviceDisplayName` populated in the builder (lookup key = bare 8-hex via `MCPClientIdentity.remoteDeviceID(from: record.id)`), threaded through threaded-row copy, thread-collapse copy, sidebar view, and `AgentSessionRow`; new pure `AgentSessionRow.remoteControlDeviceBadgeText(deviceID:displayName:)` helper: label = `displayName ?? hex`, tooltip `"Remote controlled by <Name> (<8hex>)"` when known, legacy wording otherwise. Revoked devices stay named (badge is provenance, not authorization); unknown IDs fall back to hex. `AgentSessionSidebarContentFingerprint` gained `pairedDeviceDisplayNameByBareID` (explicitly passed) so pairing renames refresh the sidebar.
- **Non-goals honored:** no changes to `PairedDeviceRecord` schema, registry format, `AgentSessionOrigin` encoding, `MCPClientIdentity`, wire formats, or stored IDs.

## Files Modified

- `Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSessionRecencySanity.swift` (new) — synthetic-timestamp floor + `plausibleRecencyDate(_:)`
- `Sources/RepoPrompt/Features/AgentMode/Models/AgentChatModels.swift` — `AgentChatItem.replacingTimestamp(_:)` factory (below the memberwise init so new fields can't silently drop)
- `Sources/RepoPrompt/Features/AgentMode/Runtime/Remote/RemoteTranscriptProjector.swift` — max-merge timestamps on upsert-by-ID
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/RemoteAgentModeCoordinator.swift` — floor-filtered `lastUserMessageAt` recompute; rescue uses the shared factory
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeSidebarSessionBuilder.swift` — display floor at the `freshestDate` choke point; `pairedDeviceDisplayNameByBareID` context + display-name population/copy
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+SidebarSessions.swift` — gated/TTL-cached name-map helper; thread-collapse copy
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+SidebarUI.swift` — fingerprint passes the name map explicitly
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+Types.swift` — `SidebarSession.remoteControlDeviceDisplayName`; fingerprint field (pure `[:]` default)
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` — `sidebarPairedDeviceNamesCache` stored property
- `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentSessionRows.swift` — badge/tooltip/status-plate via pure `remoteControlDeviceBadgeText`
- `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentSessionsSidebarView.swift` — pass-through of the display name
- `Sources/RepoPrompt/Infrastructure/Security/RemotePairing/RemotePairingIdentityStore.swift` — registry memoization (install-on-save-success)
- 4 test files (below) + `Scripts/Fixtures/test-suite-contract-ledger.tsv` (13 surgical rows)

## Key Code Changes

Projector max-merge (the S-A core):

```swift
for item in newItems {
    if let existing = byID[item.id] {
        // Projected rows carry synthetic sequence-index timestamps; max-merge preserves the
        // optimistic-rescue timestamp across re-projections and self-heals if real wire timestamps ship later.
        byID[item.id] = item.replacingTimestamp(max(existing.timestamp, item.timestamp))
    } else {
        byID[item.id] = item
    }
}
```

Coordinator floor-filtered recompute:

```swift
session.lastUserMessageAt = session.items
    .filter { $0.kind == .user }
    .map(\.timestamp)
    .filter { $0 >= AgentSessionRecencySanity.syntheticTimestampFloor }
    .max() ?? session.lastUserMessageAt
```

## Technical Decisions

- **Max-merge over keep-existing** in the projector: behaviorally identical today, but self-healing once real wire timestamps exist; never falsely bumps reattached old sessions to "Today".
- **Display floor promoted from optional to required**: the only protection for never-rescued rows (wrapped-text rescue misses) and the only repair for already-persisted epoch values; floor at ~2020 (not 2001) closes the `turnOffset ≥ 979` post-2001 hole and the false-"Today" clamp tail.
- **Gate before store access**: `RemotePairingIdentityStore.registry()` mints the host P256 key on first Keychain access; a sidebar render path must not do that for non-remote users. Observed-device-ID gating gives zero store traffic in the common case.
- **Fingerprint receives the name map explicitly**: a worker's initial version used a side-effecting default parameter that called the store from the struct initializer on every fingerprint construction; replaced with a pure `[:]` default + explicit pass from the VM helper.
- **Multi-agent orchestration**: wave 1 = two file-disjoint workers (S-A core; S-B store), wave 2 = one worker for the shared sidebar seam; workers barred from building/testing; orchestrator validated centrally through the conductor daemon and applied all review fixes itself.

## Bug Fixes (oracle-review round, fixed before commit)

1. **Sidebar render minted the remote-control host signing key for every user** (major)
   - **Symptoms**: first sidebar fingerprint of every session performed Keychain write + P256 key generation + lstat on the main actor, even for users who never used remote control.
   - **Root Cause**: `registry()` → `hostPublicKeyInfo()` creates and saves the host key on `itemNotFound`; the new name-map helper called `listDevices` unconditionally.
   - **Fix Applied**: observed-`.remote`-origin gate before any store access.
2. **Failed registry loads were retried on every fingerprint pass** (major)
   - **Fix Applied**: 30s TTL memo including negative caching in `sidebarPairedDeviceNamesCache`.
3. **Duplicated 17-field `AgentChatItem` copy helpers** (major, silent field-drop hazard)
   - **Fix Applied**: single `AgentChatItem.replacingTimestamp(_:)` on the model; both private copies deleted.
4. **`save()` invalidated instead of installing the just-validated registry** (minor)
   - **Fix Applied**: `cachedRegistry = registry` on success (nil on failure), so `updateLastSeen` churn doesn't force Keychain+decode misses.
5. **Wrong worker test expectation**: linked sidebar entries render the TAB name by design (`sidebarEntry(from:tabID:tabName:)` substitutes it), so asserting the entry name failed; rewritten with a default-blank tab name ("T29") so a floor leak into title intent would surface as "New Chat".

## Testing

- Focused suites all green after every round: `RemoteTranscriptProjectorTests` 6/6, `RemoteAgentSessionTests` 38/38, `RemoteSidebarBadgingTests` 14/14, `RemotePairingIdentityStoreTests` 6/6.
- 13 new/extended test methods: projector max-merge both directions; second-reprojection clobber regression; synthetic-only rows preserve `lastUserMessageAt`; store cache coherence (upsert/revoke/external-file-change); builder name-map + thread-depth copy; recency floor (epoch→`savedAt` fallback + genuine-date passthrough + title intent); badge text helper; `SidebarSession` equality + fingerprint inclusion. 13 surgical ledger rows appended.
- `swift build --product RepoPrompt` clean; `make dev-format` / `make dev-lint` (SwiftFormat 0 pending, SwiftLint strict 0 violations).
- Oracle review ×2 on the working tree: final verdict "Approve — no new defects".

## Next Steps

### Immediate TODOs
- Live two-machine e2e smoke (user-run after push): fresh remote session groups under "Today" and stays there after the turn settles; previously poisoned sessions regroup by `savedAt`; host badge shows the pairing display name with hex in the tooltip.

### Technical Debt Introduced / Deferred (deliberate, oracle-acknowledged)
- **Archived-list / sortDates floor gap**: `AgentSessionRestoreSupport.sidebarSortDates`, VM `sessionListSortDate(for:)`, and archived sections still consume unfloored `entry.lastUserMessageAt`; already-poisoned ARCHIVED remote sessions still sort/bucket as 1970-era.
- **Unknown-device tooltip wording**: unknown branch shows the raw device ID and hyphenation differs from the friendly branch; pinned by test.
- **Preventive follow-up**: optional `ts` attribute on spartan transcript XML `<user>` rows (host-known real times); with max-merge in place it retroactively heals poisoned items. Store cache does not observe out-of-process writes (single-app-instance model, documented).

## Session Metrics
- **Files Changed**: 17 (16 modified + 1 new source file), +~580/−49 before review fixes
- **Components Affected**: AgentMode remote runtime (projector/coordinator), sidebar builder/types/views, chat item model, remote-pairing identity store
- **Delegated workers**: 1 investigation pair, 3 implementation engineers (2 waves), oracle (investigation chat, pressure-test, 2 review rounds)

## Lessons Learned
- Synthetic ordering data must never masquerade as wall-clock time: `sequenceIndex` belongs in `sequenceIndex`, not `timestamp` — once a fabricated date is non-nil it wins every `??` chain and gets persisted.
- Copy-with-one-field helpers for structs with `let` fields belong on the model next to the init; two independent 17-field copies is a silent field-drop bug waiting for the 18th field.
- Read-only render paths must be audited for side effects behind "read" APIs — a registry read that lazily mints a Keychain key is a write in disguise.
- A side-effecting default parameter on a value-type initializer hides real I/O from every construction site; pass dependencies explicitly.

> Generated from Claude Code session on 2026-07-08
