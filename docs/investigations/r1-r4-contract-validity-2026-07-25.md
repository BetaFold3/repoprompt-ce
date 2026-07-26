# Investigation: Do the R1 (routing-instruction rewrite) and R4 (native Read accretion) contracts address real source-code issues?

**Date:** 2026-07-25
**Branch:** `feat/personal-touch-system-prompt`
**Status:** Complete

## Summary

**Both contracts target real defects, but neither remedy is correct as written.**

R1's premises all hold — the agent-mode MCP instructions really do recommend `file_search`/
`apply_edits` over `Grep`/`Glob`/`Edit`, which are disallowed at Claude agent-mode launch — but
R1 under-scopes the fix: it misses the identical dead wording in `externalMCPText`, misses two
of the four prose surfaces that carry read-routing policy, and misses a worse adjacent bug that
tells OpenCode and Cursor to use a native `Read` tool their own config **denies**. R1's
"one ownership table in the instructions string" is also the wrong location: that string is
rendered by Codex as a *tool-namespace description* and discarded outright by Zed, so absence
claims written there are false for some consumers.

R4's leak is real (native `Read` successes never reach the selection accretion pipeline) but the
prescribed bridge is the wrong fix: every *text* read it would harvest is a read that violated
the read policy, its fixture target is a Python benchmark harness that never runs Swift selection
code, and it can only promise eventual — not parity — accretion. Narrowing native `Read`'s role
is cheaper, self-healing, and eliminates the leak instead of memorializing it.

Root cause of both: tool-surface truth is duplicated as free prose across five render sites,
keyed on provider-blind axes, with no machine-checkable link to the configs that enforce
exposure — imported wholesale at the CE genesis commit and never reconciled since.

- **R1** — rewrite MCP routing instructions (`RepoPromptMCPInstructions.swift`) so each
  purpose variant references only tools that exist in that session type, replace
  "RECOMMENDED over built-in equivalents" with one-owner-per-intent language, add a
  worktree rule, and amend the Agent Mode read-policy prompt block.
- **R4** — harvest native `Read` tool successes into the selection auto-accretion pipeline
  so they register the same way MCP `read_file` calls do.

## Symptoms (claimed by the contracts)

- R1a: The agent-mode MCP instruction variant recommends `file_search` over `Grep`/`Glob`
  and `apply_edits` over `Edit` — but those native tools are disallowed at CLI launch in
  agent-mode sessions, making the guidance dead text.
- R1b: "RECOMMENDED over built-in equivalents" is soft/ambiguous where an ownership
  statement is needed; no stated owner for git inspection, shell mutation avoidance, or
  binary vs text reads.
- R1c: Worktree-bound sessions have no stated rule preventing absolute workspace paths
  from being handed to native tools/shell, which do not get path translation.
- R1d: The Agent Mode read-policy prompt block may have no equivalent for non-Claude
  families (Codex).
- R4: Native `Read` successes bypass the selection auto-accretion pipeline that
  `get_code_structure(scope="selected")`, `manage_selection`, `prompt`,
  `workspace_context`, and `context_builder` drain — a tracking-fidelity leak.

## Initial verification (agent, Phase 1)

**CONFIRMED — R1a premise (Claude agent-mode).**
`Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/ClaudeCodeIntegrationConfiguration.swift:47-67`
defines `agentDisallowedTools` = `Write`, `Edit`, `Glob`, `Grep`, `Task`, `Monitor`,
`SlashCommand`, `NotebookEdit`, `TodoWrite`, … Native `Read`, `Bash`, and `Skill` are
deliberately kept (see the doc comment at lines 44-46).
Meanwhile `RepoPromptMCPInstructions.agentModeText` (lines 31-63) still emits
"file_search instead of Grep/Glob" and "apply_edits instead of Edit". Both named
built-ins are unavailable in that session type, so the comparison is dead guidance.

**Purpose → variant mapping** (`RepoPromptMCPInstructions.text(for:codeMapsDisabled:)`, lines 18-27):
`.agentModeRun` → `agentModeText`; `.discoverRun` → `discoverText`; `.unknown` → `externalMCPText`.

**Other disallow lists for comparison:**
- `discoverDisallowedTools` (lines 73-101) additionally blocks `Bash` and `Read`.
- `terminalDisallowedTools` (lines 106-116) blocks `Read`, `Write`, `Edit`, `Glob`, `Grep`.
- `CLIPathInstaller.claudeRPDisallowedTools` (`Sources/RepoPrompt/Infrastructure/Process/CLI/CLIPathInstaller.swift:52`)
  = `["Read", "Write", "Edit", "Glob", "Grep"]` — a *fourth* exposure profile.

**OPEN — the exposure matrix is provider-dependent, not purpose-dependent.**
`MCPRunPurpose.agentModeRun` is a per-connection purpose shared by every Agent Mode
provider (Claude, Codex, ACP/OpenCode, …), but `agentDisallowedTools` is Claude-specific.
`OpenCodeIntegrationConfiguration.swift:296-301` denies `read`/`glob`/`grep`/`edit`/`write`
for OpenCode. So a single `agentModeText` cannot truthfully enumerate "tools that exist in
this session type" unless the instruction text becomes provider-aware. This is a gap in
the R1 contract as written and is a primary question for the investigation.

**UNVERIFIED — the "~2KB truncation budget" in R1b.** A repo-wide search for
`2048` / truncation logic on MCP initialize instructions found no such limit in this
codebase (all `2048` hits are unrelated: tool-summary persistence, provider max-tokens,
manifest batch sizes). If the budget is real it is imposed by the *client* (Claude Code
CLI), not by RepoPrompt — so it cannot be enforced or tested here.

## Background / Prior Research

### B1. Git archaeology — the instruction/policy mismatch is original, not a regression

Explore agent ran `git log --follow`, `git blame`, pickaxe (`-S`) searches, root-ancestry,
replacement-ref and unreachable-object checks across both files.

- Both `agentDisallowedTools` and `RepoPromptMCPInstructions` (already `MCPRunPurpose`-split,
  already containing the "RECOMMENDED … instead of Grep/Glob … instead of Edit" block) first
  appear together in the **parentless root commit `351e9803` — 2026-05-31 — "Initial RepoPrompt
  CE snapshot"**.
- Pickaxe finds **zero** post-snapshot additions/removals of `Read`, `Bash`, `Edit`, `Glob`, or
  `Grep` in `ClaudeCodeIntegrationConfiguration.swift`. The `Grep/Glob/Edit` instruction wording
  has **never been revised**.
- **Conclusion:** there is no "drift commit". The contradiction was imported wholesale at CE
  genesis and has never been synchronized. Pre-snapshot history is unrecoverable (collapsed).
- `CLIPathInstaller.claudeRPDisallowedTools` also dates to `351e9803` and has never changed;
  later commits touching that file (`5dae4116`, `b8d1bd87`, `96e039a6`, `c255548d`) were
  unrelated (signing/packaging, CLI path diagnostics, translocation-symlink recovery).

*Implication for R1:* this is a genuine, long-standing correctness bug in the guidance, not a
recent regression — and nothing else in history depends on the current wording.

### B2. External research — the "~2KB truncation budget" is real, but it is a *Claude Code client* rule

- **MCP spec itself defines no size limit** on `InitializeResult.instructions`. The schema
  ([modelcontextprotocol.io/specification/2025-11-25/schema#initializeresult](https://modelcontextprotocol.io/specification/2025-11-25/schema#initializeresult))
  calls it a "hint" that a client **MAY** add to the system prompt — no `maxLength`, no
  requirement that clients preserve or inject it at all.
- **Claude Code documents the limit explicitly:**
  > "Claude Code truncates tool descriptions and server instructions at 2KB each. Keep them
  > concise to avoid truncation, and put critical details near the start."
  — [code.claude.com/docs/en/mcp#for-mcp-server-authors](https://code.claude.com/docs/en/mcp#for-mcp-server-authors)

  Also: "Only tool names and server instructions load at session start."
- Behavior is **truncation, not summarization**; community capture
  ([anthropics/claude-code#43474](https://github.com/anthropics/claude-code/issues/43474)) shows a
  `# MCP Server Instructions` system-reminder block cut off mid-sentence. "2KB" is **not defined**
  as bytes vs. characters vs. 2000 vs. 2048 — so treat it as an approximate engineering budget,
  not an exact assertable boundary.
- **The routing-boundary-first ordering advice is therefore justified** — but only because
  truncation keeps the head and discards the tail, not because of any attention heuristic.

**Cross-client consumption of the same string (matters a lot for R1's scope):**

| Client | Consumes `instructions`? | Where it lands | Size rule |
|---|---|---|---|
| Claude Code | Yes | System prompt / `# MCP Server Instructions` system-reminder | 2KB truncation, documented |
| Codex CLI | Yes | MCP **tool-namespace description**, not a system-prompt block ([rmcp_client.rs](https://github.com/openai/codex/blob/main/codex-rs/codex-mcp/src/rmcp_client.rs#L819-L908)) | none found |
| OpenCode | Yes | System prompt, inside `<mcp_instructions><server …>` ([system.ts](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/session/system.ts#L118-L136)) | none found |
| Zed native agent | **No** — `InitializeResponse` doesn't even deserialize the field ([types.rs](https://github.com/zed-industries/zed/blob/main/crates/context_server/src/types.rs#L1158-L1169)) | discarded | n/a |
| ACP (protocol) | Unspecified — ACP only forwards MCP *connection details*; the agent owns the MCP client | agent-dependent | n/a |

*Implications for R1:*
1. The 2KB budget is a **Claude Code compatibility constraint**, and should be documented as
   such in a code comment — not asserted as a protocol contract or snapshot-tested as an exact
   byte boundary.
2. Because Codex surfaces the string as a **tool-namespace description** and Zed discards it
   entirely, `RepoPromptMCPInstructions` **cannot be the only place** the ownership/worktree
   rules live. Any rule that must hold for non-Claude providers has to also exist in the
   prompt surface (`AgentModePrompts`), which is exactly the R1d gap.

## Investigator Findings: R1 — instruction/prompt surfaces, provider exposure, worktree

### Verdicts

#### 1. Codex native tool exposure — **PARTIAL**

The narrow configuration fact is real, but the conclusion "Codex Agent Mode has no native
file access" conflates two different Codex runtimes.

- The headless helper does set `shellToolEnabled: false`, `webSearchRequestEnabled: false`,
  `viewImageToolEnabled: false`, and `includeApplyPatchTool: false` for `.agentRun`,
  `.discoverRun`, and `.promptOnly`
  (`Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/CodexIntegrationConfiguration.swift:66-89`).
  `CodexOverrides.cliConfigArgs` maps those to `features.shell_tool=false`, additionally
  `features.unified_exec=false`, `web_search=disabled`,
  `features.web_search_request=false`, and `features.apply_patch_freeform=false`
  (`Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppOnly/CodexOverrides.swift:77-101`).
  The actual headless `CodexExecAgentProvider` independently builds the same MCP-centric
  surface with shell/image/apply-patch disabled
  (`Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/CodexExecAgentProvider.swift:43-83`).
- That is **not** the interactive App Server Agent Mode path. The ViewModel passes
  `permissionProfile.codexBashToolEnabled()` into `Options.agentModeDefault`
  (`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:1429-1451`).
  Safe Managed explicitly returns `true`; user-configured and provider-override profiles use
  the user's Bash preference
  (`Sources/RepoPrompt/Features/AgentMode/Runtime/ProviderBindings/AgentProviderPermissionProfile.swift:57-66`).
  The App Server policy then enables/disables shell from that value, takes web-search from the
  user preference, always sets `viewImageToolEnabled: true`, and only *best-effort* disables
  apply-patch (`CodexNativeSessionController.swift:7965-8004`). The source explicitly warns
  that model metadata may still expose built-in patching and shell/unified-exec may route patch
  activity (`CodexOverrides.swift:52-62`); native `FileChange` remains authoritative even when
  the apply-patch flag is false (`CodexNativeSessionController.swift:7971-7979`).
- CE's Codex `ToolPolicy` has no discrete `Read`, `Write`, `Edit`, `Grep`, or `Glob` switches;
  its native concepts are shell/unified-exec, web search, image viewing, apply-patch, etc.
  (`CodexOverrides.swift:52-62`). That does **not** imply no native file channel: enabled shell
  subsumes `cat`, `sed`, `grep`, redirection, and other reads/mutations.

**Result:** headless Codex runs are intended to depend on RepoPrompt MCP for text files, but
interactive Codex Agent Mode can have native shell access (including under Safe Managed),
search, and image access. R1 must not state a provider-wide "no native file access" premise.

#### 2. OpenCode exposure — **CONFIRMED**

- Interactive managed OpenCode explicitly allows `bash` while denying `read`, `list`, `glob`,
  `grep`, `edit`, `write`, and `patch`
  (`Sources/RepoPrompt/Infrastructure/AI/Providers/OpenCode/OpenCodeIntegrationConfiguration.swift:293-312`).
  Its own mode description says it leaves shell available while denying overlapping built-ins
  (`OpenCodeIntegrationConfiguration.swift:55-63`).
- A user-selectable `fullAccess` level exists
  (`Sources/RepoPrompt/Infrastructure/AI/Providers/OpenCode/OpenCodeAgentToolPreferences.swift:4-49`),
  but it means "available tools without approval prompts," not restoration of the denied file
  tools (`OpenCodeAgentToolPreferences.swift:15-23`). The full-access permissions retain every
  explicit deny from the managed profile and add wildcard allow
  (`OpenCodeIntegrationConfiguration.swift:315-319`). Thus it still leaves the overlapping
  read/edit tools denied while Bash is allowed/auto-accepted.
- Headless discovery is different: it maps every managed permission, including Bash, to deny
  (`OpenCodeIntegrationConfiguration.swift:321-328`). RepoPrompt interactive ACP construction
  uses the managed overlay by default (`OpenCodeAgentConfig.swift:4-22,53-71`).

There is no CE-side command/path filter in the OpenCode provider after permissioning Bash; the
provider only normalizes shell events as `bash`
(`OpenCodeACPEventNormalizer.swift:84-90`). Therefore `bash` is an unpoliced native read *and*
mutation channel (`cat`, `sed -i`, shell redirection, etc.) despite the nominal read/edit denies.
One-owner wording must explicitly tell OpenCode not to use Bash for workspace text reads or
mutations; the permission table alone does not enforce that ownership.

#### 3. Claude runtime toggles — **PARTIAL**

The setting varies at runtime, but the **Agent Mode exposure matrix does not**.

- Exhaustive Swift search finds one implementation, one forwarding wrapper, and one application
  call: `ClaudeCodeIntegrationConfiguration.disallowedTools`
  (`ClaudeCodeIntegrationConfiguration.swift:118-136`),
  `MCPIntegrationHelper.claudeDisallowedTools`
  (`Sources/RepoPrompt/Infrastructure/MCP/MCPIntegrationHelper.swift:83-92`), and
  `ClaudeCodeAgentConfig` construction
  (`Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCodeAgentConfig.swift:163-177`).
- Agent Mode resolves the explicit Boolean or the user preference
  (`ClaudeCodeAgentConfig.swift:45-88`). Safe Managed forces false; user/provider profiles read
  the preference (`ClaudeControllerLaunchPolicy.swift:8-33`); discovery always passes false
  (`ClaudeCodeAgentConfig.swift:110-130`). The preference is persisted and user-settable
  (`ClaudeAgentToolPreferences.swift:185-219`).
- However, `.agentRun`'s base disallow list already omits `Bash`, `BashOutput`, and `KillShell`,
  as well as `Read`, while always containing `Write`, `Edit`, `Glob`, and `Grep`
  (`ClaudeCodeIntegrationConfiguration.swift:44-68`). `allowNativeBashTool: true` merely removes
  Bash-family names from a base list (`:118-136`), so both true and false yield the same Agent
  Mode surface: native `Read` and `Bash` exposed; `Write`/`Edit`/`Glob`/`Grep` disallowed.
- Full access / `bypassPermissions` cannot restore those disallowed tools. The native runtime
  appends `--allow-dangerously-skip-permissions` and then independently appends
  `--disallowedTools` (`ClaudeNativeProcessSessionController.swift:1996-2007`). The compatible
  runtime likewise appends `--dangerously-skip-permissions` and then `--disallowedTools`
  (`Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/ClaudeCompatibleRuntimeSupport.swift:749-759`).

So the toggle plumbing is misleading/no-op for Agent Mode, but R1's dead `Grep`/`Glob`/`Edit`
comparison is stable for every Claude Agent Mode permission profile.

#### 4. Worktree "silent wrong tree" — **CONFIRMED** (with display-form qualification)

**Cwd is the physical worktree.** A binding stores separate `logicalRootPath` and
`worktreeRootPath` values (`AgentSessionWorktreeBinding.swift:3-14`). The runtime resolver
matches the visible logical root, validates the physical worktree directory, and returns
`worktreeRootPath` as the effective workspace (`AgentWorktreeRuntimeWorkspaceResolver.swift:4-39`).
That resolved path reaches all provider families:

- Claude spawns with it as `workingDirectory`
  (`ClaudeNativeProcessSessionController.swift:598-604,2154-2160`).
- Codex uses it for the App Server process and `thread/start` / `thread/resume` cwd
  (`CodexNativeSessionController.swift:1057-1086,1111-1117`).
- OpenCode uses it for both process launch and ACP session cwd
  (`OpenCodeACPAgentProvider.swift:36-64,70-85,137-142`), and ACP passes it to the spawned
  process (`ACPAgentSessionController.swift:372-412`).
- `ProcessLauncher` establishes that cwd with `posix_spawn_file_actions_addchdir_np`
  (`Sources/RepoPrompt/Infrastructure/Process/ProcessLauncher.swift:185-202`).

Therefore relative native paths resolve in the bound physical worktree (safe for the primary
bound root). Caveats: `..` can escape, and a multi-root session has only one process cwd, so
secondary roots cannot rely on this rule.

**MCP intentionally translates input physical/logical paths but projects replies back to the
logical identity.** `WorkspaceRootBindingProjection.translateInputPath` maps absolute logical
paths and single-root relative paths to the physical root
(`WorkspaceRootBindingProjection.swift:111-150`); `projectedLogicalDisplayPath` performs the
reverse replacement for replies (`:190-210`). Concrete surfaces:

- `read_file` translates before reading, then projects its physical reply path back to a logical
  display path (`MCPFileToolProvider.swift:511-549`;
  `MCPReadFileToolProjection.swift:38-61`). Its default projected display is usually a logical
  **relative** path, not an absolute one.
- `file_search` uses the same projected logical display resolver
  (`MCPFileToolProvider.swift:821-829`).
- `get_file_tree(type:"roots")` explicitly emits each projected logical root with
  `display: .full`, i.e. the absolute canonical checkout path
  (`MCPFileToolProvider.swift:397-407`). `file_actions` echoes the caller's input path in its
  acknowledgement while internally translating it for I/O (`MCPFileToolProvider.swift:83-123`;
  `MCPServerViewModel.swift:5890-5892`).
- `worktree_scope` labels this split as `display_identity: logical_canonical_root` versus
  `effective_identity: bound_worktree_root`, while deliberately not exposing the physical path
  (`ToolResultDTOs.swift:37-73`).

The logical root is the original/main checkout, while a default created worktree is a separate
sibling under `.repoprompt-worktrees/<repo>/...`
(`GitWorktreeDefaultPathPlanner.swift:50-106,137-162`). The original checkout therefore still
exists. An absolute logical path ignores cwd and receives no MCP translation when handed to
native `Read`/Bash, so—subject only to ordinary OS/provider permissions—it resolves successfully
against the canonical checkout and silently reads the wrong tree. Provider code has no binding
projection/translation layer: an exhaustive search of the Claude, Codex, OpenCode, and ACP
provider directories finds no `bindingProjection`, `translateInputPath`, `logicalRootPath`, or
`worktreeRootPath` usage (apart from unrelated Claude `EnterWorktree` tool names).

There is a weak warning in MCP file-tool descriptions that displayed paths may remain
logical/canonical while MCP reads use the worktree (`MCPFileToolProvider.swift:360-363,483-486`),
but neither `RepoPromptMCPInstructions` nor any provider prompt states that native tools do not
translate those paths, and nothing blocks the handoff. Thus R1's worktree rule addresses a real
silent-wrong-checkout defect; it should say to use native tools only with cwd-relative paths for
the primary root and never reuse MCP-displayed absolute workspace paths.

#### 5. Test coverage — **CONFIRMED**, with a nearby-but-distinct prompt test

An exhaustive content search across all 391 files under `Tests/` and
`Packages/RepoPromptAgentProviders/Tests` found **zero** references to
`RepoPromptMCPInstructions`, `agentModeText`, `externalMCPText`, `providerReadPolicy`, or the
exact `RECOMMENDED over built-in equivalents` text.

The closest coverage is `ToolCatalogSnapshotTests.testCodingAgentPromptManifestMatchesRegisteredSchemas`:
it directly asserts separate `SystemPromptService.agentModePrompt` text and Codex qualification
(`Tests/RepoPromptTests/MCP/ToolCatalogSnapshotTests.swift:45-93`) and checks a manually curated
coding-prompt tool inventory against registered tools (`:97-123`). It does not extract tool names
from prompt text, does not cover MCP initialize-purpose variants, omits `oracle_send`,
`bind_context`, and `agent_explore` from that inventory, and never compares prompt references to
provider disallow/permission lists. No such provider-cross-check test exists. Provider tests that
assert `--disallowedTools` construction are independent of prompt wording (for example,
`ClaudeCompatibleRuntimeSupportTests.swift:104-147`).

#### 6. Third affected site (`externalMCPText`) — **CONFIRMED**

`.unknown` maps to `externalMCPText` (`RepoPromptMCPInstructions.swift:14-27`), and that variant
repeats the same `file_search instead of Grep/Glob` and `apply_edits instead of Edit` wording
(`RepoPromptMCPInstructions.swift:56-72`). R1 is incomplete if it edits only `agentModeText` and
the prompt read policy.

`.unknown` is not a client-name enum. Bootstrap uses an existing token's non-unknown purpose,
then the oldest matching pending run policy, then live run affinity; otherwise it returns
`.unknown` (`MCPConnectionManager.swift:4874-4913`). The chosen purpose is passed directly into
the MCP server's initialize instructions (`BootstrapSocketConnectionManager.swift:105-113`).
Consequences:

- Plain external clients with no RepoPrompt-installed run policy receive `.unknown`, whether
  their client name is recognized or unrecognized.
- The RepoPrompt CLI's exec and interactive modes identify themselves as
  `RepoPrompt CLI (Exec)` / `RepoPrompt CLI (Interactive)`
  (`Sources/RepoPromptMCP/Exec/ExecMCPService.swift:23-43`;
  `Interactive/InteractiveMCPService.swift:23-40`); absent another policy/affinity, they receive
  `.unknown` too.
- Cursor/OpenCode/Claude/Codex launched for Agent Mode receive `.agentModeRun` from the pending
  policy keyed by their provider client-name hint, not merely because their name is known
  (`AgentRuntimeProviderService.swift:84-95`;
  `AgentModeMCPPolicyInstaller.swift:21-36`). A normal Cursor/external connection without that
  policy remains `.unknown`. An unrecognized name cannot match a provider-installed policy or
  persisted Agent Mode restore and therefore falls through to `.unknown`.

For unknown/external clients the named built-ins are not universally dead—some hosts may expose
them—but the duplicate soft ownership wording and missing worktree rule still affect this
surface.

#### 7. `providerReadPolicy` use and non-Claude guidance — **PARTIAL**

The claimed Codex gap is real in some role prompts, but not in the top-level coding prompt.

- `providerReadPolicy(agentKind:)` has only two call sites: `explorePrompt` and
  `engineerPrompt` (`AgentModePrompts.swift:58-66,114-120`). It returns guidance only for the
  Claude-compatible cases and empty text for Codex, OpenCode, Cursor, and nil (`:336-353`).
- `codexQualifiedToolReferences` is only a name-rewrite boundary from canonical RepoPrompt names
  to `mcp__RepoPrompt__<tool>`; it adds no routing/read policy (`AgentModePrompts.swift:355-373`).
- For top-level `taskLabelKind == nil`, `SystemPromptService.agentModePrompt` routes to
  `codingAgentPrompt` (`SystemPromptService.swift:782-803`). That prompt already gives Codex an
  equivalent binary/text split: provider-native image/document tools for binary assets and MCP
  `read_file` for text (`SystemPromptService.swift:681-684,739-741`). It is directly tested
  (`ToolCatalogSnapshotTests.swift:61-86`). Therefore "Codex receives no equivalent anywhere"
  is refuted for the main coding-agent prompt.
- Explore/engineer Codex prompts get MCP text-read workflow statements but no binary-asset rule,
  because `providerReadPolicy` returns empty (`AgentModePrompts.swift:65-68,118-133`). Pair/design
  prompts carry a second inline Claude-only read-policy copy
  (`SystemPromptService.swift:854-867`); their Codex-only Tool Priorities prefer MCP tools and
  allow native tools as fallback but do not state the binary/text split (`:879-891`). OpenCode
  and Cursor likewise get no provider-specific policy in explore/engineer or pair/design. At the
  top level they instead fall into the generic non-Codex branch, which tells them to use "the
  native Read tool" for binary assets (`SystemPromptService.swift:681-684`)—a Claude-shaped
  concept that is false for managed OpenCode, whose `read` tool is explicitly denied.
- All provider families do receive the generated system prompt: Claude injects
  `SystemPromptService.agentModePrompt` (`ClaudeAgentModeCoordinator.swift:1355-1366`), Codex
  builds its base prompt from it (`CodexAgentModeCoordinator.swift:3928-3934`), and the shared
  headless/ACP message path does the same for `session.selectedAgent`
  (`AgentModeViewModel.swift:13486-13531`).

So R1 should centralize the rule rather than only amending `providerReadPolicy`: cover
explore/engineer plus the separate top-level and pair/design assemblies, preserve the already
correct top-level Codex binary guidance, and add an OpenCode/Cursor-safe formulation that does
not invent a native `Read` tool those providers may not have.

### What R1 gets right

- The current Claude/OpenCode/headless-Codex `Grep`/`Glob`/`Edit` comparisons are genuinely dead
  or misleading, and one-owner-per-intent language is more accurate.
- A worktree rule is necessary: MCP path translation and native cwd behavior form two different
  path domains, and absolute logical paths can silently hit the canonical checkout.
- Text versus binary ownership must live in provider prompts, not only MCP initialize
  instructions, and the non-Claude role variants have real gaps.
- Shell mutation/read ownership must be explicit because OpenCode Bash and interactive Codex
  shell can bypass the nominal MCP file-tool surface.

### What R1 gets wrong or misses

- It must distinguish **headless Codex** (MCP-centric) from **interactive App Server Codex**
  (runtime-configurable native shell/search/image channels); a universal "Codex has no native
  file access" statement is false.
- Claude's Bash setting is runtime-variable but currently a no-op for `.agentRun`; the actual
  Agent Mode exposure is static. Full-access permission modes do not restore disallowed file
  tools.
- The same instruction rewrite must include `externalMCPText`; `.unknown` reaches CLI and plain
  external clients, not a harmless unreachable fallback.
- The worktree rule should prefer cwd-relative native paths only for the primary bound root,
  forbid reusing MCP-displayed absolute logical paths, and acknowledge multi-root/`..` caveats.
  Merely saying "use the worktree" is not precise enough.
- Updating only `providerReadPolicy` is incomplete: top-level coding and pair/design prompt
  assemblies have separate policy text. Codex top-level already contains correct equivalent
  guidance and should not be regressed, while top-level OpenCode/Cursor currently inherit an
  invalid Claude-shaped "native Read" instruction that must also be made provider-safe.
- There is no regression test for initialize-instruction variants or a prompt-vs-provider
  exposure consistency check; R1 needs both if this mismatch is to stay fixed.

## Investigator Findings: R4 — native Read accretion feasibility

### Overall verdict

**R4 addresses a real selection-fidelity defect, but the remedy is not implementable safely as
currently worded.** Native Claude `Read` successes are retained in the transcript but never enter
the canonical selection/accretion lane, so later selection-based tools can omit a file the agent
actually inspected. The useful scope is **native text reads in a live, run-bound workspace**. R4
should proceed only after it specifies authoritative line-count recovery, real-result-only pairing,
fail-closed worktree resolution, eventual (not immediate) ordering, non-media scope, and what
"source" tagging means.

#### 1. The leak is real and consequential — **CONFIRMED (bounded)**

The production drains are:

- `get_code_structure(scope:"selected")`: canonical drain before resolving selected seed files
  (`Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift:267-298`).
- `manage_selection`: canonical for `get`, mirrored selection/metrics for every other operation
  (`Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPSelectionToolProvider.swift:159-190`).
- `workspace_context(op:"snapshot")`: mirrored drain before building the tab DTO
  (`Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPPromptContextToolProvider.swift:86-111`).
- `prompt`: **only `op:"export"` drains**; `get`, mutation, and preset operations do not
  (`MCPPromptContextToolProvider.swift:162-174`). Thus the contract's unqualified statement that
  "prompt drains" is too broad.
- `context_builder`: resolves/binds the target tab, constructs target metadata, then drains the
  mirrored lane before run authority/context capture
  (`Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPContextBuilderToolProvider.swift:330-413`).

For completeness, `get_file_tree(mode:"selected")` also drains canonical selection
(`MCPFileToolProvider.swift:417-426`), and `ask_oracle`/`oracle_send` drain mirrored state
(`Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift:1052-1068`).

Given the already-established single enqueue call in `MCPFileToolProvider`, a native `Read` leaves
**no canonical-selection or accretion-lane trace**. The Claude handler returns native events to the
generic transcript path (`ClaudeAgentToolTrackingHandler.swift:150-199,230-274`), where a real
result only terminalizes/appends an `AgentChatItem` (`AgentModeViewModel.swift:13861-13915`). It
therefore does leave a transcript and token-accounting trace; "no trace anywhere" would be false.

The lost fidelity is durable/downstream rather than the current Claude turn: selected seed files and
code-map expansion, selection export, workspace file blocks/tree, selection token/metric mirrors,
context-builder frozen context, and Oracle context can all omit the file. The model did receive the
native result during that turn, so R4 is not a claim that the immediate `Read` failed.

#### 2. `totalLines` problem — **CONFIRMED**

`AutoSliceSelection.readFileSelection` rejects missing/invalid `totalLines`, `firstLine`, or
`lastLine`, and declares a full file only for `firstLine == 1 && lastLine == totalLines`
(`Sources/RepoPrompt/Infrastructure/MCP/AutoSliceSelection.swift:18-45`). MCP can do this because
its store-backed slice projection constructs all three fields
(`Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPReadFileToolProjection.swift:11-38`).

The native event contract has call `argsJSON` and result `resultJSON`/optional `isError`, but no line
count (`AgentToolTrackingContracts.swift:8-54`). The translator serializes `tool_use.input` into the
call, then serializes result content without copying call args or adding file metadata
(`Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/ClaudeSDKNDJSONTranslator.swift:238-320,818-858`).

A sanitized audit of the local DEBUG raw-event captures (the app records inbound protocol lines at
`ClaudeNativeProcessSessionController.swift:946-949`; log placement is defined at `:2298-2324`)
found **24 native `Read` request/result pairs across three captures**:

- request keys were `file_path` plus optional `offset`/`limit` (18/24 had an offset or limit);
- all 24 had a `tool_use_id`; all 24 paired; none carried a total-line field;
- 23 text results used `N<TAB>content` numbered lines (not padded `cat -n` output); the one
  remaining result was a system-reminder-only payload with no file lines;
- native success results omitted `is_error` rather than reporting `false`.

The options are therefore:

- **(a) Always full — REFUTED.** It would promote explicit offset/limit reads, and an apparently
  default read starting at line 1 still does not prove EOF.
- **(b) Authoritative workspace re-read — RECOMMENDED.** The existing store-backed read path
  resolves a readable workspace file, rejects unavailable content, and produces an authoritative
  total/first/last range (`MCPServerViewModel.swift:5728-5854`). Re-run that slice using the native
  offset/limit, and take **all three enqueued range fields from the clipped store result**; do not mix
  stale native first/last lines with a fresh total (the file may shrink or grow between reads, and
  `readFileSelection` does not independently guard `lastLine <= totalLines`). Native numbers are only
  a success/consistency gate. This extra async read preserves current MCP semantics, with the explicit
  TOCTOU consequence that accretion describes current workspace state and may differ from what the
  model saw.
- **(c) Parse emitted line numbers — PARTIAL only.** Number prefixes can corroborate first/last and
  the requested offset, but cannot distinguish EOF from a hit limit and fail for reminder-only or
  format-drift payloads. They are suitable as a positive-success sanity check, not as `totalLines`.

#### 3. Synthetic completion interference — **CONFIRMED hazard**

For Claude-native `Read` with a nil invocation ID,
`shouldAutoCompleteProviderToolCall` returns true and the generic path immediately appends a
synthetic `.toolResult` containing `{"status":"completed",...}` and the call args
(`AgentToolTrackingContracts.swift:149-171`; `AgentModeViewModel.swift:13840-13859`). It does not
wait to establish that a real result is absent.

If a real nil-ID result later arrives, the fallback searches for a `.toolCall`, not the synthetic
`.toolResult`, so it appends another result (`AgentModeViewModel.swift:13888-13915`). An accretion
hook on transcript terminalization, or on both call and result, could therefore fire twice or fire
from a payload with args but no actual file content. The audited normal `Read` events all had IDs, so
this is a compatibility-path hazard rather than evidence of routine duplication. R4 must hook **only
the real provider `tool_result` path** and explicitly exclude synthetic completions.

#### 4. Request-to-success pairing — **PARTIAL**

Normal correlation is strong: a nonempty Claude `tool_use_id` is mapped to one generated UUID and
reused for the result (`ClaudeSDKNDJSONTranslator.swift:650-659,818-826`); the checked-in translator
test proves stable call/result identity (`ClaudeSDKNDJSONTranslatorTests.swift:6-58`), and the local
24-pair audit agreed. However, result events do not carry the original args, so a new native-Read
pending map must retain `argsJSON` by invocation ID. The current `ClaudeAgentToolTrackingHandler`
correlation machinery is MCP-only (`ClaudeAgentToolTrackingHandler.swift:528-594`); native events
fall through. The generic transcript fallback matches nil-ID results by latest tool name
(`AgentModeViewModel.swift:13888-13912`), which is not reliable for overlapping/repeated Reads.

Failure classification is also incomplete. `isError` is optional. The translator recognizes
explicit `is_error`, structured failure/denied statuses, exit codes, and structured error fields,
but returns nil for ordinary non-JSON text (`ClaudeSDKNDJSONTranslator.swift:664-751`). No captured
native Read failure or permission denial was available, so the contract's claim that denials are
reliably identifiable is unproved.

The safe acceptance rule is stricter than `isError != true`: require a real provider result, a stable
paired call, a valid `file_path`, no positive error signal, numbered file-line evidence consistent
with offset, successful fail-closed workspace resolution, and successful authoritative text re-read.
Skip nil-ID, non-numbered, empty/unprovable, failed, denied, and stale/unbound cases. Add fixtures for
structured denial, plain-text failure, nil-ID result, missing result, reminder-only result, and
success with `is_error == nil` before relying on this path.

#### 5. Context and identity plumbing — **CONFIRMED implementable, with a specific seam**

The handler is `MainActor`-isolated and receives `TabSession`. A session has `runID` and tab identity
(`AgentModeViewModel+TabSession.swift:137-159,386-391`); the ViewModel holds a weak MCP server
(`AgentModeViewModel.swift:549-552`) and already constructs provider tracking hooks at `:2198-2235`.
The MCP server can recover the **live agent MCP connection** from `runID` using a bidirectionally
validated mapping (`MCPServerViewModel+TabContext.swift:3572-3598`). Do not use
`AgentMCPControlContext.originatingConnectionID` (`AgentModeViewModel+Types.swift:233-259`): that is
the parent/control caller, not necessarily the runtime's child MCP connection.

The clean seam is a new `AgentToolTrackingHooks` native-read observation carrying run/tab identity
plus paired call/result data into `MCPServerViewModel.enqueueNativeReadAccretion`. The server—not the
handler—should:

1. resolve `runID -> connectionID`, construct `RequestMetadata` with `.agentModeRun` and this window,
   resolve the current run-bound `TabContextSnapshot`, and verify tab/run identity;
2. resolve the actual physical read path and authoritative readable file in that context;
3. re-read/project an MCP-equivalent `ReadFileReply`, pass it through the existing
   `AutoSliceSelection.readFileSelection`, and call the **existing**
   `MCPReadFileAutoSelectionCoordinator` lane. This inherits the MCP exclusion for `AGENTS.md`
   (`AutoSliceSelection.swift:18-35`); the coordinator's authoritative candidate path retains an
   already-full selection instead of adding a partial slice (`MCPServerViewModel.swift:4469-4505`).

This makes `hasVirtualContext` and route/binding generation authoritative at observation time. If the
connection/context has already closed or changed, skip rather than fall back to the active tab.

A nil `CoverageIdentity` does not break correctness: a mixed batch loses the certificate fast path
(`MCPReadFileAutoSelectionCoordinator.swift:207-252`), is classified `.uncertifiableBatch`
(`MCPServerViewModel.swift:4245-4255`), then takes the authoritative mutation path
(`MCPServerViewModel.swift:4509-4653`). It is slower and can poison that optimization for the whole
coalesced batch, so the native seam should supply the resolved physical identity exactly as MCP does
(`MCPServerViewModel.swift:3904-3927`).

"Tag accretion entries with source" is currently underspecified. `StoredSelection` has only paths,
slices, and codemap state (`Features/Workspaces/WorkspaceModel.swift:148-164`); it has no per-entry
provenance. `WorkspaceSelectionCoordinator.Change.source` tags an entire transaction, not each path
(`WorkspaceSelectionCoordinator.swift:125-148`), and current accretion persists as
`.mcpTabContext` (`MCPServerViewModel+TabContext.swift:1801-1807`). Add an accretion provenance enum
(e.g. MCP/native) to coordinator intents/batches and diagnostics, retaining a set when mixed intents
coalesce. If durable per-path provenance is intended, R4 needs a separate persistence/schema design;
it is not a small tag addition.

#### 6. Ordering guarantee — **CONFIRMED: only eventual parity is possible**

MCP `read_file` projects its reply, awaits enqueue, and only then encodes/returns the result
(`MCPFileToolProvider.swift:525-571`). Although selection mutation remains asynchronous, a later
drain captures at least that accepted intent.

A native result is read from the Claude process, translated, and emitted through the provider stream
(`ClaudeNativeProcessSessionController.swift:946-949,1294-1345`). There is no barrier between this
UI/provider-stream processing path and the child's next MCP request. The model/CLI can issue that
request before MainActor observation/enqueue has completed.

The coordinator drain deliberately captures one finite `acceptedSequence` and waits only through
that target (`MCPReadFileAutoSelectionCoordinator.swift:546-608`), behavior covered by
`MCPReadFileAutoSelectionCoordinatorTests.swift:337-371`. A native intent accepted after capture is
not ordinarily dropped; it continues asynchronously and a future drain can see it. But the current
consumer snapshot can miss it. `finish` marks the context closing before its final drain, so enqueue
rejects observations arriving during teardown; invalidation also prevents stale work from applying
(`MCPReadFileAutoSelectionCoordinator.swift:486-490,610-622,706-803`). The seam must not reroute such
an observation to an active-tab context. Amend "registers the same
identity/behavior" to **same merge/dedupe semantics with eventual accretion; no guarantee for the
immediately following MCP consumer**. Exact parity would require a cross-channel result barrier not
present today.

#### 7. Worktree canonicalization — **PARTIAL: APIs exist; the stated rule is insufficient**

The projection supports tilde expansion, relative/single-bound-root translation, absolute logical to
physical translation, physical-root membership, and physical-to-logical display projection
(`WorkspaceRootBindingProjection.swift:123-210,315-333`). Claude's process cwd is the supplied
workspace path (`ClaudeNativeProcessSessionController.swift:2154-2161`), and Agent Mode supplies the
primary worktree physical root when bound (`AgentWorktreeRuntimeWorkspaceResolver.swift:16-40`).

Resolution must treat the native argument as **evidence of what the CLI actually opened**, not as a
new MCP input to translate:

- resolve relative paths against the actual Claude cwd;
- expand tilde and standardize using the workspace store's existing path-canonicalization and
  symlink-escape discipline; do not invent a second `realpath` convention. Require the resolved
  physical file to be inside an allowed root and present in the authoritative store
  (`FileSystemService+ContentLoading.swift:1722-1730`);
- for a bound root, accept only the bound physical worktree path, then call
  `projectedLogicalDisplayPath(forPhysicalPath:)`; reject `..` escapes, ambiguous multi-root
  relatives, and all paths outside visible/bound roots.

An absolute **logical/base-checkout** path is the critical case: native `Read` really opened that
base file. Calling `translateInputPath` would silently map it to the worktree counterpart
(`WorkspaceRootBindingProjection.swift:123-143`) and accrete a different file. Correct
physical-to-logical projection returns nil for that non-worktree physical path, so the seam must skip
it. R4 should explicitly forbid feeding observed native paths through logical-to-physical input
translation.

#### 8. Proposed fixtures — **CONFIRMED wrong harness**

`Scripts/Fixtures/agent-mode-file-tools/v1/` is consumed only by the pure Python benchmark replay
tests (`Scripts/test_agent_mode_file_tools_benchmark.py:14-16,412-487`). The replay groups lifecycle
events into request/MainActor timing envelopes (`Scripts/benchmark_agent_mode_file_tools.py:153-252`)
and validates sample counts, completion events, worktree projection, transcript arguments, and
latency (`:498-538`). It does not execute Swift selection code or inspect canonical `StoredSelection`.
Adding native-read accretion semantics there would test the wrong thing.

Use these seams instead:

- `ClaudeSDKNDJSONTranslatorTests.swift` for native `Read` args/result/ID/error fixtures;
- new handler/hook tests for real-vs-synthetic completion and pending-call pairing;
- `MCPReadFileAutoSelectionCoordinatorTests.swift` for source-aware mixed batching, dedupe,
  slice union, full-wins, and finite drains (existing coverage at `:225-371`);
- a bound-context MCP integration test, adjacent to
  `PersistentAgentModeMCPReadFileConnectionTests.swift:1449-1507`, that injects the new native
  observation seam and asserts canonical plus mirrored selection.

The coordinator already exposes the needed DEBUG observation and race controls:
`setCanonicalApplyGateForTesting`, `debugContextSnapshot`, `debugDrainCanonical`, and
`debugSnapshot` (`MCPReadFileAutoSelectionCoordinator.swift:625-677`), with bounded accounting types
at `:303-360`.

#### 9. Media/binary Reads — **CONFIRMED: exclude them from R4**

Selection storage is path-based and can retain a media path (`WorkspaceModel.swift:148-164`), but
RepoPrompt's prompt context is text-only. Common image, PDF, Office, audio, video, and binary
extensions are explicitly classified as binary (`FileSystemService+ContentLoading.swift:2098-2121`),
and `loadContent` returns nil before reading them (`:904-941`). A selected entry with no loaded text
accounts as zero content tokens (`TokenCalculationService.swift:420-439`) and prompt packaging skips
it (`PromptPackagingService.swift:181-185,268-269`). MCP `read_file` correspondingly fails before
auto-selection when workspace content is unavailable (`MCPServerViewModel.swift:5778-5800`).

Accreting a native image/PDF Read would therefore preserve only a misleading selected path—no media
payload, meaningful token charge, or downstream context. R4 should explicitly accrete text-readable
workspace files only. Media can be reconsidered when selection, token accounting, and packaging have
an actual media context model.

### Recommendation: amend, then implement

**Worth doing:** yes, for successfully observed native Claude text Reads. **As-written go/no-go:**
**NO-GO until amended.** The minimum contract is:

1. observe only real provider results; maintain ID-keyed native Read calls and ignore synthetic/nil-ID
   completions;
2. use conservative positive success evidence, then re-slice the authoritative store with native
   offset/limit and take total/first/last wholly from that current clipped result;
3. resolve from the actual provider cwd to a physical in-scope file, reject base/logical worktree
   paths and escapes, then project physical to logical;
4. enqueue through the existing coordinator with physical `CoverageIdentity`, the same full/slice
   merge semantics, and diagnostic MCP/native provenance;
5. promise eventual accretion only, and skip observations after context closure/rebinding;
6. exclude binary/media; and
7. test translator, handler/hook, coordinator, and bound-context integration seams—not the benchmark
   replay fixtures.

### Maintainer-guidance check

- **User impact/invariant:** downstream selected-context surfaces should faithfully include text files
  successfully read by the active agent, without selecting a different checkout or an unproved read.
- **Root-cause confidence:** high; native results terminate in transcript state while the sole
  `read_file` accretion producer is the MCP read path (eligible `file_search` has its own producer).
- **Authority:** keep path validation/content truth in the workspace store and merge/order truth in
  `MCPReadFileAutoSelectionCoordinator`; the handler only correlates observations.
- **State safety:** fail closed on nil IDs, uncertain success, stale run bindings, path ambiguity,
  root escape, unavailable text, and teardown; never fall back to active-tab routing.
- **Scale/observability:** one extra bounded store read per accepted native observation; retain
  MCP/native source in coordinator diagnostics and measure accepted/skipped/fallback reasons.
- **Recommended scope:** a narrow Claude-native text-read bridge, not a parallel accretion pipeline,
  media context feature, or selection-schema migration.
- **Validation boundary:** focused translator/tool-tracking/coordinator tests plus one run-bound
  worktree integration test; no live-app or full-suite requirement unless implementation touches
  provider lifecycle beyond this seam.

## Investigation Log

### Phase 4 — agent verification of the `can_use_tool` enforcement seam

**Hypothesis:** the oracle's preferred R4 alternative ("narrow native Read's role" with a
pre-tool-use guard) is only viable if a permission seam exists that can deny a *native* tool
call before it runs.

**Findings — a real seam exists, with two hard limits:**

- `ClaudeNativeProcessSessionController.handleControlRequest` handles
  `subtype == "can_use_tool"` and receives `tool_name` plus the full `input` dict — which for
  native `Read` carries `file_path` (`ClaudeNativeProcessSessionController.swift:1770-1814`).
  RepoPrompt already implements both an auto-approve path
  (`repoPromptPermissionAutoApprovalMatch` → `allowPermissionResponsePayload`) and a user
  decision path (`buildApprovalRequest` → `permissionResponsePayload(decision:)`,
  `:2020-2089`). So denying/redirecting a native `Read` for an in-workspace text path is
  architecturally supported — no new protocol work.
- **Limit 1 — bypass mode makes it inert.** When `config.permissionMode == "bypassPermissions"`,
  the runtime appends `--allow-dangerously-skip-permissions`
  (`ClaudeNativeProcessSessionController.swift:1996-1997`). Claude then does not issue
  `can_use_tool`, so the guard never fires.
- **Limit 2 — the compatible runtime has no seam at all.** An exhaustive search of
  `Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/` finds **zero**
  `can_use_tool` / `control/` handling. GLM, Kimi, and `customClaudeCompatible` sessions
  therefore cannot be guarded this way.

**Conclusion:** the guard is a **best-effort reinforcement on the native Claude runtime only**,
not an enforcement boundary. This *strengthens* rather than weakens the recommendation: the
prompt-layer rule must be the primary mechanism (it reaches every provider and every permission
mode), with the guard as opportunistic backup where it applies. It also further undercuts R4's
bridge, which is likewise Claude-only but far more expensive.

### Agent spot-checks of pair findings

Independently re-verified before folding into conclusions:

- `SystemPromptService.swift:684-686` — `binaryAssetReadingGuidance` branches only on
  `agentKind == .codexExec`; every other kind gets "Use the native Read tool…". Cross-checked
  against `OpenCodeIntegrationConfiguration.swift:293-312` (`"read": "deny"`, `"bash": "allow"`).
  **Confirmed defect.**
- `MCPPromptContextToolProvider.swift:168-173` — `prompt` drains only when `op == "export"`.
  **Confirmed**; R4's "prompt drains" is too broad.
- `WorkspaceRootBindingProjection.swift:122-140` — `translateInputPath` replaces a logical-root
  prefix with the physical worktree root for absolute logical paths; `:190-210`
  `projectedLogicalDisplayPath(forPhysicalPath:)` returns `nil` when the physical path is not
  under a bound root. **Confirmed** — input translation would silently retarget a base-checkout
  read to a different file, while the reverse projection fails closed.
- `grep -rn "agent-mode-file-tools"` returns exactly one consumer:
  `Scripts/test_agent_mode_file_tools_benchmark.py:15`. **Confirmed** — R4's fixture instruction
  targets a Python latency/lifecycle harness that never executes Swift selection code.

## Root Cause

**Both contracts are treating symptoms of one defect: tool-surface truth is duplicated as free
prose across five render sites, keyed on the wrong axes, with no machine-checkable link to the
configuration that actually enforces exposure.**

The five render sites:

1. `RepoPromptMCPInstructions.agentModeText`
2. `RepoPromptMCPInstructions.externalMCPText` (same dead wording; reached by external clients
   *and* RepoPrompt's own CLI via `.unknown`)
3. `RepoPromptMCPInstructions.discoverText`
4. `AgentModePrompts.providerReadPolicy` (explore/engineer only; `default: ""`)
5. `SystemPromptService.codingAgentPrompt` **plus a second inline Claude-only copy** for
   pair/design (`SystemPromptService.swift:854-867`)

The wrong axes: the instructions layer is keyed on `MCPRunPurpose` only — **provider-blind and
session-state-blind** — while actual tool exposure varies by provider family, by permission
profile, and (for the worktree hazard) by session binding state. Enforcement lives in
`ClaudeCodeIntegrationConfiguration`, `CodexOverrides`/`CodexNativeSessionController`, and
`OpenCodeIntegrationConfiguration`, and **nothing ties the prose to those lists**.

Per B1, the contradiction was imported wholesale in the parentless genesis commit `351e9803`
and the wording has never been edited since. This is not drift — it is a birth defect with no
immune system.

R4's leak has a **different, narrower root**: a side-effectful context-accounting pipeline
(`enqueueReadFileAutoSelection`) is attached to only one of the two channels through which an
agent can read a file. But note the two roots interact — every *text* read that R4 would harvest
is a read that the (broken) routing prose failed to prevent.

## Recommendations

Ranked by user-visible impact × fix cost.

### Do now — PR 1: consolidate the four text surfaces + pin them with tests

**Division of labor (the design rule):** *instructions describe what MCP tools do; prompts
describe how this provider in this session should route; configs enforce; tests synchronize.*

1. **Rewrite all three `RepoPromptMCPInstructions` variants to positive capability claims only**
   (`RepoPromptMCPInstructions.swift:31-102`). Remove every native tool name, every
   "instead of X", and every absence claim. Rationale: the same string is rendered by Claude as
   a truncatable system-prompt block, by **Codex as a tool-namespace description**, and is
   **discarded entirely by Zed** (B2) — so any absence claim written there is false for some
   consumer and misplaced for others. Include **`externalMCPText`**, which R1 as written omits.
   Keep the Claude 2KB budget as an `assert < budget` with a code comment citing the Anthropic
   doc — never assert an exact byte boundary (B2: "2KB" is undefined as bytes vs. chars).
2. **Fix `binaryAssetReadingGuidance`** (`SystemPromptService.swift:684-686`) — it currently
   instructs OpenCode and Cursor to use a native `Read` tool that managed OpenCode **denies**.
   *This defect is not mentioned anywhere in R1 and is the single most clearly-broken instruction
   found.*
3. **Generalize `providerReadPolicy` into a shared per-provider tool-policy fragment** and have
   `codingAgentPrompt`, the explore/engineer prompts, **and the pair/design assembly** all call
   it, deleting the inline duplicate at `SystemPromptService.swift:854-867`. Remove the
   `default: ""` fallthrough. Per-family content:
   - **Claude family** — binary/media → native `Read`; workspace text → MCP `read_file`, no
     exceptions; never mutate files via shell.
   - **Codex** — MCP owns all file work; shell is a fallback for outside-root only. Preserve the
     already-correct top-level Codex binary guidance (do not regress it).
   - **OpenCode** — no native read exists; **never use `bash` `cat`/`sed`/redirection for
     workspace reads or mutations** (this is the real leak channel and no current text addresses it).
   - **Cursor** — provider-safe generic wording that does not name a native `Read`.
4. **Add contract tests** (see Preventive Measures) in the same PR so the new wording is pinned.

### Do now — PR 2: the worktree rule

5. Emit a worktree fragment **only when the session has bindings** — session state is known to
   prompt assembly and structurally cannot live in the static instructions string. Wording must
   be more precise than R1c's draft: *native tools get cwd-relative paths, for the primary bound
   root only; never reuse an MCP-displayed absolute workspace path in a native tool or shell
   command.* Acknowledge the `..`-escape and multi-root caveats (one process cwd, N roots).
   Add one *factual* sentence near the head of the instructions string (truncation keeps the
   head): displayed paths are logical identities; MCP tools translate them, nothing else does.

   This is ranked highest for impact: it is a **data-corruption class** bug — `bash` in a bound
   session can write the canonical checkout — and MCP's own logical display paths manufacture
   the very inputs that break native tools.

### Amend, don't implement — R4

6. **Replace R4's "build the bridge" with "narrow the role, instrument, revisit."** Every *text*
   read the bridge would harvest is a read that violated the read policy. Native `Read` is kept
   for two legitimate jobs — binary/media (verified worthless to accrete: selections hold the
   path but packaging skips binary content and it accounts zero tokens) and `.claude/skills`
   discovery (not workspace context). The bridge is elaborate accounting machinery for policy
   violations, and can only promise *eventual* accretion that the next `manage_selection` may miss.
   - Ship the prompt narrowing (rides item 3, free).
   - Optionally add the `can_use_tool` guard for native `Read` on in-workspace text paths, with
     a denial message naming `mcp__RepoPrompt__read_file` and the same path — **documented as
     best-effort**: inert under `bypassPermissions` and absent on the compatible runtime.
   - Add a cheap counter in `ClaudeAgentToolTrackingHandler` for native `Read` results resolving
     to in-workspace text files — all the observation machinery, none of the accretion machinery.
   - Revisit the bridge **only if** that counter shows the leak survives prompt hardening.

   If the bridge is ever built, R4 must first be amended with: real-provider-results only
   (exclude synthetic completions), authoritative store re-read for `totalLines`/first/last taken
   wholly from the fresh clipped result, fail-closed path resolution that **never** feeds observed
   native paths through `translateInputPath`, physical `CoverageIdentity` supplied as MCP does,
   an honest *eventual* ordering guarantee, binary/media excluded, and Swift test seams
   (translator / handler / coordinator DEBUG hooks / bound-context integration) instead of the
   Python benchmark fixtures.

### Defer

7. `allowNativeBashTool` is a **no-op for `.agentRun`** (Bash was never in that base list) —
   document with a comment now, clean up later. No behavioral harm.
8. Interactive-Codex shell breadth is not fixable at the text layer; the per-provider wording in
   item 3 is the mitigation.

## Empirical Study (retrospective session mining, 2026-07-25)

Agent-established corpus and join key (verified before dispatch):

- **RepoPrompt CE session store** — `~/Library/Application Support/RepoPrompt CE/Workspaces/*/AgentSessions/AgentSession-<uuid>.json`.
  **967 sessions, 61 MB, 2026-06 → 2026-07.** All 967 parsed cleanly.
  Records `agentKind`, `worktreeBindings`, and per-tool `toolExecution{toolName,status,keyPaths,summaryText}`.
  **`keyPaths` is empty for every read** (74/74 native, 11789/11789 MCP) → **paths are NOT recoverable here**.
- **Claude Code native store** — `~/.claude/projects/*/<uuid>.jsonl`. **995 files, 441 MB**, same date range.
  Full tool args including `Read` `file_path`/`offset`/`limit`.
- **JOIN KEY (verified):** CE `providerSessionID` → `~/.claude/projects/*/<providerSessionID>.jsonl`.
  Confirmed live match on `AgentSession-4A6D60BF…` → `22a319c8-3932-422e-b22e-f38f133d8f2a.jsonl`.
  This is what makes path-level classification possible; without it the study stalls at frequency-only.

Baseline measurements taken by the agent:

| Metric | Value |
|---|---|
| Sessions by kind | codexExec 649 · claudeCode 293 · unknown 24 · openCode **1** |
| Claude: native `read` vs MCP `read_file` | **73 vs 684 → native = 9.64% of reads** |
| Claude sessions using native `read` ≥1× | **20 / 293 (6.8%)** |
| Codex: native `read` vs MCP `read_file` | 1 vs 11 103 (confirms Codex MCP-dependence) |
| Sessions with `worktreeBindings` | **115 / 967 (11.9%)** |
| `Grep` / `Glob` / `Edit` tool executions, any session | **0** |

### Study Findings: R4 — native Read leak composition

#### Join coverage and counting boundary

The join is **low-coverage overall but high-coverage where it matters for R4**. Of the 293 CE
`claudeCode` records, 123 currently contain a `providerSessionID` and **94 / 293 (32.1%)**
resolve to exactly one local Claude JSONL. Among the 20 CE sessions with a native `read`,
**19 / 20 (95.0%)** join, covering **72 / 73 (98.6%)** of the established CE-store native-read
events. The one unjoined session is the only June native-read session, so its one path and
bucket are unknowable. All downstream path results exclude it.

There is also a material source-population discrepancy. The 19 joined provider histories contain
**126 unique native `Read` `tool_use` IDs**, not 72. The additional 54 calls are provider-
history events in two joined JSONLs that are not retained as `read` activity in the persisted CE
projection. They are still in scope: all 126 are in provider-ID-joined transcripts, all have
`entrypoint == "sdk-ts"`, and all are non-sidechain; none came from a plain `claude` CLI
transcript. The primary table therefore follows the task's “every native `Read` tool_use” rule
and uses **n = 126**. A baseline-aligned sensitivity check below shows that the conclusion does
not depend on those extra 54 calls. This does not replace the established **n = 73** CE-store
baseline; it shows that the baseline is a persisted-projection count, not a complete provider-
history count.

#### Roots, classification, and outcomes

For all 19 joined native-read sessions, roots came from that CE session's sibling
`workspace.json.repoPaths`; the transcript `cwd` was inside one of those roots in **19 / 19**
sessions, no session had any `worktreeBindings`, and the `cwd` fallback was never used. Paths were
`expanduser` + lexically normalized, relative MCP paths were resolved against the session roots,
and bucket precedence was binary/media → agent config → outside roots → workspace text. This
makes the joined classifications high-confidence. Remaining error bars are the unjoined event,
possible historical mutation of `workspace.json`, and symlink/case aliases not visible in the
stored strings; the exact `cwd`/root agreement argues against a material root error here.

`tool_result` was joined by `tool_use_id`; an explicit `is_error: true` is an error and an omitted
or false value is success. Every recoverable native call had a corresponding result.

| Bucket | Events | Sessions | Distinct paths | Success / error |
|---|---:|---:|---:|---:|
| (a) binary/media | **0** | 0 | 0 | 0 / 0 |
| (b) `.claude/` or agent config | **2** | 2 | 2 | 2 / 0 |
| (c) outside all workspace roots | **19** | 7 | 19 | 18 / 1 |
| (d) **text inside a workspace root** | **105** | **15** | **62** | **105 / 0** |
| **All joined native `Read` tool uses** | **126** | **19** | **83** | **125 / 1** |

There were no image, PDF, audio, video, or Office reads at all. Bucket (b) consists of two
Claude runtime `~/.claude/.../tool-results/*.json` reads. Bucket (c) is principally Claude task
output under `/private/tmp`, plus one `/tmp` source file. Thus **83.3% (105 / 126)** of observed
native reads were the exact R4 failure mode, not legitimate binary reading.

#### Actual and residual leak

The 15 bucket-(d) sessions contain 122 native `Read` calls plus 175 MCP `read_file` calls:
**297 total reads** on the two channels. Bucket (d) is therefore **105 / 297 (35.4%) of all reads
in those sessions**. Exact normalized-path comparison found that only **8 / 105 (7.6%)** bucket-
(d) events, covering 6 distinct files, were also read through MCP `read_file` in the same
session. The residual leak is consequently **97 successful events (92.4%) across 56 distinct
files and 15 sessions**. This is the decision-driving number.

The established-baseline sensitivity check is nearly as strong. Monotonic timestamp/order
alignment maps all 72 joined CE-store events to JSONL calls (70 agree within 0.5 seconds; two
persisted projection timestamps lag their provider calls but preserve order): (a) 0, (b) 2,
(c) 6, and **(d) 64**. Of those 64, 6 were MCP-covered and **58 remained residual**; the 73rd
baseline event is the unjoined unknown. The R4 verdict therefore survives the conservative
persisted-store boundary.

Slice semantics are material. Of the 105 full-history bucket-(d) reads, **79 (75.2%) were
ranged** and 26 were full-file: 76 supplied both `offset` and `limit`, 2 supplied only `limit`,
and 1 supplied only `offset`. On the baseline-aligned 64, the split is likewise **41 ranged / 23
full**. A bridge that records only whole-file selection would lose the dominant observed
semantics.

#### Month trend

| Execution month | CE native `read` | CE MCP `read_file` | Native share | Recoverable bucket (d) |
|---|---:|---:|---:|---:|
| 2026-06 | 1 | 20 | **4.8%** | unknown: the one native event is unjoined |
| 2026-07 through the corpus cutoff | 72 | 664 | **9.8%** | **105** full-history events; 64 baseline-aligned |

By both volume and share of read operations, native use is **rising, not falling** (native share
roughly doubled). June has only 21 total read operations and one read-active session, while July
is a partial month with much more activity, so this is directional rather than a stable rate
estimate. Still, the joined data do not support “prompt narrowing has driven native text reads
to zero”: the latest bucket-(d) event is July 23, when 27 occurred. If the hardening landed after
July 23, this corpus has no post-change exposure and cannot evaluate it.

#### Reproducible key logic

The complete scratch implementation used for the asserted totals is
`/tmp/r4_native_read_study.py`; its counting core is:

```python
jsonl_by_id = defaultdict(list)
for p in Path("~/.claude/projects").expanduser().glob("*/*.jsonl"):
    jsonl_by_id[p.stem].append(p)

for session_path in CE_WORKSPACES.glob("*/AgentSessions/AgentSession-*.json"):
    ce = json.load(open(session_path))
    if ce.get("agentKind") != "claudeCode":
        continue
    matches = jsonl_by_id.get(str(ce.get("providerSessionID")), [])
    if len(matches) != 1:
        continue
    roots = json.load(open(session_path.parents[1] / "workspace.json"))["repoPaths"]
    uses, result_by_id = parse_tool_blocks(matches[0])  # unique by tool_use.id
    mcp_paths = {
        resolve(u["input"]["path"], roots, u["cwd"])
        for u in uses if u["name"].lower().endswith("__read_file")
    }
    for u in uses:
        if u["name"] != "Read":
            continue
        p = normalize(u["input"]["file_path"], u["cwd"])
        bucket = (
            "a" if suffix(p) in BINARY_MEDIA_EXTS else
            "b" if is_agent_config(p) else
            "c" if not any(is_inside(p, root) for root in roots) else "d"
        )
        outcome = "error" if result_by_id[u["id"]].get("is_error") is True else "success"
        covered = p in mcp_paths
        ranged = "offset" in u["input"] or "limit" in u["input"]
```

#### Verdict and maintainer-guidance check

**GO-ONLY-IF: build a narrow R4 bridge.** The driver is **97 residual successful workspace-text
reads** (56 files, 15 sessions), with only 7.6% later covered by MCP and 75.2% carrying slice
semantics. The stricter n=73 baseline boundary still yields at least **58 known residual events**
after join loss. That is enough demonstrated failure to justify a bridge, despite the small
single-user sample and the already-hardened prompt.

The condition is substantive: reuse the existing workspace-root/path and selection authorities;
accrete only successful in-root text reads; preserve `offset`/`limit`; make MCP/native repeats
idempotent; and make binary/media, agent config, outside-root, failed, and unresolved reads
no-ops. Do not add a second root classifier or re-read file content merely for accounting.
The invariant is “every successful workspace-text read contributes the same bounded selection
slice regardless of read channel.” State-safety risk is accidental selection pollution; scale
risk is duplicate content work. The smallest validation boundary is a provider-native `Read`
success event through the real selection delta, with focused cases for both/one/neither range
field, deduplication, and every no-op bucket.

### Study Findings: R1 — dead-guidance cost and worktree incidents

#### A. Cost of dead guidance

**Join coverage and tool exposure.** Of 293 CE `claudeCode` records, 123 have a
`providerSessionID` and **94 / 293 (32.1%)** join to a local Claude JSONL (94 unique
provider sessions). Ninety-two joined transcripts contain 136
`deferred_tools_delta` tool-list records. Across every `addedNames`, `readdedNames`,
`removedNames`, and `addedLines` field, **`Grep`, `Glob`, and `Edit` appear 0 times**.
They do appear as prose in MCP instructions, but not as loaded or deferred tool schemas.
The deliberately constructed session `3796873c-…`, named *Claude tool-exposure probe
(deferred vs disallowed)*, asked the model to enumerate both lists. Its verbatim result was:

> “Tools with schemas loaded/callable in my session: `Bash`, `Read`, `ReportFindings`,
> `Skill`, `ToolSearch`, `Workflow`.”
>
> “None of `Edit`, `Write`, `Grep`, or `Glob` appear in either list.”

Its `ToolSearch` query for the four names returned **“No matching deferred tools found.”**
This confirms that `--disallowedTools` removes these schemas from the model's callable
inventory; they are not merely present and permission-denied at execution time.

There is one important qualification to the zero-execution baseline. The 94 joined JSONLs
contain **one unique rejected `Edit` tool-use ID**, but it is the same diagnostic probe, whose
user prompt explicitly ordered: **“Then attempt to invoke a native tool named `Edit`.”** The
runtime replied verbatim:

> `Error: No such tool available: Edit. Edit exists but is not enabled in this context. Use one of the available tools instead.`

There are **0 `Grep` attempts, 0 `Glob` attempts, and 0 organic `Edit` attempts in the other
93 / 94 joined sessions**; there are still zero successful executions in the full 967-session
CE baseline. Thus the prose can seed a disabled tool name and a forced call can fail, but this
corpus shows **no ordinary failed-call cost attributable to the guidance**. The operational
severity of “agents waste calls on dead tools” moves down. Trust erosion is plausible but not
measured. Pre-execution rejections in the 199 unjoined Claude records are not observable, so
this is not a 293-session absence claim.

**The instruction-budget cost is live, not theoretical.** Ninety joined transcripts contain
**106 / 106 identically truncated** `mcp_instructions_delta` blocks. Reconstructing the exact
`externalMCPText` source variant recorded in those blocks gives **2,896 characters / 2,914
UTF-8 bytes** before Claude rendering. Claude retained exactly the first **2,048 characters /
2,064 bytes** of RepoPrompt content, then appended the client marker `… [truncated]` (13
characters / 15 bytes). Thus the rendered payload is **2,061 characters / 2,079 bytes**, or
**2,077 characters / 2,095 bytes** including the `## RepoPromptCE\n` heading. The retained
content itself is already 2,064 bytes, so the observed cap is character-based for this
text/client version. This is direct practice-level evidence for the documented per-server “2KB”
constraint.

There is also an unresolved cross-finding contradiction: the text fingerprint is
**`externalMCPText`**, the `.unknown` variant, even though finding 6's code path predicts that
provider-launched Agent Mode connections receive `.agentModeRun → agentModeText`. Either purpose
resolution failed for these deliveries or Claude recorded a second, non-policy-bound MCP
connection. The transcripts prove that the model received this truncated external variant during
Agent Mode sessions; they do **not** prove that `agentModeText` itself was truncated. That routing
question needs a focused live trace, but recommendation 1 already covers both variants.

The delivered tail is `expect a report pat… [truncated]`. The exact **848 characters / 850
bytes** removed from the source begin mid-word and are:

```text
h in their summary, not just an inline response.

SHARING AN ORACLE / CONTEXT_BUILDER EXPORT: Pass `export_response: true` on `context_builder` or `oracle_send` to capture the response as a shareable file. The call returns `oracle_export_path` (the file path) and `oracle_export_instruction` (a ready-made "Read the Oracle export at `<path>` with `read_file` …" sentence). To hand the export to a delegated child agent, include `oracle_export_path` inside the `message` you send on your next `agent_run` `start` or `steer` call. You may emit `oracle_export_instruction` verbatim at the head of that `message`; the child already has `read_file` and will open the export itself.

Workspace tabs isolate tab contexts for parallel tasks. Use bind_context with context_id to bind this connection to the intended tab context for multi-window/tab routing.
```

So truncation removed part of delegation guidance, all Oracle/context-builder export handoff
guidance, and all tab-binding guidance in every recorded delivery. The full
`RECOMMENDED over built-in equivalents:` paragraph is **473 characters / 481 bytes**: **23.3%
of retained RepoPrompt content** (481 / 2,064 bytes), **23.1%** of the rendered payload including
the client marker (481 / 2,079), or 23.0% if the Claude heading is also included.
Removing/recasting it does not by itself bring the original 2,914-byte string under
the observed cap, but it recovers almost a quarter of the scarce delivered budget and moves
later, currently missing guidance forward. This upgrades the ordering/budget rationale for
recommendation 1 even while the failed-call rationale moves down.

**OpenCode exposure is near zero for this user.** The verified corpus has **1 / 967 OpenCode
session (0.10%)**, named *Git validation & commit*. Its request said **“perform ONLY Git
validation/commit mechanics. Do not edit files and do not push”**; it presented no binary/media
read opportunity, and its CE projection records no native read. Therefore the
`binaryAssetReadingGuidance` contradiction has **no demonstrated historical trigger here**.
With `n = 1`, nothing can be inferred about OpenCode users generally. It remains a real,
deterministic correctness bug and is trivially cheap to fix, but its user-specific exposure
should rank below defects observed across the Claude corpus.

#### B. Worktree hazard: mechanism observed, incident not demonstrated

**Binding census.** All **115 / 967** bound records have exactly one binding; every
`logicalRootPath` / `worktreeRootPath` pair was extracted to
`/tmp/r1_bound_115.tsv` (SHA-256
`9153f187e211f5ba5000f6a50a25ccdd16b9d83859c22d2a645d32abe534b0ed`). Their composition is
more important than the headline denominator:

- **66** logical roots are under `…/AgentRunWorktreeStartTests-*`;
- **48** are under `…/WorktreeAPISmokeHarnessTests-*`;
- **1** is a real checkout: logical `/Users/tnguyen/workspace/repoprompt-ce` bound to physical
  `/Users/tnguyen/workspace/.repoprompt-worktrees/repoprompt-ce/rp-agent-c2a6c6c7-fix-duplicated-menu-check-for-up-914de1c4`.

Thus **114 / 115 are XCTest/smoke artifacts**, not historical user exposure. By provider, 111
are `claudeCode` and four are `codexExec`; three of the Codex records are also test artifacts.

**The requested Claude path test has no empirical denominator.** All 111 bound Claude records
are zero-item test artifacts: 84 have no `providerSessionID` and 27 use the synthetic literal
`stable-provider-identity`. Consequently the corpus contains **zero real bound Claude runs**, and
**0 / 111** records join to a Claude JSONL. There are no native `Read` paths, Bash commands,
relative-command denominator, or MCP outputs to recover. This means **no silent-wrong-tree Claude
read or write is confirmed**, but it does *not* mean the hazard did not fire historically: for
Claude, `n = 0` exposed runs and the corpus is inconclusive.

The lone real bound record is Codex, and its `codexConversationID` does join to the native Codex
JSONL. It provides a useful secondary check:

- native Read calls: **0**; MCP `read_file`: **6**;
- native `exec_command` calls: **18**;
- command strings containing the absolute logical root: **0 / 18**;
- command strings containing any absolute checkout path: **0 / 18**;
- relative/no-absolute command strings with `workdir` equal to the physical worktree:
  **18 / 18**;
- worktree-mutating command attempts were also relative and safely scoped: two
  `make dev-format`, two `git add`, and two `git commit` invocations (**6 / 18**).

A representative mutating call was:

```json
{"cmd":"git commit --no-gpg-sign -m \"Fix duplicated update menu command\"","workdir":"/Users/tnguyen/workspace/.repoprompt-worktrees/repoprompt-ce/rp-agent-c2a6c6c7-fix-duplicated-menu-check-for-up-914de1c4"}
```

There is **no demonstrated divergence or harm** in that run. Three MCP `apply_edits` results
resolved to physical worktree paths; lint, guardrails, and the focused build passed; and the
provider's final message reported **“Final status: clean (`git status --short` produced no
output)”** with commit `f20498bb…` on the worktree branch. The observed failures were explicitly
sandbox/cache access and commit-signing failures, followed by successful retries—not wrong-tree
symptoms.

**The input-manufacturing mechanism did occur, but only in labeled metadata.** In that one real
bound provider transcript, **8 / 12 MCP result messages (66.7%)** exposed a copyable absolute
logical checkout: all six `read_file` results named it inside the explicit scope/remapping banner,
and both `git` results named it as `Main checkout:` plus a worktree warning. The displayed
`read_file` target itself remained relative. The other results were three `apply_edits` outputs
showing the physical worktree and one path-free `set_status`. A representative `read_file`
result said verbatim:

> `Scope: session-bound worktree. Displayed paths use logical/canonical roots; filesystem reads use that bound checkout.`
>
> `Root remapping: repoprompt-ce /Users/tnguyen/workspace/repoprompt-ce → session-bound worktree`

So a copyable bad input was present eight times in **1 / 1 real bound run**, but never as an
unlabeled file target; each occurrence also explained the remapping or worktree distinction. The
model never copied it into native commands. This confirms a mitigated latent mechanism, not the
claimed data-corruption incident.

**Maintainer-guidance check.** The invariant is that provider guidance names only executable
tools and native I/O in a bound run never escapes the physical checkout. Truncation and logical
path display are confirmed; guidance-caused failed calls and a wrong-tree incident are not.
Provider launch configs/tool schemas and binding-aware path translation are the authorities.
The state-safety risk remains high *if* a logical path is reused, but the corpus contains only
**1 / 967 real bound run (0.10%)** and no bound Claude exposure. The smallest evidence-led scope
is the prompt/instruction cleanup now, followed by a
real bound-Claude reproduction or diagnostic counter before treating the worktree rule as the
highest observed incident class.

**Re-rank these recommendations:**

1. **Move recommendation 1 up to the highest evidence-supported priority** (with recommendation
   4's contract tests attached). The `externalMCPText` variant actually present in the joined
   Agent Mode logs is truncated **106 / 106** times, and dead comparison prose consumes **23.3%**
   of retained RepoPrompt bytes. Keep the positive-capability rewrite, budget assertion, and
   ordering fix; change its rationale from failed-call prevention to restoring external-variant
   instructions that are demonstrably cut. Trace why these runs received `.unknown`; do not yet
   claim that `agentModeText` itself was truncated.
2. **Move recommendation 5 down from “highest impact / do-now PR 2” to the first defensive
   follow-up after PR 1, or gate it on one real bound-Claude reproduction/counter.** Keep the
   proposed rule available because the logical-path manufacturing mechanism is confirmed and the
   consequence could be severe. Do not describe historical corruption as established: real bound
   usage is only **1 / 967**, Claude has `n = 0`, and the one real Codex run was safe despite eight
   explicitly labeled logical-path exposures.
3. **Move recommendation 2 down within PR 1, below the shared policy/test work, but still fix it
   opportunistically.** Exposure here is 1 / 967 with no trigger; correctness is certain and fix
   cost is tiny, so this is de-prioritization rather than dismissal.
4. **No empirical movement for recommendations 3 and 6–8.** This study did not test their central
   claims. Recommendation 4 moves only as inseparable coverage for the now-confirmed truncation
   and exposure-matrix defect.


### Agent corrections to the empirical study (post-mining verification)

Five corrections, three of which change conclusions. **Two are corrections to the agent's own
earlier numbers.**

1. **CORRECTION (agent error) — the worktree exposure figure was wrong.** The baseline table's
   "115 / 967 (11.9%) sessions with `worktreeBindings`" counted a non-empty list as user
   activity. **114 of the 115 are XCTest/smoke artifacts** with roots under
   `/var/folders/.../T/AgentRunWorktreeStartTests-*` (66) and `WorktreeAPISmokeHarnessTests-*`
   (48). **Real worktree usage is 1 / 969 sessions (0.10%)** — a single `codexExec` run. The
   user independently flagged this ("I mostly never tried worktree"), and they were right. The
   R1 miner caught the same contamination independently. All worktree-impact reasoning that
   relied on 11.9% is void.

2. **RESOLVED — the `externalMCPText` "routing bug" is not a bug.** The R1 miner correctly
   observed that joined Agent Mode transcripts carry the `.unknown` variant and flagged possible
   purpose-resolution failure. Cause identified: `~/.claude.json` has **`RepoPrompt` as a
   top-level `mcpServers` entry and `RepoPromptCE` as a per-project entry**. Claude Code sessions
   therefore connect to the user's *own* project-scoped `RepoPromptCE` server as a plain external
   client (`.unknown` → `externalMCPText`, rendered under the observed `## RepoPromptCE`
   heading), independently of the agent-mode-bound connection. No `purposeForNewBootstrapConnection`
   defect is implied. **Do not open a routing investigation.**

3. **GENERALIZED — truncation is not confined to the observed variant.** Measuring the rendered
   source strings directly:

   | Variant | chars | bytes | vs 2 048 cap |
   |---|---:|---:|---|
   | `agentModeText` | 2 445 | 2 461 | **over by 397** |
   | `externalMCPText` | 2 984 | 3 002 | **over by 936** |
   | `discoverText` | 616 | 628 | fits |

   The miner empirically proved `externalMCPText` truncation (106/106 deliveries, cut at exactly
   2 048 chars). `agentModeText` is **also over the cap** and will lose its tail — the
   `SHARING AN ORACLE / CONTEXT_BUILDER EXPORT` paragraph — by the same mechanism. So the
   budget argument applies to **both** file-tool-exposing variants, strengthening recommendation 1.

4. **NEW — the OpenCode/Cursor `binaryAssetReadingGuidance` defect is one day old and
   self-inflicted.** `git show d2f8f504` shows the branch's own commit
   *"Update system prompt following latest guidances…"* (**2026-07-24 20:51**) **introduced**
   the `agentKind == .codexExec` ternary as an added line. It is not inherited from the genesis
   snapshot. That commit touched **only `SystemPromptService.swift`** (126+/54−);
   `AgentModePrompts.swift` was untouched, so the `providerReadPolicy` `default: ""` gap
   (recommendation 3) is unaffected and still stands.

5. **CRITICAL FOR SEQUENCING — the entire R4 corpus predates the prompt hardening.** The
   hardening landed **2026-07-24 20:51**; the miner's last bucket-(d) native-text-read event is
   **2026-07-23**. **There is zero post-hardening exposure in this corpus.** Every R4 number
   therefore measures the *pre-hardening* prompt. The "narrow the role" remedy has not been
   tested even once, so the miner's rising-trend observation cannot speak to it. This does not
   refute the leak — 97 residual events across 56 files is real — but it means the bridge would
   be sized against a baseline that may already have moved.

## Preventive Measures

**The single highest-yield mechanism: a rendered-surface ↔ exposure-matrix contract test.**

For each `(AgentProviderKind, role/purpose, permission profile)` tuple: render the full prompt +
instructions string, extract every backtick-quoted tool reference, and assert

- (a) every referenced **native** tool is absent from that provider's disallow/deny list for that
  profile, and
- (b) no MCP-owned intent (read text / edit / search) is attributed to a native tool the provider
  lacks.

This one test catches five of the seven text defects found here: the dead `Grep/Glob/Edit`
guidance, the `externalMCPText` duplicate, the `providerReadPolicy` `default: ""` gap, the
OpenCode/Cursor `binaryAssetReadingGuidance` bug, and the pair/design copy drift. It converts this
whole bug class from "text review" to compile-time-adjacent.

Currently **zero** tests reference `RepoPromptMCPInstructions`, `agentModeText`, `externalMCPText`,
or `providerReadPolicy` (exhaustive search across 391 files under `Tests/` and
`Packages/RepoPromptAgentProviders/Tests`). The nearest existing coverage,
`ToolCatalogSnapshotTests.testCodingAgentPromptManifestMatchesRegisteredSchemas`
(`Tests/RepoPromptTests/MCP/ToolCatalogSnapshotTests.swift:45-123`), asserts prompt text and a
curated tool inventory but never compares prompt references to provider disallow lists — which is
precisely why the genesis contradiction survived unchallenged.

Supporting measures:

- Keep enforcement single-sourced in the provider configs and have the test read *those* lists —
  never a second hand-maintained copy.
- Treat the Claude 2KB instruction budget as an approximate client constraint in a code comment
  (`assert < budget`), not a protocol contract.
- For the R4 class: if a side-effectful accounting pipeline is attached to one read channel, add a
  test or assertion that enumerates *all* channels through which that intent can occur.
