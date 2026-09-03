> **Outcome (2026-09-03):** Implemented and validated the per-leaf thinking-accessory policy, added the live-captured OMP 18.1.3 catalog fixture and regression coverage, and updated the owning catalog contract.
>
> **Decision:** Family grouping remains presentational; effort-nil exact wire IDs may expose and execute runtime thinking selections, while explicit-effort wire IDs remain terminal. No wire-ID migration was added.

# Plan: Restore OMP runtime thinking accessory for effort-nil Cursor wire IDs

Scope: read when the task touches OMP model-menu projection (`OhMyPiModelMenuProjector`), the thinking accessory/eligibility seam (`OhMyPiThinkingSelections`, thinking menu surfaces), or OMP ACP catalog fixtures for collapsed Cursor models (Grok 4.5/4.6 base/fast pairs).
Authority: Authoritative
Last-verified: 2026-09-03

- **Status**: Planned — not implemented.
- **Date**: 2026-09-03
- **Origin**: Independent verification of a prior investigation session, two independent Oracle planning lanes (2-round adversarial exchange), and two live OMP 18.1.3 ACP probes.

## Problem

Grok 4.6 (Cursor provider via the OMP CLI ACP bridge) no longer shows a thinking-effort submenu in RepoPrompt's model pickers, and stored thinking values for it are silently dropped from execution assignments.

## Verified root cause

1. OMP PR #8988 (shipped by 18.1.3) collapsed Cursor Grok 4.5/4.6 effort-suffixed catalog IDs into logical base/fast pairs (`cursor/cursor-grok-4.6`, `cursor/cursor-grok-4.6-fast`) whose effort is controlled by the runtime ACP `thinking` config option.
2. `OhMyPiModelMenuProjector.qualifiesAsFamily` (OhMyPiModelMenuProjector.swift:259-281) classifies the collapsed pair as a suffix family (bare-base + stripped-sibling rule; `{nil} ∩ {nil}` normal/fast slot overlap).
3. `familyLeaf` (OhMyPiModelMenuProjector.swift:316-321) hard-codes `allowsThinkingAccessory: false`; `standaloneLeaf` (line 351) sets `true`.
4. Every thinking-submenu surface gates on that flag: `AgentModelOptionsMenuContent.swift:272` and `:930`, and `Features/Settings/Views/OhMyPiModelMenuBuilder.swift:107`.
5. Not UI-only: `OhMyPiThinkingExecutionEligibility.allowsAssignment` (OhMyPiThinkingSelections.swift:129-148) returns the same flag, so `assignments(for:)` suppresses stored values at send time.

## Live evidence (omp 18.1.3 ACP probes, 2026-09-03)

- Grok 4.6 appears as exactly `cursor/cursor-grok-4.6` ("Grok 4.6") and `cursor/cursor-grok-4.6-fast` ("Grok 4.6 Fast"); after selecting the base model the session advertises `thinking` values `off, auto, low, medium, high, xhigh`. Grok 4.5 is collapsed identically.
- The live catalog **still contains mixed families with bare members**: `cursor/gpt-5.1`, `cursor/gpt-5.2`, `cursor/gpt-5.2-codex`, `cursor/gpt-5.3-codex` each coexist with effort-suffixed and `-fast` siblings.
- Selecting bare `cursor/gpt-5.2` (a mixed-family bare member) **advertises runtime `thinking`** (`off, auto, low, medium, high, xhigh`) — so terminality for mixed-family bare leaves is a live correctness gap, not a hypothetical.
- Even the pure pair `cursor/composer-2.5` advertises `thinking` (`off, auto`).

## Decision (recommended policy)

**Per-leaf accessory predicate; grouping unchanged.** In `OhMyPiModelMenuProjector.familyLeaf`, derive the flag from the leaf's own wire ID:

```swift
allowsThinkingAccessory: entry.effort == nil
```

- A family leaf whose exact wire ID encodes **no** effort suffix (bare base, or bare `-fast`) gets the thinking accessory; the probe-fed capability registry remains the sole authority for which values exist.
- A family leaf whose wire ID encodes an effort (`-low` … `-max`, including `-none`, and their `-fast` forms) stays terminal.
- `qualifiesAsFamily`, `parseSuffix`, sorting, grouping, titles, `standaloneLeaf`, and all menu-builder/execution code are untouched.

Documented invariant replacing "family leaves are terminal": **a wire ID that encodes an explicit effort is terminal; an effort-nil wire ID may carry the runtime thinking accessory.**

## Material disagreement record

Two independent Oracle lanes received identical prompts and produced opposing policies; arguments (not identities) were cross-relayed for two rounds. Notably, **both lanes conceded to the other in round 1 and both reverted to their original positions in round 2**, so the disagreement formally survived the exchange:

- **Position A (per-leaf predicate — adopted)**: eligibility must be a pure function of the leaf's own wire ID because all related state (capability registry, selections, destination state) is exact-wire-ID-keyed; the alternative re-creates the regression's own failure mode (catalog drift → silent send-time drop) whenever upstream adds an effort sibling next to a pure pair; family-wide terminality was a coincidence of the 17.x era when family membership and effort-encoding were synonymous; hiding a live-advertised per-model option because a *different* wire ID ends in `-high` is unsupported inference.
- **Position B (family-demotion guard — not adopted)**: add `guard entries.contains(where: { $0.effort != nil }) else { return false }` to `qualifiesAsFamily`, so pure speed pairs demote to standalone (accessory via the existing standalone path) while mixed/sparse families stay fully terminal. Argued: the behavior delta then equals the confirmed regression footprint; no pinned thinking-surface tests invert; no stale stored values reactivate for mixed/sparse IDs; cleaner presentation (two sibling leaves instead of `Default > Default` nesting).

**Resolution — by post-debate evidence, not preference.** Two facts settle it in favor of Position A:

1. A fresh live probe (above) refutes Position B's core evidentiary premise ("no evidence a mixed-family bare ID advertises runtime thinking"): `cursor/gpt-5.2` is a live mixed-family bare member and advertises the full `thinking` ladder. The true regression footprint therefore *includes* mixed-family bare leaves, so Position B's own "delta = footprint" criterion selects Position A. Upstream itself exposes both effort mechanisms simultaneously (bare + runtime thinking, and effort-suffixed IDs); hiding one is editorializing over the provider's contract.
2. Position B's "inverts zero pinned tests" claim is false: `OhMyPiModelCatalogTests.testProjectorEnforcesAdversarialParsingCorroborationAndStableOrdering` (Tests/RepoPromptTests/AI/OhMyPiModelCatalogTests.swift:307-310) pins `ns/pair` + `ns/pair-fast` as `isFamily == true` with Default/Default titles; the guard flips that grouping contract plus all pure-pair presentation. Both policies invert pinned tests, neutralizing that argument; Position A's inversions are confined to accessory flags while grouping stays byte-identical.

**Residual costs of the adopted policy, accepted deliberately:**
- Previously suppressed stored values for effort-nil family IDs (e.g. `provider/sparse-fast`-shaped, mixed-family bare IDs) resume being sent. Live evidence shows those IDs advertise runtime thinking; a policy-independent hardening (emission-time capability validation) is filed as follow-up, not a blocker.
- Mild UX redundancy in mixed families (runtime `High` under the bare leaf next to a terminal `-high` sibling). These are distinct upstream wire IDs with independently keyed state; no double assignment can occur (effort-suffixed leaves stay terminal, and only one model is selected per destination).
- `Default > Default` nesting for the collapsed pair (outer = family slot without effort suffix; inner = no runtime assignment). Cosmetic; any relabeling is a separate cross-surface UX change.
- Known drift-asymmetry: an *uncorroborated* standalone `model-high` still flips terminal if corroborating siblings later appear. This suffix-ambiguity resolution is pre-existing, applies to IDs where stored runtime-thinking values are semantically dubious anyway, and is pinned by a new test (below).

**Consensus items (both lanes, all rounds):** the projector flag is the single seam (no changes to menu builders or `OhMyPiThinkingSelections.swift`); no Grok/model-name allowlist; keep `models-17.3.4.json` untouched and add an 18.1.3 fixture beside it; update the authoritative catalog doc atomically with the code; add a drift-stability regression test; validate through registered `make dev-test FILTER=` suites.

## Implementation steps

1. **Fixture.** Add `Tests/RepoPromptTests/AgentMode/Fixtures/OhMyPiACP/models-18.1.3.json` from a fresh live `omp acp` capture (exact IDs, order, and case; do not synthesize). Verify it contains the collapsed Grok 4.5/4.6 base/fast pairs and none of the old Grok effort variants, and that the mixed `gpt-5.2` family retains its bare member. Update the fixtures `README.md` with provenance (omp 18.1.3, PR #8988) and the observed `thinking` values (`off…xhigh` for `cursor/gpt-5.2` and the Grok base; `off, auto` for `composer-2.5`). Reuse the existing fixture loader (see `fixtureWireIDs()` in `OhMyPiModelCatalogTests`).
2. **Projector change (only production change).** In `OhMyPiModelMenuProjector.swift`, set `allowsThinkingAccessory: entry.effort == nil` in `familyLeaf`, ideally via a small named helper expressing "wire ID encodes an explicit effort". Extend the type-level doc comment: family grouping is presentational; accessory eligibility is per-leaf and effort-suffix-derived. Do not touch `qualifiesAsFamily`, `parseSuffix`, ordering, cache, or `standaloneLeaf`.
3. **Update pinned surface tests** in `OhMyPiThinkingCapabilityTests.swift` (suite `OhMyPiThinkingMenuBuilderTests`):
   - `testStableAgentSurfaceKeepsFamilyLeavesTerminalAndStandaloneGoogleThinkingCapable` (≈506-605): rename to reflect the per-leaf contract. Flip `familyDefault` (`cursor → cursor-grok-4.6 → Default`) and `sparseFastDefault` (`provider → sparse → Fast → Default`) to expect a thinking submenu whose first row is `Default`. Keep `familyHigh`, `fastXHigh`, `sparseFastLow` asserted terminal (`submenuItems == nil`). Add an action-order assertion through `… → Default → Default`: model commit precedes thinking write, and only that exact ID's stored entry changes.
   - `testStableSettingsSurfaceKeepsFamilyLeavesTerminalAndStandaloneGoogleThinkingCapable` (≈609-650): keep `familyHigh` terminal; add coverage that an effort-nil family leaf gains the submenu on the settings surface.
   - `testStableAgentSurfaceNestsThinkingUnderEachValidModelNotAsSibling` (203 numeric-suffix standalone models) is unaffected — leave it alone.
4. **New collapsed-pair test.** Inputs exactly `cursor/cursor-grok-4.6` + `cursor/cursor-grok-4.6-fast`: still one family under `cursor` (grouping unchanged); both leaves `effort == nil` and accessory-capable; thinking rows appear beneath both outer leaves on agent and settings surfaces.
5. **New drift-stability test (key regression guard).** Project the same wire IDs `cursor/gpt-5.2` and `cursor/gpt-5.2-fast` under (a) a pure-pair catalog and (b) the expanded catalog with `-high`/`-high-fast` siblings. Assert by exact `wireID`: both effort-nil IDs are accessory-capable in **both** shapes; `-high` variants terminal in (b). Cover `OhMyPiThinkingExecutionEligibility.allowsAssignment` under both shapes too. Add the complementary ambiguity pin: uncorroborated standalone `model-high` eligible; corroborated `model-high` family leaf terminal.
6. **Execution-path tests** in `OhMyPiThinkingSelectionsTests.swift` (extends `ACPAgentSessionControllerModeConfigTests`): stored values under `cursor/cursor-grok-4.6` and `-fast` flow as `.ohMyPiThinking(value)`; stored value under `cursor/cursor-grok-4.6-high` (effort-suffixed) remains suppressed; split the sparse-family expectation — `provider/sparse-fast` now flows, `provider/sparse-low-fast` stays suppressed. No production change in `OhMyPiThinkingSelections.swift`.
7. **Fixture-backed projection test** in `OhMyPiModelCatalogTests`: load `models-18.1.3.json`, assert the collapsed Grok leaves are accessory-capable and effort-suffixed groups present remain terminal; existing 17.3.4 grouping assertions (including `pair.isFamily`) remain untouched.
8. **Docs.** Update `docs/context/oracle-remote-models-cursor-catalog.md` atomically: replace "family leaves are terminal / family-leaf assignments are suppressed" with the per-leaf invariant (effort-encoded wire IDs terminal; effort-nil wire IDs accessory-capable; capability registry authoritative for values; execution follows the same per-leaf rule; no ID migration between old suffixed and new collapsed IDs). Bump its last-verified date.
9. **Validation** (registered suites; broaden only if boundaries move):
   ```
   make dev-test FILTER=OhMyPiThinkingMenuBuilderTests
   make dev-test FILTER=ACPAgentSessionControllerModeConfigTests
   make dev-test FILTER=OhMyPiModelCatalogTests
   make dev-lint
   make dev-format-check
   ```
   Optional live smoke: select `cursor/cursor-grok-4.6` in a debug app session, load thinking levels, pick `high`, verify the run carries `.ohMyPiThinking("high")`.

## Out-of-scope follow-ups (filed, not part of this fix)

- **Emission-time capability validation** in `assignments(for:)` (only emit stored values present in a loaded capability snapshot): defuses stale-value risk under any policy; changes behavior for not-yet-probed models, so it needs its own design.
- **`standaloneLeaf` orphan-effort audit**: a lone effort-suffixed ID with no siblings is accessory-capable today; unifying it on the named predicate is a deliberate widening, not a rider.
- **Labeling refinement** for `Default > Default` nesting (e.g. distinguishing "standard model" from "use model default") across all surfaces.

## Migration / rollback

No schema or persistence change; no migration between old suffixed IDs (`cursor/cursor-grok-4.6-high`) and collapsed IDs — selections stay keyed to exact upstream identity, and users re-select thinking on the collapsed IDs. Rollback is a one-line flag revert.
