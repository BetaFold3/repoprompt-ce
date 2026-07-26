# MCP Instructions and Provider Guidance

Current as of 2026-07-25. This document records the prompt-layer decisions for MCP initialization instructions and provider-specific binary-asset guidance.

## Scope

MCP initialization instructions describe RepoPrompt capabilities to clients. The coding-agent system prompt owns provider-specific routing because it knows which provider runtime is active and which non-MCP capabilities that runtime exposes.

## Positive MCP capability claims

MCP initialization instructions make positive capability claims only. They describe what RepoPrompt tools do without comparing them with a client's other tools or claiming that a client-native capability is present or absent.

Provider-specific routing belongs in the provider-aware prompt layer. MCP clients render initialization instructions differently, while Agent Mode providers expose different native capabilities and policies; a shared MCP instruction string cannot state those provider boundaries reliably.

## Tested client budget

Each rendered instruction variant has a tested design budget of 2,048 Swift `String` characters. This is a Claude Code client constraint observed in delivered instructions, not an MCP protocol limit. The budget is enforced by tests across every run purpose and both Code Maps states. A separate ordering contract keeps routing and boundary guidance ahead of optional workflow details.

## Exhaustive provider guidance

Binary-asset guidance branches exhaustively on actual provider exposure:

- Claude Code and its GLM, Kimi, and custom Claude-compatible runtimes retain native `Read` guidance.
- Codex retains its provider-native image or document guidance.
- Managed OpenCode sessions report that binary and media files cannot be read and ask for text content.
- Cursor and the provider-neutral fallback refer only to a provider-native image or document capability when one exists; otherwise they report the limitation without inventing a named tool.

Adding an `AgentProviderKind` therefore requires an explicit guidance decision rather than inheriting a default that may fabricate a capability.

## Deferred R4 native-Read accretion bridge

The R4 native-Read accretion bridge is deferred pending post-hardening re-measurement. The available corpus is pre-hardening: 83% of native Reads in joined Claude agent sessions targeted workspace text, while zero targeted binary/media assets. MCP instructions were truncated in 106/106 observed deliveries, and Grep/Glob/Edit recorded zero executions.

Those measurements justify the instruction and provider-guidance changes, but they do not establish the post-hardening leak rate. No selection-accretion bridge or telemetry behavior is introduced by this decision.

## Deferred worktree guidance

The Worktree path-translation rule is deferred to a conditional prompt fragment. Real worktree use appeared in 1/969 sessions. The code-level path-translation hazard is credible, but its user impact remains undemonstrated in practice; unconditional prompt cost is not justified by the observed usage.
