# Technical Implementation Report - 2026-07-25 - MCP Instructions Rewrite & Provider-Aware Binary Guidance

## Session Overview

Implemented Steps 1 and 2 of the R1/R4 contract-validity investigation handoff via a
verifier-first workflow (contract → verifier matrix → implementation → verification → independent
review), with oracle consults before and after implementation plus a follow-up
prompt-effectiveness review. Three deliverables landed:

1. All three MCP initialization-instruction variants rewritten as positive, routing-first
   capability claims that fit Claude Code's observed 2,048-character client truncation, with new
   contract tests enforcing the budget, forbidden-comparison matcher, purpose boundaries, and
   ordering.
2. `binaryAssetReadingGuidance` converted from a `codexExec`-only ternary to an exhaustive
   `AgentProviderKind` switch, so no provider is told to use a tool its own integration config
   denies (OpenCode sets `"read": "deny"`).
3. A committed architecture decision document recording the durable decisions and the evidence
   behind two explicit deferrals (R4 native-Read accretion bridge; worktree prompt fragment).

## Implementation Details

### MCP instruction variants (Step 1)

**Problem Statement:**
`RepoPromptMCPInstructions.swift` shipped verbatim in the genesis commit and was never edited.
Its "RECOMMENDED over built-in equivalents" block referenced native tools (Grep/Glob/Edit)
that are removed from the model's tool schema in Claude agent-mode sessions — dead guidance
consuming ~23% of the delivered budget. Claude Code truncates MCP `instructions` at exactly
2,048 characters (observed in 106/106 deliveries in the session-transcript corpus);
`agentModeText` (~2,445 chars) and `externalMCPText` (~2,984 chars) both exceeded the cap, so
the tail — the oracle-export handoff and `bind_context` tab-routing guidance — was silently cut
in every delivery. Some clients also render the field differently (Codex: tool-namespace
description; Zed: ignored), making comparative/absence claims about native tools false for some
consumers.

**Solution Approach:**
Positive capability claims only; routing/boundary content first so truncation-robustness aligns
with importance ordering; provider-specific routing stays in the provider-aware system-prompt
layer. Shared fragments (`routingAndBoundaries`, `contextWorkflow`,
`additionalCapabilities(codeMapsDisabled:)`) were extracted so the two full variants cannot
silently desynchronize under a per-variant budget. Worst-case rendered sizes after the rewrite:
`agentModeText` 1,546 / `externalMCPText` 1,927 / `discoverText` 634 characters (bytes == chars;
ASCII-safe against a possibly byte-based client cap).

A follow-up prompt-effectiveness oracle review (old-as-delivered vs new-as-delivered) judged
agent-mode/discover strictly better and external mixed-net-positive, and produced four patches
that were applied and re-validated: an external adoption cue ("These tools are the primary
interface to this workspace…"), the "update it before Oracle calls" sequencing imperative, the
`agent_run` role-enum affordance (explore/engineer/pair/design), and the `apply_edits`
creates-new-files affordance.

### Provider-aware binary-asset guidance (Step 2)

**Problem Statement:**
`SystemPromptService.codingAgentPrompt` branched binary-asset guidance on
`agentKind == .codexExec` only; every other provider — including OpenCode, whose managed Agent
Mode permissions set `"read": "deny"`, and Cursor, whose ACP-native tool inventory is not
statically declared — was told to "Use the native Read tool". A one-day-old regression from
commit `d2f8f504`.

**Solution Approach:**
Exhaustive `switch` over `Optional<AgentProviderKind>` with no `default`, so adding a provider
kind forces an explicit compile-time decision instead of inheriting a fabricated capability:

```swift
let binaryAssetReadingGuidance = switch agentKind {
case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
    "Use the native Read tool for images, screenshots, PDFs, and other binary assets — …"
case .codexExec:
    "Use the provider's native image or document reading tools for binary assets — …"
case .openCode:
    "Binary and media files (images, screenshots, PDFs) cannot be read in this session; … tell the user that limitation and ask for the content in a text form."
case .cursor, nil:
    "If the provider exposes a native image or document reading capability, use it … if it does not, tell the user the file cannot be read and ask for the content in another form."
}
```

The Claude-family grouping was verified against `usesClaudeNativeRuntime`
(`AgentRuntimeProviderService.swift:108-115`). OpenCode/Cursor/nil sentences were rewritten to
agent-voice imperatives during the pre-implementation oracle consult.

**Files Modified:**

- `Sources/RepoPrompt/Infrastructure/MCP/RepoPromptMCPInstructions.swift` — full variant rewrite + shared-fragment extraction + 4 prompt-effectiveness patches
- `Sources/RepoPrompt/Infrastructure/AI/SystemPromptService.swift` — exhaustive binary-guidance switch
- `Tests/RepoPromptTests/MCP/RepoPromptMCPInstructionsTests.swift` — new; 3 contract tests (client budget, forbidden-comparison matcher with word-boundary rules, purpose/Code-Maps boundaries, routing-before-detail ordering)
- `Tests/RepoPromptTests/MCP/ToolCatalogSnapshotTests.swift` — provider table extended to all 7 kinds + `nil`, incl. exactly-one-of-four-sentences cross-contamination assertion
- `Scripts/Fixtures/test-suite-contract-ledger.tsv` — 4 surgical additions (3 new IDs + 1 backfill for the extended provider-prompt test)
- `docs/architecture/mcp-instructions-and-provider-guidance.md` — new ADR

### Technical Decisions

1. MCP `instructions` carry positive capability claims only; tool-routing/ownership rules live in
   the provider-aware prompt layer (client rendering diversity + per-provider tool exposure).
2. 2,048 characters is a tested design budget for every rendered variant — explicitly a Claude
   Code client observation, not an MCP protocol limit.
3. Provider-conditional prompt guidance must branch exhaustively on actual provider exposure,
   never on a single `== .codexExec` axis.
4. Deferred: R4 native-Read accretion bridge (entire leak dataset predates the 2026-07-24 prompt
   hardening; re-measure post-hardening before building) and the worktree path-translation
   fragment (1/969 real sessions; hazard real in code, undemonstrated in practice).
5. Pre-existing test-ledger drift (3 missing + 2 stale `WorkspaceProjectedPathSearchTests` IDs)
   deliberately left untouched as out of scope; `verify-ledger` keeps failing with exactly that
   residual until reconciled separately.

## Challenges Encountered

- **Ledger dead end avoided**: the pre-implementation oracle consult flagged the curated-ledger
  workflow as the likeliest mid-run failure; a clean-checkout `verify-ledger` run confirmed the
  baseline was already broken (missing=4/stale=2), so the verifier criterion was re-pinned to a
  delta-based check before the implementer launched.
- **Matcher self-contradiction**: the verifier's forbidden-tool-name rule originally keyed on
  words (`use`, `tool`, `available`) present on nearly every legitimate instruction line; the rule
  was narrowed pre-launch. Two latent test loopholes (backtick not in the punctuation trim set;
  `try?` swallowing regex errors) were found in independent review and fixed.

## Testing

- `RepoPromptMCPInstructionsTests` (3 tests) and the extended
  `ToolCatalogSnapshotTests/testCodingAgentPromptManifestMatchesRegisteredSchemas` pass via
  daemon-coordinated focused runs; authoritative `dev-test-list` confirms all 4 IDs;
  `make dev-swift-build PRODUCT=RepoPrompt` exit 0; `make dev-lint` (format-check + strict
  SwiftLint) exit 0. Final rerun after prompt patches: suite passed, 3 tests / 0 failures
  (conductor ticket `958e4db9`), lint exit 0 (ticket `88008111`).
- Shared-fragment extraction was proven behavior-preserving at the time via a six-render SHA-256
  byte-identity comparison (later intentionally superseded by the four content patches, which the
  contract tests govern).

## Next Steps

### Immediate TODOs
- Commit (run `.agents/skills/rpce-contribution-check/scripts/preflight.sh commit` first).
- Reconcile the pre-existing `WorkspaceProjectedPathSearchTests` ledger drift as its own change.
- After ~2–3 weeks of post-change Claude-session volume, rerun the transcript-mining scripts to
  measure post-hardening native-Read leak rate (decides the R4 bridge) and external tool-adoption
  effects of the rewritten instructions.

### Technical Debt Introduced
- None knowingly; the ADR records the two explicit deferrals.

## Session Metrics
- **Files Changed**: 6 (4 modified, 2 new) + run artifacts under `.agent-artifacts/` (git-excluded)
- **Lines Modified**: ~111 insertions / ~45 deletions in tracked sources at last measure, plus the new test file (~290 lines) and ADR (~40 lines)
- **Components Affected**: MCP instruction rendering, coding-agent system prompt, MCP contract tests, test-suite ledger, architecture docs
- **Verification**: 12/12 verifier rows PASS; two independent oracle reviews (code + prompt-effectiveness), all findings applied

## Lessons Learned
- "Battle-tested" prose can be an illusion: the old instructions were never edited post-genesis,
  referenced schema-absent tools, and were truncated in 100% of observed deliveries.
- Measure the delivery channel, not the source file — the binding constraint (2,048-char client
  cap) was invisible in the repository and only appeared in delivered-transcript mining.
- Verifier-first pays off when the verifier itself is reviewed: both oracle gates found defects
  in the *checks* (matcher over-breadth, ledger baseline) before they could burn implementation
  time.

> Generated from Claude Code session on 2026-07-25
