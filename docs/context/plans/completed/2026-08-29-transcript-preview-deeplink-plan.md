# Completed outcome

Completed 2026-08-30. M1–M4 shipped in `c78e7b67`, `348639b1`, `52613836`, and `21ae21f2`; M5 was completed by this closeout change. The final disputed decisions were a window-targeted reveal-only `.showAgentUtilityPanel` notification, auto-detected provenance with no fuzzy fallback, and omission of the optional post-mapping existence stat.

The original plan follows intact.

---

# Transcript → Utility-Panel Preview Deep Links — Implementation Plan

**Date:** 2026-08-29
**Status:** Planned, not implemented
**Consultation:** Two independent Oracle lanes received the identical initial prompt. Lane 1 was originally OracleE, which failed 4 consecutive attempts with an infrastructure error (`oracle_failed: retry after checking Oracle browser automation`); at the user's direction **OracleC** replaced it (chat `preview-deep-link-plan-l-F32C2E`). Lane 2 was **OracleD** (chat `preview-deep-link-plan-l-DA9E0C`). Both lanes produced full plans; four material disagreements went through the anonymized cross-challenge protocol (2 rounds). Two settled; two survived and are presented with both positions and the session agent's recommendation in §8.

## 1. User need

Clicking any Markdown/HTML document path that appears in an Agent Mode transcript should open that document **in the built-in right utility panel Preview** (secure MD/HTML renderer), with the panel auto-revealed — no workflow change, no special link syntax. Paths appear as:

1. plain text and `@`-tagged mentions in the user's own message (inert `TaggedFilesBadge`),
2. assistant prose — real markdown links, but far more often bare paths (`docs/report.html`) or backticked inline code,
3. tool results.

All other file types must keep today's behavior (open in the default macOS app).

## 2. Verified current state (all checked against live code this session)

- The preview stack is complete and untouched by this plan: `PreviewDocumentReference` → `AgentUtilityPanelTabState.showPreview(of:)` → `AgentModeViewModel.showUtilityPanelPreview(of:tabID:)` → `AgentPreviewPanelView` (semi/rendered MD, secure scripts-off WKWebView for HTML).
- Panel visibility is per-window in `AgentUtilityPanelPresentationStore` (on `WindowState`); `show()` exists with **zero call sites**. The transcript view (`AgentModeChatDetailView`) has no reference to the store but holds `windowID: Int` (AgentModeView.swift:208) and already posts window-targeted notifications (e.g. `.showAgentWorkflowPopover`, AgentModeView.swift:6155).
- `handleTranscriptURL` (AgentModeView.swift:1961) resolves `repoprompt-preview://` URLs through `AgentPreviewLinkRouter` + `AgentChangesArtifactLinkResolver` (worktree-aware, ambiguity-suppressing) and calls `showUtilityPanelPreview` — but nothing renders that scheme into transcripts, it never reveals the panel, and it sits on the SwiftUI `openURL` environment which NSTextView link clicks never reach.
- Rendered markdown clicks flow: `EnhancedMarkdownCompiler.visitLink` (only source of `.link`) → `AttributedTextView` → `MarkdownTextViewCoordinator.textView(_:clickedOnLink:)` → `MarkdownFileLinkOpener` env value → `WorkspaceFilesViewModel.openFileForMarkdownLink` → **default app**.
- `openFileForMarkdownLink` performs **fuzzy resolution**: case-insensitive basename matching over selected files (WorkspaceFilesViewModel.swift:11806), `resolveFileForUserInput(profile: .uiAssisted)` (11776), then `searchFallbackCandidates(...).first` (11781) — it can open a similarly-named-but-different file. Material to open dispute B (§8).
- `visitInlineCode` attaches no link; bare prose paths are plain text; `CollapsibleUserMessage` is deliberately plain `Text`; `TaggedFilesBadge` is inert.
- `AgentSessionArtifactKind(fileExtension:)` gates exactly `md/markdown/html/htm`. `MarkdownRenderSignature` (MarkdownTextView.swift:12) keys compile dedupe. `visitText` (EnhancedMarkdownCompiler.swift:120) is the prose hook.

## 3. Settled design decisions (agreed by both lanes after cross-challenge)

| # | Question | Decision |
|---|---|---|
| 1 | Click routing | Intercept at the transcript's `MarkdownFileLinkOpener` closure (`AgentModeChatDetailView.markdownFileLinkOpener`): kind-gate via `AgentSessionArtifactKind`; on successful resolution route to `showUtilityPanelPreview` + reveal (state first, then reveal); otherwise fall back toward today's behavior (exact fallback policy: see open dispute B). No compile-time `repoprompt-preview://` emission in rendered markdown — compiled attributed strings are cached and shared and must stay policy-free; NSTextView clicks bypass SwiftUI `openURL` anyway. |
| 2 | Detection placement | **Visitor-level** linkification in `EnhancedMarkdownCompiler` behind a new opt-in option (default **off**; enabled only at Agent-transcript render sites): `visitInlineCode` whole-token path rule (internal spaces allowed), boundary-guarded regex over `visitText` prose runs (spaces excluded). Authored-link precedence is an **explicit invariant** — detection is suppressed while visiting descendants of an authored link (not left to attribute-overwrite ordering) — with a dedicated compiler test. Fenced code blocks excluded in v1. The flag joins `MarkdownRenderSignature`, `MarkdownTextView.==`, and the segmented streaming path **atomically**. Cheap `".md"`/`".htm"` substring pre-guards before regex; detector is purely lexical (no I/O at render time); chat/preview/Oracle rendering stays byte-identical. A tool-result renderer audit is required before declaring the feature complete (if a canonical tool result wraps paths in fenced blocks, that renderer gets narrow support — no global code-block linkification). |
| 3 | Resolution pipeline | Extract `handleTranscriptURL`'s body into a reusable click-time resolution service (`AgentChangesPanelLiveEnvironment.rootInputs` → `AgentPanelCheckoutResolver` → `AgentChangesArtifactLinkResolver.reference`); `handleTranscriptURL` becomes a caller of it and finally gains the reveal. Cancellation checked between awaits; newest click wins; cancel on tab change/disappear. Ambiguity is never guessed across roots. |
| 4 | User messages | `TaggedFilesBadge` becomes clickable early (Button for one previewable attachment, Menu for several), routing through the same opener using canonical attachment metadata (`AgentTaggedFileAttachment.relativePath`), never `displayName`. **User prose linkification is in scope but staged** as its own late milestone (both lanes converged): collapsed branch via attributed SwiftUI `Text` links using a reserved in-process URL form (`repoprompt-preview://transcript-file?path=<encoded>`, decoded by `AgentPreviewLinkRouter`, reaching `handleTranscriptURL` — no OS scheme registration), expanded branch via link attributes threaded into `MeasuredPlainTextView`; **both branches ship together**, gated on (a) `MeasuredPlainTextView` demonstrably hosting link attributes without resurrecting its documented invalidation history and (b) detector precision proven on assistant prose first. Lane A additionally argued against widening `MarkdownFileLinkOpener` with a URL-builder parameter, preferring a static URL helper at the AttributedString construction site; resolved by agent judgment in favor of the static helper (smaller API surface, opener contract stays single-shaped). |

### Detection rules (summary)

- Prose regex (one cached `NSRegularExpression`): optional `~/`, `./`, `../`, `/` anchor; colon-free, space-free segments; terminal `.(md|markdown|html|htm)` case-insensitive; optional `:line` suffix; left/right boundary guards kill `https://…/page.html`, `.mdx`, `a.md.bak`, mid-token hits. Paths with spaces are out of scope in prose (covered by badge metadata and authored links).
- Inline code: entire trimmed single-line span must be one path token, length ≤ 512.
- The detector's extension set lives in Infrastructure (no Features-layer dependency); a parity unit test binds it to `AgentSessionArtifactKind`.

## 4. File-by-file changes

| File | Change |
|---|---|
| `Features/AgentMode/Services/UtilityPanel/AgentTranscriptPreviewLinkResolver.swift` **(new)** | Click-time resolution service lifted from `handleTranscriptURL` (plus existence gate if dispute B resolves toward lane A). |
| `Infrastructure/UI/Markdown/MarkdownFilePathLinkDetector.swift` **(new)** | Pure lexical detector: regexes, pre-guards, extension set, parity-tested against `AgentSessionArtifactKind`. |
| `Infrastructure/UI/Markdown/EnhancedMarkdownCompiler.swift` | Opt-in linkification option; hooks in `visitInlineCode` + `visitText`; explicit authored-link suppression. |
| `Infrastructure/UI/Markdown/MarkdownTextView.swift` | Thread the flag through init, `Equatable`, `MarkdownRenderSignature`, `SegmentedStreamingMarkdownTextView` — atomic with the compiler option. |
| `Features/AgentMode/Views/AgentModeView.swift` | Rewrite `markdownFileLinkOpener` closure (kind-gate → resolve → showPreview → reveal → fallback per dispute B); refactor `handleTranscriptURL` onto the resolver + reveal; generalized click-routing task lifecycle. |
| `Features/AgentMode/Views/AgentModeDetailWithSidebarView.swift` | Reveal wiring (observer or callback per dispute A). |
| `App/Notifications/AppNotifications.swift` | Only if dispute A resolves to the notification: add `.showAgentUtilityPanel` (window-targeted, reveal-only). |
| `Features/AgentMode/Views/AgentMessageBubble.swift` | Enable the flag at assistant/thinking `MarkdownTextView` sites; `TaggedFilesBadge` → Button/Menu via env opener. |
| `Infrastructure/UI/Markdown/MarkdownFileLinkInteraction.swift` | Only if dispute B resolves to lane A: `MarkdownFileLinkTarget.isAutoDetected` + `.markdownDetectedFileLink` key (read in `EnhancedMarkdownView` coordinator). |
| Later milestone (user prose) | `AgentPreviewLinkRouter` gains the reserved `transcript-file` URL encode/decode; `CollapsibleUserMessage` + `MeasuredPlainTextView` gain gated link support. |

Untouched by design: the whole preview/security stack, `AgentUtilityPanelTabState`, `AgentChangesArtifactLinkResolver` logic, `WorkspaceFilesViewModel`, chat views, persistence.

## 5. Milestones (each independently shippable)

1. **M1 — Routing + reveal.** Resolution service; opener rewrite; reveal wiring (dispute A); `handleTranscriptURL` refactor. Ships: authored md/html links open in Preview with auto-reveal.
2. **M2 — Linkification (the crux).** Detector; compiler option + visitor hooks with authored-link suppression; signature/`==`/segmented threading (atomic); enable at transcript prose sites; parity test; DEBUG stress-harness perf check gates the milestone.
3. **M3 — `TaggedFilesBadge` clickability.**
4. **M4 — User-prose linkification** (staged, gated; collapsed + expanded ship together; reserved in-process URL bridge).
5. **M5 — Tool-result renderer audit** and, if warranted, narrow support for the canonical tool-result path surface.

**Non-goals:** fenced-code interiors (v1); line-number scroll targeting in Preview; chat-mode or preview-panel linkification; OS scheme registration; persistence changes; any preview-security change.

## 6. Tests

- **New** `MarkdownFilePathLinkDetectorTests`: positive/negative matrix (relative, nested, bare, `~`, absolute, `:12`, sentence punctuation, uppercase, unicode; `https://…/page.html`, `.mdx`, `.md.bak`, `.md5`, mid-token, multiline inline code); extension-set parity vs `AgentSessionArtifactKind`; large no-match/many-match inputs (accidental-quadratic guard).
- **New** compiler tests: flag-off output attribute-identical to today (chat regression guard); flag-on attribute sets on prose and inline-code matches; authored-link label suppression (`[see docs/report.html](https://…)` untouched); fenced code untouched.
- **New** resolution-service tests: reuse `AgentChangesPresentationTests` fixtures; (dispute B) existence-seam accept/reject incl. a directory named `*.md`; spy-opener ordering test (showPreview before reveal; fallback policy per dispute B).
- **Extend** `AgentPreviewLinkRouterTests` (M4: `transcript-file` URL round trips — relative paths, spaces, Unicode, `%`, `#`, `+`, line fragments), presentation-store tests (`show()` idempotence), signature tests (policy change forces full render; append-only reuse requires equal policies).
- **Regression only:** `AgentPreviewLinkRouterTests` (existing decoding), `AgentUtilityPanelTabStateTests`, `AgentChangesPresentationTests`.
- **Manual/perf:** DEBUG stress harness on a path-dense streaming session before/after M2; multi-window reveal targeting; worktree session opening an agent-authored doc.

## 7. Risks

- **Streaming perf** (highest): pre-guards, single static regex, default-off flag, no new invalidation; gated by the stress-harness check.
- **False positives**: allowlist + boundaries + authored-link suppression + (dispute B) either existence gate or preview missing-state as the surface.
- **Cache cross-talk**: prevented only if the flag lands in `MarkdownRenderSignature`/`==` atomically with the compiler option.
- **Unverified assumptions, each gated behind its milestone:** fenced-code/segmented string architecture (M2 audit), `MeasuredPlainTextView` link-attribute viability (M4 gate), tool-result render path (M5), whether the preview stack can address non-local roots (relevant to dispute B's gate bypass).

## 8. Consultation outcome, disagreements, and resolutions

**Protocol run:** identical initial prompt to both lanes → four material disagreements identified → round 1 relayed each lane's arguments (not identity) to the other → **both lanes swapped positions on two points** (each conceded to the other's original stance with new arguments) → round 2 relayed the fresh arguments → two points settled, two locked in opposite finals. Per protocol, the two survivors are presented with both positions and a recommendation; neither is silently picked.

### Settled by cross-challenge

- **Detection placement (settled → visitor-level).** Lane B originally proposed a post-pass over the compiled attributed string; after round 1 it conceded that visitors know Markdown structure natively (a post-pass must reverse-engineer "am I in a code block / link label?" from attributes), that the differentiated inline-code rule (spaces allowed) needs span extents only structure provides, and that the perf argument was a wash. Lane B's lasting contribution: authored-link precedence must be an explicit suppression invariant with a test, not an attribute-overwrite-ordering accident — adopted.
- **User-prose scope (settled → staged inclusion).** Lane A originally excluded user prose as a permanent non-goal; it conceded that the stated need explicitly includes plain paths in the user's own message and that its perf rationale over-reached (user messages are static, not streaming). Converged: badge first, user prose as its own gated milestone, collapsed+expanded shipping together, reserved in-process URL bridge. Residual API detail (opener widening vs static URL helper) resolved by agent judgment: static helper.

### Open dispute A — panel reveal mechanism (survived 2 rounds)

- **Position 1 (lane A final): window-targeted `.showAgentUtilityPanel` notification.** Reveal-only sibling of `.toggleAgentUtilityPanel`, same `windowID` userInfo contract, observed beside the existing toggle observer → `store.show()`. Grounds: `.showAgentWorkflowPopover` proves the intra-window posting idiom from this exact view; zero initializer churn (the parent maintains parallel DEBUG/release init pairs and two `chatDetail` construction expressions); a defaulted callback (`= {}`) compiles even when a construction path forgets to wire it — a silent per-call-site no-op is worse than the notification's testable targeting; the policy helper still takes an injectable reveal closure for unit tests, with the production closure posting the notification.
- **Position 2 (lane B final): typed callback.** `let revealUtilityPanel: @MainActor () -> Void` (deliberately **not** defaulted, so a missed wiring site fails to compile), passed by the parent as `{ utilityPanel.show() }`. Grounds: the click originates inside the view tree whose direct ancestor owns the store — broadcasting globally and reconstructing that relationship via `windowID` adds an avoidable silent failure mode; the menu-command precedent exists because that caller has no view-tree access, a boundary a transcript click does not cross; spy-closure testing is simpler than NotificationCenter fixtures.
- **Agent recommendation: the notification (position 1), with the injectable-closure testing synthesis.** Verified facts favor it narrowly: the intra-window posting idiom demonstrably exists in this exact view (AgentModeView.swift:6155), the `windowID` member is already load-bearing there, and the parent has four initializer variants plus two child-construction expressions — a non-defaulted callback touches all of them (compile-safe but the largest diff of the options), while a defaulted one has the silent-no-op flaw lane A identified. The mis-targeting risk is pinned by the three proposed tests (matching-window-only, idempotent, reveal-never-hides). This is a reversible, low-stakes choice; if the implementer prefers the compile-checked callback and accepts the init churn, nothing downstream changes.

### Open dispute B — click-time existence gate and fallback policy for auto-detected spans (survived 2 rounds)

- **Position 1 (lane A final): existence gate + provenance marker.** After pure mapping succeeds, one off-main-actor regular-file stat of the exact mapped absolute path (bypassed when the path is not local-stat-able, e.g. remote roots — trust mapping, panel owns load failure). Detected spans carry `.markdownDetectedFileLink` → `MarkdownFileLinkTarget.isAutoDetected`; on any resolution/gate failure a detected span dies as a **debug-logged no-op**, while authored links keep today's fallback exactly. Grounds: "fuzzy resolution is earned by author intent" — an authored link carries human intent; a detected span's only authority is the mapping resolver, and routing its failures into `openFileForMarkdownLink` launders machine guesses through intent-inference machinery. The failure is common, not tail: any multi-root workspace + prose mentioning `README.md`/`PLAN.md` → ambiguous mapping → nil → fuzzy fallback → wrong similarly-named file opens in an external app from a "link" nobody authored.
- **Position 2 (lane B final): no gate, no marker, uniform fallback.** Kind-gate → mapping → on success always open Preview (even if the load later shows missing — visible, in-app, self-correcting on re-click); on mapping failure use `openFileForMarkdownLink` for authored and detected alike; if that fails too, debug-log. Grounds: a local `FileManager` stat inserts a third authority between the addressing layer and the preview panel's designed missing-document surface, and can wrongly kill references the preview stack could address (remote-host roots); the fuzzy risk is bounded by the narrow detector; if live evidence shows wrong-file opens, harden the shared opener once for all callers rather than adding caller-specific provenance plumbing preemptively.
- **Agent recommendation: adopt the provenance marker + no-fuzzy-fallback for detected spans unconditionally; adopt the narrowed post-mapping stat.** The deciding evidence is verified in this session's reads, not hypothetical: `openFileForMarkdownLink` really does case-insensitive **basename matching** (WorkspaceFilesViewModel.swift:11806), UI-assisted fuzzy resolution (11776), and **opens the first fuzzy search candidate** (11781). With linkification live, bare `README.md`-class spans are everyday input, multi-root ambiguity is exactly the case where mapping returns nil, and an external app opening a wrong file from a machine-fabricated link is the worst outcome on the table — lane B's own final concedes the risk exists and defers the mitigation to "if live evidence shows". The provenance half must therefore land with M2, not after. The stat half is genuinely softer: with provenance in place its only marginal benefit is preventing auto-reveal onto a missing document for detected garbage (e.g. whole-token `cp a.md b.md` in a single-root workspace). I recommend keeping it in lane A's narrowed form (post-mapping, single stat, non-local bypass, panel remains the load authority) because "just works" tolerates a quiet nothing better than a panel popping open onto "document not found"; but if the implementer wants the strictly smaller change, dropping **only the stat** (never the provenance marker) is an acceptable fallback and does not reintroduce the dangerous leak.

### Lane failure record

OracleE (originally requested for lane 1) never produced output: 4 attempts, identical `oracle_failed: retry after checking Oracle browser automation` error; the user was consulted and substituted OracleC. Both final lanes' preset identities were verified on every exchange (`model_preset_id`/`model_preset_name` matched the requested presets throughout).
