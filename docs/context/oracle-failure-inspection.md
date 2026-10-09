# Oracle fresh-chat contract, failed-Oracle inspection, and live group expansion

Scope: read when the task touches `ask_oracle` fresh-chat `selection_mode`/`slices` validation, the omitted-`model` rejection or its guidance, persisted Oracle failure diagnostics, the failed Oracle tool card, transcript group (activity-cluster or grouped-history) expansion during an active run, inner follow of an expanded group, or the group header failure-count suffix.
Authority: Authoritative
Last-verified: 2026-10-04

The implementation covers A/B/C below. Both OracleA and OracleB approved the original R6 remediation on 2026-10-04. A subsequent acceptance-test follow-up remediated OracleA R1/P1 (watchdog cancellation without draining), but has not received its closing re-review. The latest full suite still failed; focused tests and live fresh-chat MCP smoke passed. On 2026-10-04 the maintainer requested a local commit and daily use instead of further live verification. Live UI and exact request-content capture are deferred, not passed. The [active implementation plan](plans/2026-10-03-oracle-failure-inspection-plan.md) records the remaining test, review and acceptance gaps.
## Patch A — `ask_oracle` single-send contract

- **Targeting rule** (`MCPOracleToolService.parseSelectionMode`): a non-`current` `selection_mode` needs an explicit conversation target, either `chat_id` or `new_chat:true`. Implicit latest-chat sends still reject `none`/`explicit_slices` with `selection_mode:<mode> requires an explicit conversation target: …`. `consultations` lanes still reject `selection_mode` before admission and always package `current`. Packaging (`OracleSendPackagingContext.applying`) is unchanged and chat-newness-agnostic: `none` sends no selection and no automatic or frozen review diff, and `explicit_slices` sends only the resolved slices. Neither mutates the shared selection.
- **Omitted model** (`validateNewChatModelSelection`): it still throws `MCPError.invalidParams` when more than one configured preset supports the mode, so no model is chosen silently. The message is self-correcting:
  - it starts with the stable `oracle_model_required:` prefix and names the mode and the compatible-preset count;
  - it says this is a pre-provider failure;
  - it lists every compatible preset's escaped name and UUID in deterministic order;
  - it says no `oracle_utils` call is needed;
  - it keeps the `chat_name` display-only sentence.

  Listed presets are *configured*, not availability-checked.
- **Slice entries** (`validateExplicitSlicesBeforeAdmission`): before an operation is reserved, every `explicit_slices` entry needs a non-empty `path` and a usable `ranges` (non-empty array of objects) or `lines` (non-empty string); JSON `null` counts as absent. Otherwise the whole send is rejected, naming each bad `slices[i]` with a copyable example. The Oracle slice resolver also rejects a send in which any requested slice resolves to no line ranges, so no slice is dropped silently. `manage_selection` parsing is unchanged.
- **Wait and cancel stay strict.** Send arguments are still rejected, never reinterpreted. When the rejected call carries `message` or `consultations`, the error adds how to send (omit `op` and `operation_ids`) and says nothing was started or cancelled.
- **Guidance**: one shared `AgentModePrompts.Fragments.oracleFreshChatGuidance` fragment appears exactly once in every prompt family that recommends fresh Oracle lanes. Named-Oracle guidance reuses an exact UUID the session already holds, and keeps its identity checks. The tool description, schema, Knowledge description and the context-overflow remedy all state the same rule. These descriptions are pinned by `ToolCatalogSnapshotTests` hashes and `OracleFreshChatGuidanceTests`.

## Patch B — failed Oracle card diagnosability

- **One projection.** `OracleToolResultInspection` (`Features/AgentMode/Runtime/Transcript/`) is the single pure projection used by both persistence and the card, so a live card and its reloaded copy cannot diverge. It takes the first failure diagnostic in source order, in this priority:
  1. structured `errors[]`;
  2. failed lanes, by lane `index`;
  3. the top-level `error`;
  4. raw non-JSON text, only on trusted failure (`toolIsError` or the normalized status, except cancelled, pending or running).

  A `code` comes only from a structured field, never from free text. Each failed lane contributes its first diagnostic; its other diagnostics (`errors[]` entries and `error`) are not retained but count toward `error_count` and set `error_truncated`.
- **Invocation errors.** On a lane envelope, an invocation-level error alone (the trusted flag or a bare top-level `message`) is a failure only when every lane is terminal and at least one completed, mirroring the single-result rule. It never makes an envelope with unfinished lanes terminal; a failed lane or a structured error still does.
- **Invocation status vs Oracle outcome.** `OracleToolResultInspection.classify` returns `failed`, `notFailed`, or `invocationFailureOnly` when the trusted invocation status is a failure but the Oracle result was unfinished or cancelled. In that last case the summary keeps `status` as the invocation status (for example `failed`) and adds `oracle_outcome` (`nonterminal` or `cancelled`), also in the minimal size fallback. A saved summary's `oracle_outcome` outranks its `status`, so the reloaded card is not a failed card either, and re-saving keeps it.
  - A single result's own status word (for example `pending`) already becomes the saved `status`, so nothing is added.
  - A terminal Oracle outcome under a failed invocation stays a failure, live and reloaded.
  - Only failure classification consumes `oracle_outcome`. `results` are never saved, so a reloaded non-failed card's subtitle still shows the saved invocation `status` rather than the live lane states, as before.
- **Cursor ACP.** A live Cursor ACP result (`acp_status` without `summary_only`) is inspected through its wrapped `rawOutput` (an Oracle object, an MCP `content[]` envelope, or serialized text), or else the ACP `content` text. The ACP or trusted status establishes failure for the wrapped output, so a pending or cancelled Oracle result inside a failed ACP call is not a failure. The Cursor branch of `AgentToolResultPersistencePolicy` persists the same bounded failure fields beside `acp_status`, with `mode` from `rawInput`, and drops `rawOutput`. For a failed ACP call whose wrapped Oracle result was unfinished or cancelled, it keeps `oracle_outcome` beside `acp_status`.
- **Redaction (R6, code approved; acceptance incomplete).** `OracleDiagnosticRedactor` is Oracle-local and redacts the full text before UTF-8 truncation. Quoted `authorization` values are included.
  - Size bound: a diagnostic longer than `maxScannedBytes` (4,096 UTF-8 bytes, eight times the 512-byte primary diagnostic) becomes `<redacted>` whole, before normalization or any regex runs; unsanitized text is never truncated to fit. Within the bound, the slowest known input (a dotted quoted value) redacts in well under 0.1 s.
  - Every rule finds its sensitive ranges in the same control-stripped text before anything is replaced. Each run of overlapping or touching ranges becomes one `<redacted>`, so no rule can erase a delimiter another rule depends on, and rule order does not matter. A pass repeats until the text stops changing; if eight passes do not settle it, the whole diagnostic becomes `<redacted>`.
  - From the first secret-named key whose value opens a quote (double, single, or JSON-escaped `\"` or `\'`), everything to the end of that diagnostic is removed, even when the quote looks closed. The opening delimiter is repeated after the placeholder, for example `password="<redacted>"`, unless another range removed it too (a quote inside URL userinfo, or the backslash of `?password=\"` taken by the URL's query value).
  - Quoted extents are never trusted. A quote may be unterminated, broken by a line break (LF or CRLF), closed only by an escaped delimiter, mismatched, or closed by a later assignment's quote, and a backslash escape may hide a nested key. No later secret, quoted or bare, survives.
  - URL userinfo runs from `://` to the last `@` before whitespace, `/`, `?` or `#`, even across quotes. Query values (a parameter without `=` whole) and a non-empty fragment come from each URL match, which ends at whitespace, a quote, `<` or `>`. When userinfo overlaps an assignment, both are removed together: `fetch https://alice:alpha;token=bravo@example.com/path failed` becomes `fetch https://<redacted> failed`, because the unquoted value also ran through the host. A quoted assignment inside userinfo removes the rest of the diagnostic.
  - Fidelity trade-off: harmless text after a quoted secret-named value is lost too, such as a `"model"` field or a request ID. Each retained diagnostic is redacted separately, so only that diagnostic is shortened.
  - Unquoted values end at whitespace or a delimiter. Known residual: an unquoted value that runs straight into the next key, with no whitespace or delimiter between them, can swallow that key. This includes authorization and bearer values, whose value sets also allow `&` and `=`.
  - A raw quote inside URL userinfo ends that URL match early, but the next pass reads the URL again through the userinfo placeholder and removes its query values. Known residual: if an unquoted value also ran through the `?`, later parameters are no longer query values, so `https://u:p"w@h/token:abc?q=1&r=2` keeps `r=2`.
  - Secret-named keys match only at word starts. URL scheme detection (unchanged since R3) is quadratic on dotted text, which the size bound keeps small.
  - If any redaction regex fails internally, the whole diagnostic becomes `<redacted>`. ICU's backtracking limit is one such failure, which `NSRegularExpression` would otherwise report as no match; it was measured at about 330,000 characters for the URL rule, so no diagnostic within the size bound is known to reach it.
  - Bounded persisted diagnostics are fixed points in the covered save/reload paths. Known nonblocking finding (OracleA R6-01, P2; OracleB R6-02, P3): an admitted 4,096-byte input such as 512 copies of `token=a ` expands to 8,704 bytes after placeholder replacement; re-feeding that unbounded output returns only `<redacted>`. The admission limit is not rechecked inside the pass loop. No persistence drift was demonstrated because stored messages are bounded to at most 512 bytes. No code change was made for this report-only finding.
  - The internal-regex-error and pass-exhaustion fallbacks remain defense-in-depth branches without independently triggered below-cap test coverage. The oversized fixture now tests input admission, not ICU failure. Free-form provider text still cannot be guaranteed secret-free.
- **Persisted failure fields.** A failure adds:
  - up to four `errors` entries `{index?, lane_chat_id?, code?, message}`, where entry 0 is ≤512 bytes and entries 1–3 are ≤160 bytes, `code` ≤80 and `lane_chat_id` ≤64 (the user-resolved form of plan §7.2: **no `operation_id`**);
  - `error_count`, the original count;
  - `error_truncated`;
  - `summary_text` = `Failed: <headline>` (≤160 bytes);
  - `mode`, from the result or the recognized call argument;
  - historical `lane_count`/`failed_count`/`nonterminal_count`. The card words `nonterminal_count` as "unfinished when recorded".

  `results` is never persisted. A failed lane's identity is kept in every case, under `lane_chat_id` and never a nested `chat_id`. This means:
  - the root `chat_id` stays the only candidate for `AgentOracleAuthoritativeChatIDPolicy.extract`;
  - root routing authority is unchanged;
  - `allowsLatestFallback` counts `lane_chat_id` as chat identity, so a lane-only summary never allows identity-free latest-chat fallback, matching the live envelope's nested lane `chat_id`. Its only caller (`oracleToolCallPopoverUserInfo`) reads call arguments, and only when there is no result;
  - each diagnostic's **Open lane chat** is an explicitly scoped lane route.

  Known asymmetry (pre-existing, reported as P3): a live envelope with both a root `chat_id` and nested lane `chat_id`s refuses the root, while its saved summary keeps the root and the `lane_chat_id` entries, so it routes to the root.

  Reading accepts `lane_chat_id`, or an `errors[]` entry's structured `chat_id`, and never text.
- **Size bound.** The encoded summary must fit 2,048 bytes. Content is shed in this order:
  1. diagnostics 1–3;
  2. the primary message, shortened to 256 bytes;
  3. `code`;
  4. a minimal object (status, counts, primary diagnostic and bounded `chat_id`);
  5. `minimalResultJSON` with `summary_text`.

  Re-sanitizing is a fixed point.
- **Failure classification (contract interpretation).** Failure follows the card's trusted resolution (`OracleToolCardPresentation.state`), so a non-terminal status word such as `success` that carries a non-empty `errors[]` counts as failed. This intentionally changed the existing persistence golden (`AgentToolResultPersistencePolicyTests`): such a result now keeps the redacted primary diagnostic. Results without a failure signal are byte-identical to before, and pending-only and cancelled-only results gain nothing.
- **Card.** Only failed `ask_oracle`/`oracle_send` cards expand: they use `ToolCardContainer`, start collapsed, and show the redacted headline. If nothing was retained they show "Error details unavailable". Header tap only toggles disclosure: `ToolCardContainer` wraps only the header's leading content in the toggle button and renders the trailing control instead of its default timestamp. Nothing reads `agentToolCardAutoExpandEnabled`. **Open Oracle** is a separate trailing control routed by the authoritative chat-ID policy. Diagnostic text never establishes routing; a structured `laneChatID` only opens that lane. Success, pending, queued and cancelled cards, and `chat_send`, keep the static click-to-open container. The transcript row keeps `.id(item.id)` across the container swap.
- **Lane classifiers.** The card's DTO lane state and the projection's `laneState` are pinned equivalent by `OracleToolCardInspectionTests`. `is_error` and `failed_count` are dictionary-only failure signals; they still render the failed card through the shared projection.

## Patch C — live group expansion and large groups

- **Block identity.** Production projection never emits `.activityCluster`; live groups are `.groupedHistory` blocks whose ID (`grouped-history:<turn>:<span>`) is stable across appends and re-projection. `AgentTranscriptGroupInspectionTests` gates this.
- **Expansion state.** `AgentTranscriptScrollOrchestrationState.transcriptBlockManualExpansionIDs` records explicit user choices. It is in memory only, so a reload returns every block to its default.
- **Effective expansion.** `AgentTranscriptGroupExpansionPolicy` is the single rule:
  1. no expandable content → collapsed;
  2. a manual choice → the stored value;
  3. the default-collapse target (`dynamicSummaryLockTargetTurnID`, the latest turn while the run is active and has tool activity) → collapsed;
  4. otherwise → stored or default.
- **Toggle and sync.** A toggle flips the *effective* state and records the choice. Sync prunes stale IDs and never default-follows a manual choice. Run-activation re-pin counting excludes manual choices. A manual toggle writes no outer scroll state.
- **Inner follow.** An expanded group in the default-collapse target follows its newest entry only while its inner viewport is at the bottom (6-point tolerance), and stops when the user scrolls up.
  - **Position source.** macOS 15+ reads `onScrollGeometryChange`. macOS 14 reads the scrolled content's frame in the inner scroll view's named coordinate space, plus the viewport height, through geometry-reader preferences; this is the pre-`ScrollGeometry` pattern the outer transcript's legacy path relies on. Both feed one `AgentTranscriptInnerFollowState`.
  - **Deferred scroll.** The scroll that follows an append is deferred. It runs only if it is still the latest scheduled follow and the group is still live and pinned. Scrolling up, or the run ending, cancels it.
  - **Validation.** This is verified by deterministic tests only; live checks are deferred in favor of daily use by the maintainer's 2026-10-04 decision. The [supported macOS range](../../README.md#get-started) is macOS 26.7 and newer (maintainer decision, 2026-10-04). macOS 14 live validation is not an acceptance gate. The older fallback code remains unchanged and is outside the supported range.
- **Lazy rendering.** Capped expanded groups (220/260 points; five-row threshold unchanged) render rows lazily. Grouped history is flattened by `AgentTranscriptGroupInspection.entries(for:)` into section-header and row entries with stable IDs. Offscreen inner card state can reset, which is accepted.
- **Failure suffix.** `AgentTranscriptClusterSummary.failedToolCount` is optional, omitted at zero, and stored with the collapsed summary. It is computed at the summary projection boundary by `AgentTranscriptToolFailureCount`. Each failed execution counts once. An Oracle result counts as failed when the shared projection finds a failure, and a multi-lane result counts once. Pending and cancelled work never counts; the existing `containsFailure` does include cancelled work. Headers show ` • N failed` only when N > 0.
