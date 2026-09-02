# Agent Mode transcript preview deep links

Scope: read when the task touches Agent Mode transcript links that open Markdown or HTML in the utility-panel Preview, including assistant or user path detection, tagged-file badges, tool-result path linkification, click-time resolution, and panel reveal.
Authority: Authoritative
Last-verified: 2026-08-30

## Durable architecture and invariants

- Transcript Preview routing is limited to the case-insensitive extensions `md`, `markdown`, `html`, and `htm`, kept in parity with `AgentSessionArtifactKind`. Other authored file links retain the normal external-file behavior.
- `MarkdownFilePathLinkDetector` is the shared, purely lexical detector. Detection is opt-in and default-off at rendering primitives so chat, Preview, Oracle, and unrelated TextKit surfaces do not inherit transcript policy.
- Assistant rendered Markdown enables detection in compiler visitors. Prose and whole-token inline code may be detected; descendants of authored links and fenced code blocks are excluded. The detection policy participates in render signatures, equality, and segmented-streaming reuse.
- Auto-detected targets carry `.markdownDetectedFileLink` provenance. They never enter fuzzy external fallback when exact transcript mapping fails; authored links may retain their established fallback.
- Click-time resolution flows through `AgentTranscriptPreviewLinkResolver`, using the live Agent Changes root inputs, checkout mapping, and `AgentChangesArtifactLinkResolver`. Composer `@` markers are removed before mapping; in multi-root workspaces, unique canonical root aliases such as `ripple/docs/report.md` select that logical root, while ambiguous aliases fail closed. No post-mapping existence stat is required; the Preview remains the load authority.
- A successful route updates Preview state before revealing the panel. Reveal uses the window-targeted, reveal-only `.showAgentUtilityPanel` notification; it must never toggle a visible panel closed. Superseded click tasks are cancelled and cannot show or reveal stale results.
- Tagged-file interactions use canonical attachment `relativePath` metadata rather than display names. User prose uses the reserved in-process `repoprompt-preview://transcript-file?path=...` bridge in both collapsed and expanded representations; it is not an OS-registered scheme.

## M5 tool-result contract

`ToolMarkdownExpandedContent` opts only its canonical expanded, verbatim monospaced tool-result body into path detection. `ToolResultMarkdownLinkifier` parses that body as Markdown and maps Markdown AST source ranges back to the original string:

- prose and inline-code `md`/`markdown`/`html`/`htm` paths are eligible;
- authored `Link` descendants and `CodeBlock` interiors, including fenced and indented blocks, are skipped;
- the original tool-result text is not re-rendered or rewritten;
- detected ranges are attributed by `TextKitView` and routed through `MarkdownFileLinkOpener` with auto-detected provenance.

`TextKitView` remains default-off and attributes detected ranges only when a `MarkdownFileLinkOpener` is present. Bash-specific surfaces, unified diffs, compressed groups, header chips, and code-block contents do not opt in.

## Owning source seams

- Routing and reveal: `Sources/RepoPrompt/Features/AgentMode/Services/UtilityPanel/AgentTranscriptPreviewLinkResolver.swift`, `Sources/RepoPrompt/Features/AgentMode/Views/AgentModeView.swift`, `Sources/RepoPrompt/Features/AgentMode/Views/AgentModeDetailWithSidebarView.swift`, and `Sources/RepoPrompt/App/Notifications/AppNotifications.swift`.
- Detection and rendered Markdown interaction: `Sources/RepoPrompt/Infrastructure/UI/Markdown/MarkdownFilePathLinkDetector.swift`, `EnhancedMarkdownCompiler.swift`, `MarkdownTextView.swift`, `EnhancedMarkdownView.swift`, and `MarkdownFileLinkInteraction.swift`.
- User and badge surfaces: `Sources/RepoPrompt/Features/AgentMode/Views/AgentMessageBubble.swift` and `Sources/RepoPrompt/Infrastructure/UI/Components/CollapsibleUserMessage.swift`.
- Tool results: `Sources/RepoPrompt/Features/AgentMode/Views/ToolCards/ToolResultMarkdownContent.swift` and `Sources/RepoPrompt/Infrastructure/UI/TextField/TextKitView.swift`.

## Smallest validation routes

- Detection, compiler boundaries, and render-cache policy: `make dev-test FILTER=MarkdownFilePathLinkDetectorTests`, `make dev-test FILTER=EnhancedMarkdownCompilerFileLinkTests`, and `make dev-test FILTER=MarkdownRenderSignatureTests`.
- Resolution, fallback, cancellation, and reveal targeting: `make dev-test FILTER=AgentTranscriptPreviewLinkResolverTests` and `make dev-test FILTER=AgentUtilityPanelPresentationStoreTests`.
- Tagged files and user prose: `make dev-test FILTER=TaggedFilesBadgeInteractionTests`, `make dev-test FILTER=CollapsibleUserMessageLinkificationTests`, and `make dev-test FILTER=AgentPreviewLinkRouterTests`.
- Canonical tool-result detection and click provenance: `make dev-test FILTER=ToolResultMarkdownLinkifierTests`.

## Explicit non-goals

Fenced-code-interior linkification, Bash-specific linkification, unified-diff linkification, compressed tool-group or header-chip linkification, line-number scrolling inside Preview, chat-mode or Preview-panel auto-linkification, OS scheme registration, persistence changes, and Preview security changes are out of scope.
