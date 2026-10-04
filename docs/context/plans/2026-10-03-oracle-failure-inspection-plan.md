# Implementation outcome — daily-use handoff; acceptance gaps recorded (2026-10-04)

Scope: read when the task touches the Oracle failure-inspection implementation, its redaction remediation, or acceptance and validation evidence.
Authority: Reference
Last-verified: 2026-10-04

Status: A, B and C are implemented. On 2026-10-04 the maintainer requested committing the current work and replacing the remaining live verification with daily use and issue reports. This is not a clean acceptance result. Both Oracles approved the original R6 implementation, but the later acceptance-test follow-up has an OracleA R1/P1 finding that was remediated and regression-tested without a closing re-review. The latest full suite failed. These gaps are retained below, and this plan remains active rather than declaring all acceptance gates passed.

Review history (all reviews are owned by the orchestrator):
1. OracleA and OracleB reviewed snapshot 2026-10-03/2138. A first remediation pass (R1) addressed their P0/P1/P2 findings.
2. Their fresh re-review of R1 (snapshot 2026-10-03/2232) left three findings open: ORI-01, ORI-03 together with OracleB's R1-01, and RF-B1-04. The orchestrator recorded the other findings as closed. OracleB's R1-02 and R1-03 are P3 and received no code change.
3. The second fresh re-review closed ORI-03/R1-01 and RF-B1-04 in both lanes. OracleA kept ORI-01 at P0 because an unterminated multiline quoted credential leaves later secret fragments. OracleB downgraded ORI-01 to P1 and identified a fix-induced cross-line pairing case: an earlier unmatched quote can consume the opening quote of a later bare-key secret, exposing that later value. Both lanes required stopping.
4. The user then authorized continuing. R3 remediated ORI-01 and OracleB's R2-01.
5. In the third fresh re-review, OracleB approved R3 for the reviewed remediation; its R3-01 to R3-05 are report-only P3s. OracleA kept ORI-01 at P0: a backslash escape inside one quoted value hid a nested `password="` opener, so the continuation survived (`secret='alpha \password="bravo'`, then `charlie` on the next line). R4 remediated it.
6. In the fourth fresh re-review, OracleB approved R4. OracleA closed ORI-01 but raised R4-01 at P0: because URL rewriting ran last, an unquoted assignment inside URL userinfo consumed the `@`, so `fetch https://alice:alpha;token=bravo@example.com/path failed` became `fetch https://alice:alpha;token=<redacted> failed` and kept `alice` and `alpha`. R5 remediated it.
7. In the fifth fresh re-review, both lanes closed R4-01 and every credential finding. OracleB approved R5; its R5-01 (P2) asked for exact rows for the later-pass paths and a correction to a residual claim, and R5-02 to R5-05 are report-only P3s. OracleA raised R5-01 at P1: R5 scanned the whole original text with URL scheme detection, which is quadratic on dotted text, so a long dotted quoted value that R4 removed first now stalled the projection (`password="` followed by 65,536 `a.` pairs). The user allowed one round beyond the cap. R6 remediates it.
8. In the explicitly authorized sixth fresh re-review, both lanes approved the reviewed code and closed OracleA R5-01 (P1) and OracleB R5-01 (P2). All earlier credential, routing and outcome findings remain closed. Exact preset identities were verified in both lanes. OracleA reported R6-01 (P2): placeholder expansion can produce output above the admission cap, so re-feeding unbounded redactor output is not always idempotent; no persistence/reload defect was shown. OracleB reported the same limitation as R6-02 (P3) and a P2 stale ICU-coverage tag. The tag and documentation were corrected without changing the approved production code or tests.

**Contract dispute outcome:** R2 bounded an unterminated quoted credential to its line, and the reviewers disputed that. The user chose a simple conservative policy: no uncertain recognized credential tail may survive. R3 therefore removed everything after an uncertain opening delimiter rather than bounding it to a line. R4 goes further: every quoted secret-named value removes the rest of its diagnostic, and R5 and R6 keep that. Both reviewers explicitly closed the credential findings. The draft still must not be represented as ready to ship: current full-suite and live acceptance evidence is incomplete.

Decisions taken during implementation:
- **§7.2 resolved by the user:** Position W without `operation_id`.
  - Up to four `errors` entries carrying `index` and `lane_chat_id`. The lane identity is stored under `lane_chat_id` rather than a nested `chat_id`, so it is kept beside an authoritative root `chat_id` without tripping the routing policy's nested-`chat_id` refusal (ORI-03).
  - Historical `lane_count`, `failed_count` and `nonterminal_count`; the card words the last one as "unfinished when recorded".
- **B3 contract interpretation, flagged for review.** Failure classification mirrors the card's trusted resolution (`OracleToolCardPresentation.state`), so a result whose status word is `success` but carries a non-empty `errors[]` counts as failed. Such results now keep the redacted primary diagnostic. That deliberately changes the existing `AgentToolResultPersistencePolicyTests` golden: its old "raw error text never persisted" assertion now applies only to `chat_send` and to error-free output. Output without a failure signal stays byte-identical.
- **C1/C3 premise correction.** Production projection never emits `.activityCluster`. Live groups are `.groupedHistory` blocks whose prefix grows during the run, with an ID that stays stable across appends. Inner follow therefore applies to default-collapse-target grouped history as well as to clusters (user decision 5). The C1 gate test covers grouped history.
- **Inner follow on both platforms (ORI-02, ORI-05).** macOS 15+ reads `onScrollGeometryChange`. macOS 14 reads the content frame in a named coordinate space, plus the viewport height, through geometry-reader preferences. Both feed one `AgentTranscriptInnerFollowState`, which revalidates a deferred scroll when it runs. This is verified by deterministic tests only; no live macOS 14 run was performed.
- **Failure-count suffix storage.** It is a separate optional `failedToolCount` field, because the existing `containsFailure` also counts cancelled work.
- **Redaction.** `OracleDiagnosticRedactor` is Oracle-local, because no existing repository scrubber covers URL userinfo or query values.
- **Cursor ACP (RF-B3-02).** Cursor ACP Oracle results are inspected through their wrapped `rawOutput` or `content` text. Their Cursor persistence branch keeps the same bounded, redacted failure fields; the earlier "keeps no diagnostics" limitation is remediated.
- **Review remediation, also in the routed contract.**
  - Every failed lane's additional diagnostics count toward `error_count` and `truncated` (ORI-04).
  - The card and projection lane classifiers are pinned by shared fixtures (RF-B1-06).
- **R2 remediation, also in the routed contract.**
  - **ORI-01 remained open at R2 (closed by R4).** Terminated-value rules run across line breaks before line-bounded fallbacks. R2 tests cover multiline, CRLF and Cursor ACP inputs, but the reviewers identify residual credential leaks for unterminated values and cross-assignment quote pairing. The implementation's intended line-bound is disputed and is not a safe-redaction guarantee.
  - **ORI-03 / R1-01.** `allowsLatestFallback` treats `lane_chat_id` as chat identity, so a lane-only summary no longer allows latest-chat fallback after reload. `extract` and root authority are unchanged. R1-02 (a root beside lane routes is refused live but routes after reload) predates this work and is recorded as a known asymmetry.
  - **RF-B1-04.** A failed invocation whose Oracle result was unfinished or cancelled keeps its truthful invocation `status` and adds `oracle_outcome` (`nonterminal` or `cancelled`), including on the Cursor ACP branch and in the minimal fallback. Reload reads it, so no failed card appears live or after reload. A reloaded card's subtitle still shows the invocation status, because lane `results` are never saved; this predates the work.
- **R3 remediation, also in the routed contract.**
  - **ORI-01 and OracleB R2-01.** A secret-named quoted value is removed alone only when its extent is certain. It must close with the same delimiter on the same line, hold no other secret-named quoted assignment, not end with `:` or `=`, and have a closing delimiter that does not open or close another assignment. Any other quoted value (unterminated, line-broken, escaped-closer, mismatched or cross-paired) removes the rest of the diagnostic. Redactor rows and per-layout save-and-reload fixtures cover both Oracle tools, five result shapes including Cursor ACP, LF and CRLF, and later bare-key secrets. A Python prototype of the rules was fuzzed with mixed quoted layouts and with unquoted secrets that end at whitespace or a delimiter. It found no surviving secret fragment and no output that changed when redacted again. An unquoted value glued directly to the next key still swallows that key, as before R3.
  - **Found during R3, not reviewer findings.** Secret-named keys now match only at word starts. Before, ICU took about 21 s per rule for one 8,000-character unbroken token. Regex matching also now fails closed: an ICU internal error (its backtracking limit on a very long line) used to be reported as no match, which kept the value. The R2 rules hit that limit at about 1,000,000 characters on one line, and R3's at about 100,000. Such a diagnostic now becomes `<redacted>` whole.
  - **Preflight fixtures.** The four synthetic credential-shaped fixtures that staged-index gitleaks flagged are now assembled from pieces at runtime with unchanged values and assertions. A gitleaks scan of the working copies of every index-listed file reports no findings. No scanner exemption was added.
  - **Not done.** OracleA's optional P2 oversized-`oracle_outcome` fixture was not added, because no small fixture reaches the size fallback.
- **R4 remediation, also in the routed contract.**
  - **OracleA ORI-01 (escape-hidden nested key).** R3's escape tokens consumed the first letter of a nested key, so its certainty check never saw that key, and the outer replacement then erased the key's opening delimiter. R4 stops trusting quoted extents. One rule removes everything from the first secret-named value that opens a quote, including an escaped single quote, and runs right after control-character stripping. The six R3 quoted rules and their lookaheads are gone. The orchestrator asked whether this simpler guarantee beats narrowly fixing escape consumption; R4 chose it.
  - **Explicit fidelity trade-off.** Text after a quoted secret-named value is now always removed, including text R3 kept after a value it judged certain. For example, `{\"password\": \"alpha beta\", \"model\": \"m\"}` now ends at `{\"password\": \"<redacted>\"`. This removes more, so no security contract narrows. The redactor table, the save-and-reload scenarios, and the Cursor ACP expectation were updated on purpose.
  - **Found during R4, not reviewer findings.** URL rewriting ran first. It could erase a JSON-escaped opener inside a query (`?password=\"…`), and the key of an unquoted value separated from it by whitespace (`?token: …`), leaving the value. It now runs last. An escaped single quote also did not open a value, so `password=\'alpha bravo\'` kept `alpha bravo`. Both have rows.
  - **Prototype fuzz (informal support, not acceptance evidence).** A Python prototype fuzz that adds URLs, escape-hidden keys, escaped single quotes and mixed delimiters found 66,912 leaking inputs out of 300,000 for R3 and none of the quoted kind for R4. R4's few remaining leaks are all unquoted values that run straight into the next key, including through the authorization and bearer rules. The same fuzz found 16 inputs that changed when redacted again under R3, and none under R4. A run with quoted secrets only, over three seeds and 900,000 inputs, found no leak and no change on re-redaction for R4.
  - **Fail-closed fixture.** Quoted values no longer reach ICU's backtracking limit: a 4,000,000-character quoted value matched in about 11 ms. This also removes the capacity cost in OracleB's R3-02. The fail-closed test now uses a 1,000,000-character URL; the URL rule's limit measured about 330,000 characters. The test still depends on ICU's default limit (OracleB's R3-01).
  - **Unchanged.** OracleB's R3-03 trade-off still applies: `Unexpected token: ' at line 3` loses the rest of that diagnostic. Rewriting the redactor's doc comment also resolves R3-05's line wrap. OracleA's optional oversized-`oracle_outcome` fixture is still not added.
- **R5 remediation, also in the routed contract.**
  - **OracleA R4-01 (URL userinfo erased by an assignment).** Rule order no longer matters. Every rule, including the quoted tail, now reports the ranges it would remove in the same control-stripped text, before anything is replaced. Overlapping or touching ranges merge, and each merged run becomes one `<redacted>`. URL userinfo is its own rule, from `://` to the last `@` before whitespace, `/`, `?` or `#`; it is not cut at a quote. URL query values and fragments are found in the original text too. A pass repeats until the text stops changing; if eight passes do not settle it, the whole diagnostic becomes `<redacted>`. Templates, the URL rewrite and its ordering are gone. The quoted-tail policy is unchanged.
  - **Results.** OracleA's repro becomes `fetch https://<redacted> failed`. The reversed order (`alice:token=bravo;alpha@…`) becomes `fetch https://<redacted>@example.com/path failed`. A double- or single-quoted assignment inside userinfo becomes `fetch https://<redacted>`. These have exact redactor rows, and save-and-reload scenarios for both Oracle tools and all five result shapes.
  - **Explicit trade-offs.** These remove more text, not less:
    - When an unquoted value runs through `@`, the host and path go with it.
    - Userinfo runs to the last `@` before whitespace or `/?#`, so text up to a later `@` can be removed.
    - A URL query value that covers the backslash of a JSON-escaped opener now drops the repeated delimiter. `see https://example.com/p?password=\"alpha` (with more text) ends `password=<redacted>"<redacted>` instead of R4's `…<redacted>\"`. That row and its scenario were updated on purpose.
    - Query values after an unquoted key's value are now also removed: `https://h/token=x?a=SECRET&b=2` keeps no `2`.
    - Bearer values keep their original whitespace instead of one normalized space.
  - **Prototype fuzz (informal support, not acceptance evidence).** A Python prototype was fuzzed with URLs whose userinfo, path or query holds unquoted, quoted or JSON-escaped assignments, separated by whitespace or delimiters. On two seeds of 200,000 inputs each, R4 leaked a secret in 53,910 and 54,002 inputs; R5 leaked in none, and no output changed when redacted again. The earlier quoted-only fuzzes found no leak. A standalone build of the Swift redactor produced output identical to the prototype on about 257,000 fuzz inputs. A fuzz that glues segments together still finds leaks of known kinds, as R4 did: an unquoted value running into the next key, and a URL glued to other text. (Corrected in R6, after OracleB's R5-01: a raw quote inside userinfo ends the URL match before its query, but the next pass reads the URL again through the userinfo placeholder and removes the query values. They survive only if an unquoted value also ran through the `?`.)
  - **Performance.** URL scheme detection, unchanged since R3, is quadratic on a long dotted token: about 0.74 s per pass for 16,000 characters. A diagnostic that contains a secret needs a second, confirming pass. At R5, the historical 128 KiB token test redacted in well under its then-10-second bound; R6 replaces that fixture with an admission-bounded one. The userinfo rule starts at `://`, so it adds no scheme scan, and it did not reach ICU's backtracking limit at 4,000,000 characters.
- **R6 remediation, also in the routed contract.**
  - **OracleA R5-01 (quadratic scan of a long quoted value).** `redact` now checks the diagnostic's UTF-8 length first. Above `maxScannedBytes`, 4,096 bytes, the whole diagnostic becomes `<redacted>` before normalization or any regex runs, so no unsanitized text is truncated to fit. The bound is eight times the 512-byte primary diagnostic that is persisted, so text that could still appear in a summary is scanned. A UTF-8 byte count is never smaller than the UTF-16 length that ICU scans, and normalization only removes characters. The range union, the quoted-tail policy and the regexes are unchanged.
  - **Results.** OracleA's input becomes `<redacted>` in about 42 ns in an optimized standalone build. At the bound, a dotted quoted value redacts in about 0.06 s, the slowest input found. An exact-boundary test pins 4,096 bytes: one more byte, or a two-byte character that keeps the UTF-16 length at 4,096, becomes the placeholder. OracleA's input and the old 1,000,000-character URL become the placeholder for both Oracle tools, in plain-text and structured failures, live and after reload, with no fragment persisted, a fixed-point re-persist and a 5-second bound.
  - **Updated contract tests, on purpose.** The long-token test now uses three 1,346-character tokens that fill the bound, with a 2-second limit instead of 10. Without the word-start anchor, two 1,300-character tokens took about 0.9 s per rule in ICU, so the test still catches that regression. The regex-failure test is renamed `testOversizedDiagnosticIsRedactedWholeThroughReload`: the bound now rejects its 1,000,000-character URL before ICU runs. The internal-error check remains, but no diagnostic within the bound is known to reach ICU's limit, which measured about 330,000 characters for the URL rule.
  - **Fidelity trade-off.** A provider diagnostic over 4,096 bytes, such as an HTML error page, is now only `<redacted>`, even if it holds no secret.
  - **OracleB R5-01 (P2).** Two exact rows cover paths that need a third pass: `https://o'brien:pw@h/?p=1 x` becomes `https://<redacted>@h/?p=<redacted> x`, and `https://token=a/b;c@d` becomes `https://<redacted>@d`. The context document's incorrect raw-quote residual is corrected.

Validation of R1, deterministic only:
- **Focused suites:** 107 of 107 passed across eight suites (conductor ticket `a5fe1805-f851-4b06-a6b0-2bc101934d3c`).
- **Lint:** `make dev-lint` passed (ticket `02dddf8e-6fde-488d-8753-50fe647d0834`).
- **Product builds:** `make dev-swift-build` passed for `PRODUCT=RepoPrompt` (`f2ff5aa7-cb3c-480f-a262-5faee4354134`) and `PRODUCT=repoprompt-mcp` (`5c56953f-a4a9-475d-bd39-f2281000ba4a`).
- **Full run:** `make dev-test-parallel` passed 6,322 of 6,322 tests in 591 suites (ticket `fc8fba15-bfe8-4f81-9be2-b70083e8cb71`). Six untouched suites passed only on retry.
- **Package:** the orchestrator reports that it reran the final package successfully after R1.

Validation of R2, deterministic only:
- **Focused suites:** 109 of 109 passed across the same eight suites (ticket `afa4bfa0-dcb8-4615-9990-481ad847e4bd`).
- **Lint:** `make dev-lint` passed (ticket `462c11fc-13bd-4b31-b020-fa9f1f505e71`).
- **Product builds:** `make dev-swift-build` passed for `PRODUCT=RepoPrompt` (`1ed064d6-c462-40ab-bffe-715d9f1d347f`) and `PRODUCT=repoprompt-mcp` (`dcac8d7a-3cde-48e7-90d4-eaf6f7b4dddf`).
- **Full run (one attempt, not repeated):** `make dev-test-parallel` executed 6,324 of 6,324 tests in 591 suites with no failures. Eight suites outside the R2 delta passed only on retry. Conductor still rejected the run (ticket `89154318-50ed-4260-8356-9bff904db86b`, exit 67) because its source/artifact integrity check found a changed dirty digest. The only file changed during the run was this Markdown preface; no Swift source or test changed after the product builds. The run is therefore **not** a clean conductor pass.
- **Ledger:** `verify-ledger` reports no stale rows and one missing row, which predates this work (`AgentDelegationPolicyTests.testPairReviewRemediationGuidanceMatchesDelegationAudienceAcrossProviders`).
- **Context check:** `Scripts/check-agent-context` reports six errors, which also predate this work: links to untracked `prompt-exports/` files in the shim-auth plan.

The user accepted deferring three pre-existing items: the six broken links, the one missing ledger row, and an unexplained OMP failure.

After R2, the staged-index preflight's gitleaks step reported four matches in synthetic redaction fixtures in `OracleToolResultInspectionTests.swift`; R3 resolves them, as described above. Raw Oracle exports and review-delta artifacts remain unstaged. No commit was created.

Validation of R3, deterministic only:
- **Passed:** focused suites 111 of 111 (ticket `a99e6e9c-af20-4d6f-b5d9-1fb0dc313a35`), `make dev-lint` (`7bffd7f2-9731-4965-9056-d86338fce3a7`), both product builds (`74136247-6e32-4697-9c80-8343d94f61a7`, `11d9ccc4-6cdb-4b50-8253-3327215e3c7b`), and the package build without launch (`ab0cec4e-72ba-45ac-b978-40fb88c5efd2`).
- **Failed:** the frozen full run (`147ed6e6-003d-4801-b3d7-01e390e9a48a`, exit 1). It executed 6,326 of 6,326 tests, and `AgentModeRunServiceLifecycleTests` failed on both attempts. The runner labels nonzero XCTest exits `CRASH`; that label alone does not establish a process crash. A focused rerun of that suite (`4aa72cbd-2c39-4aa9-9747-85c60bf66e80`) failed 1 of 116: `testACPDelegatedQuestionStageIsAcknowledgedAtThePromptWriteNotAtTurnCompletion` timed out on its 0.5 s wait. That test file is unchanged, and it failed once then passed in the R2 full run, but independence from A/B/C is **not proven**. This failure is not a pass and is outside the user's deferrals.

Validation of R4, deterministic only:
- **Passed:** focused suites 111 of 111 (ticket `b5b14b18-3078-4034-a302-91d8e6ca2007`), `make dev-lint` (`adfe3999-0717-4c4a-a697-dba45bb64b43`), both product builds (`71c1d8b4-1710-4700-8c2e-921e4db7efad`, `fc585912-19ef-4159-b5e4-7b168b0b0f1e`), and the package build without launch (`d9f9fc55-a6a3-4365-95ff-05d81254a5b9`).
- **Full run:** the frozen full run (`3aa8b2d0-fb1e-4d88-915c-1e2da51c8479`) exited 0 with 6,326 of 6,326 tests in 591 suites and no final failures, and the tree digest was unchanged. Five suites passed only on retry: `AgentModeRunServiceLifecycleTests`, `AgentRunMCPToolServiceWaitTests`, `GitWorktreeCreationReceiptTests`, `MCPCodeStructureWorktreeTests` and `OMPAgentModeSmokeScriptTests`. On its first attempt, the lifecycle suite returned a nonzero exit with four failed assertions. `testACPDelegatedQuestionStageIsAcknowledgedAtThePromptWriteNotAtTurnCompletion` failed after 5.641 s, and `testPreDeniedOhMyPiReceiptPreventsBootstrapAfterGateAuthorization` also failed. A passing retry is not evidence that the timeout's cause is fixed or that it is independent of A/B/C; this remains a caveat.

Validation of R5, deterministic only (frozen tree digest `fa6ec8de9cf916cf`, unchanged through every run):
- **Passed:** focused suites 111 of 111 (ticket `4ddecac1-e5ff-42fa-8e31-f912d29b8321`), `make dev-lint` (`79550219-76f7-46ef-b82c-57b7ed5a0c52`), both product builds (`19643bac-a776-455d-9b7b-4d8ed5c5541d`, `2df1ef38-7a27-43df-ab8f-cfb4f602c482`), and the package build without launch (`948053fb-2fdb-41f7-b4fe-860a2979c80e`).
- **Failed:** the frozen full run (`e4ea7788-22fd-4327-9f81-5a236c3e21f9`, exit 1). It executed 6,326 of 6,326 tests in 591 suites with three final failures, all in `AgentModeRunServiceLifecycleTests`, which failed on both attempts. On attempt 1, `testACPDelegatedQuestionStageIsAcknowledgedAtThePromptWriteNotAtTurnCompletion` timed out on its 0.5 s wait. On attempt 2, `testPreDeniedOhMyPiReceiptPreventsBootstrapAfterGateAuthorization` failed three cleanup-count assertions (lines 842–844, expected 1, got 0). Six other suites passed only on retry: `AgentRunMCPToolServiceWaitTests`, `CodemapAutomaticSelectionBusyTests`, `GitWorkspaceStateAuthorityTests`, `GitWorktreeCreationReceiptTests`, `OMPAgentModeSmokeScriptTests` and `RemoteAgentSessionTests`. The lifecycle test file is unchanged at HEAD, and the same two tests failed R4's first attempt; independence from A/B/C is still **not proven**. This run is not a pass, and the run was not repeated.

Validation of R6, deterministic only (frozen tree digest `556d71e7ba92f2b8`):
- **Passed:** focused suites 112 of 112 (`30c76459-f019-426b-9a67-f1b28fe8b4e3`), lint (`adcc17c1-5e69-4a7e-8366-6ac544a71470`), RepoPrompt (`d0a6e04b-c5ae-4867-b08f-36d21659a09b`), repoprompt-mcp (`ab738af7-b44e-4e86-87f1-58e799abec23`), and debug packaging without launch (`4f40d98c-3aee-410a-80eb-06a7eacb3b0c`).
- **Failed:** current full run `4b4ee20a-d5ae-4b61-af31-ccee7d880d1f`, exit 1. All 6,327 tests in 591 suites executed; three final failures remained after seven retries. `AgentModeRunServiceLifecycleTests` failed both attempts on the ACP prompt-write acknowledgement timeout, with the not-sent-before-write timeout also failing on the second attempt. `AgentRunMCPToolServiceWaitTests.testOMPQualificationAuthorizationUsesSingleAbsoluteDeadline` failed both attempts (`nil` versus `.denied`). Five other suites passed on retry. Both files are unchanged at HEAD, but causal independence from the full A/B/C patch is unproven. The earlier OMP deferral is not a clean pass and does not waive the newly recurring lifecycle failures.
- **Context checker regression tests:** 23 passed, zero skipped or failed (`Scripts/test-check-agent-context`).
- **Post-review bookkeeping:** only documentation and ledger coverage wording changed after the reviewed/tested snapshot. Production code and tests are unchanged. The oversized test establishes size admission; ICU-internal-error and pass-exhaustion defenses lack independently triggered below-cap coverage. Direct unbounded redactor idempotence has the nonblocking replacement-expansion limitation recorded in the owning context document.
- **Staging/preflight:** the final index is intended to contain only the 30 implementation, test, ledger, guardrail and context files; raw `prompt-exports/` evidence remains excluded. Actual staged-index preflight is rerun after final staging; its result is reported in the final handoff. Historical R4 success is not substituted for current R6 full-run failure.

## Daily-use handoff decision and latest evidence (2026-10-04)

The maintainer explicitly requested a local commit instead of further live verification, intending to use the newly built app daily and report issues. Remaining live UI and exact request-capture checks are therefore deferred by maintainer decision, not reported as passes. No additional review or test campaign is started for this handoff; no push is authorized.

- **Running app:** the user manually launched the packaged debug app. Process inspection confirmed the intended bundle and executable hash. Scoped CLI smoke passed (`64af4f7a-80ee-4d51-9683-ccf252d6233e`). Fresh `review` sends with both `none` and `explicit_slices` succeeded with exact preset IDs; omitted-model requests returned the expected self-correcting pre-provider rejection. Exact immutable request contents were not captured. Computer-use tools were unavailable, so live card/reload/group-scrolling checks were not performed.
- **Watchdog remediation:** the regression now parks post-cancellation work behind existing test fences. Reintroducing the orphaning watchdog failed the regression with two assertions (`29e0ec65-83c8-488e-89ba-9558bbd09d1b`); the mutation was restored and hashes verified. No production code changed after packaging. OracleA R1/P1 remains formally open because the maintainer's commit request ends this verification pass before fresh re-review; original R6 approvals must not be represented as approval of this later delta.
- **Final focused validation:** 54 wait tests (`08c103af-c3cc-4fe9-a390-be7a578a0fc2`), 3 ListAgents tests (`02aa8030-e8e7-4470-b7cc-52cbf170ccdc`), 28 smoke-gate tests (`04a9af35-b503-4d46-83ad-c6714a5e3c37`), and 116 lifecycle tests (`94b62885-3cce-4084-8c8c-7a4f450d8405`) passed. Lint (`e3bffc22-4990-4289-8832-f0bb41e26bb9`) and format check (`3963a35f-eaee-4355-8a05-3c52f0c913b0`) passed.
- **Latest full run failed:** `03f6e71b-85c4-4d9b-a8cb-e9476bc2ec48` executed 6,329 tests in 591 suites. Both lifecycle attempts failed three assertions in unchanged `testPreDeniedOhMyPiReceiptPreventsBootstrapAfterGateAuthorization` (cleanup counts and entries at lines 842–844). The same assertion values occur in an earlier log, but independence from the complete implementation is not established. The changed ACP tests and wait suite passed. Code-structure and OMP smoke-script suites passed only on retry.
- **Integrity caveat:** conductor exited 67 for a source-dirty-digest change in addition to the test failure. All five recorded code/test/ledger hashes remained unchanged. A generated agent-result export appeared during the run and is a possible explanation, not a proven cause. This run is not valid clean full-suite evidence.
- **Other known gaps:** exact-ID ledger verification still reports the previously deferred missing delegation-test row and no stale rows; the six previously deferred shim-auth documentation links remain broken. Raw review/agent exports remain local and are excluded from the commit.

The earlier checkpoint below is historical; its pause instructions and unwaived-live-check wording do not override this daily-use decision.

## Acceptance follow-up and pause checkpoint (2026-10-04)

The user requested pausing verification, packaging the current debug app for manual opening, and waiting for a signal before resuming checks. No agent app launch, relaunch, or stop was performed. The original 30-file R6 draft remains staged; the acceptance follow-up and support-policy edits are unstaged. No commit was created.

Packaging completed successfully with `make dev-build`, ticket `c1e743a7-a982-4535-85ce-033745675bf2` (2026-10-04 17:20:59 +0700). The actual bundle is `/Users/tnguyen/Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app`; the worktree's `.build/debug/RepoPrompt.app` is the compatibility path. Packaging passed signature, architecture, helper-layout and embedded-helper smoke checks; it did not launch the app. Auto-detected debug signing selected ephemeral in-memory secure storage, so credentials may need re-entry after restart. This is a development verification candidate, not accepted/re-reviewed remediation. No new tests or Oracle reviews were started after the pause request.

### Baseline and fixes
- A clean detached worktree at `a11b77eeda868a5014b0fc74a92d2ec5a60ed74d`, `../rpce-baseline-a11b77e`, reproduced both original failures without the Oracle patch: lifecycle 116 tests/1 failure (ticket `507e8634-77f7-4e8c-8908-f6e31dcd7cde`), wait suite 52/1 (`e1d97a16-d7ba-44f6-b3a7-f8ed1ab1fc32`). It remains intact and clean.
- ACP acknowledgement now observes the existing event with a cancellation-cooperative five-second hang safeguard and cancels the run on failure; real environment startup and the acknowledgement-before-completion assertions remain.
- OMP qualification uses a per-service DEBUG monotonic clock, snapshotted once per start and forwarded to the existing receipt. Default runtime behavior remains real uptime. The single-deadline test drives clock boundaries deterministically, and a separate test checks remaining-budget arithmetic.
- Initial follow-up validation passed 53 wait tests (`0a9bfc84-ec7e-46b9-993a-be7f8af6a15d`), 116 lifecycle tests (`4e771877-e7d0-4ceb-ba00-78b3e5b7bbed`), 28 receipt/gate tests (`a12593c0-a6b4-455c-b279-154328bd4c5e`), and 17 current-artifact single-test reruns. Lint `fb9df059-6546-4cf8-8234-676d5dd740c7` and format check `e0769dee-e598-434b-a331-7c9992a8971a` passed for that revision.
- The frozen full run `9b905074-d119-48e3-865b-d8177b6d28ba` executed 6,328/6,328 tests in 591 suites and **failed** with one final failure. The follow-up ledger edit had removed a shared-state tag still read indirectly by the rewritten test; `AgentManageMCPToolServiceListAgentsTests.testQualificationLedgerKeepsSharedGateIsolationContract` caught it. The tag is restored. Both ACP tests passed on both full-run attempts; a different, pre-existing lease-cleanup race caused the lifecycle suite's first-attempt failure. Lifecycle, Git worktree receipt, and OMP smoke-script suites passed only on retry.

### Review and remediation state
- Fresh review of snapshot `2026-10-04/1652-3`: OracleA withheld approval on **R1/P1**, because the watchdog cancelled without draining the operation before test teardown. OracleB approved code with nonblocking findings. Preset identities were verified: OracleA `61D024A4-CCFB-4C9C-A614-CC65E0A1864C`, OracleB `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C`.
- Review exports remain local under `prompt-exports/`: `oracle-review-2026-10-04-170036-oraclea-acceptance-s-0321.md` and `oracle-review-2026-10-04-170526-oracleb-acceptance-s-ffbb.md`.
- Remediation replaces the orphaning watchdog with a structured task group that cancels and drains before returning. A cancellation/drain ordering regression test and ledger row were added. A nil-default DEBUG rollback-entry hook verifies the receipt is already denied before cleanup; the existing terminal-category callback runs too late for that assertion. The test also counts pre-dispatch-hook invocation, and the tautological clock assertion was removed.
- Remediation validation before temporary negative mutations: 54 wait tests passed (`aec99466-034a-4bdd-a635-8f71ae214441`), including the watchdog-drain test; all 3 ListAgents tests passed (`ba8f4d7c-f00d-4ca6-9706-f25af14a61c5`). Negative-mutation run `9fc7706e-9ab7-4cab-a91f-e836c90c7689` executed two tests with two assertion failures in the single-deadline test: missing pre-dispatch-hook invocation and missing denial at rollback entry. The watchdog test did not fail with the orphaning mutation, so its discriminating strength remains unproven and must be addressed or reported during re-review.
- The worker was cancelled during the pause handoff after restoring production mutations but before restoring the watchdog mutation. The orchestrator restored the last test mutation. Both files exactly match their recorded pre-mutation SHA-256: service `2487c6b2c7a3c5ee88ec6b4a22eefbc4f75c730012ec9be46103c13e66136217`; wait tests `ac1c3ebe858e490730a78d8d61b4b73a7bffc37eed60a49866dce85aefdafbb8`. No conductor job was running at the restoration checkpoint.
- **R1 remains open until fresh re-review explicitly closes or downgrades it.** No re-review of the remediation has occurred. Original R6 approval does not cover this follow-up.
- Nonblocking follow-ups: pending-authorization wait-branch coverage (OracleA R2); exact-deadline service admission and related ledger precision (OracleB R7-04); cold-ACP timing concern (R7-02) remains nonblocking because both ACP tests passed under full-run load. Do not silently expand these into another implementation campaign.

### Resume after the user's signal
1. Confirm the manually opened app is the intended packaged artifact; do not assume opening a path replaced the existing running process.
2. Recover worker `A053D1A8-835C-4EFC-92F0-380402B40D8C` logs if needed, but do not use workers for code review.
3. Finish affected validation on restored source, including lint/format (the remediation's last recorded lint ticket `fa24a49a-618f-4a72-a127-5af0fe7b8922` failed), ledger/list checks and a frozen full run. Do not edit during source-validating jobs.
4. Run fresh OracleA/OracleB review lanes scoped to their prior findings verbatim, the delta from `2026-10-04/1652-3`, and new evidence. No reviewer substitutes; R1/P1 requires explicit closure.
5. Run live A/B/C on a supported OS, then update this record, stage only intended files, and rerun contribution preflight. The six broken links and one missing pre-existing ledger row remain deferred, not passes. No commit without a new request.

Not run: live checks A, B and C. These remain required on a supported OS.

Support-policy update (maintainer decision, 2026-10-04): support is limited to the current host OS, verified by `sw_vers` as macOS 26.7, and newer; see the [README support policy](../../../README.md#get-started). macOS 14 live validation is no longer required for acceptance. This is a documentation/support-policy change only; deployment settings and compatibility fallback code remain unchanged.

Durable contracts live in [Oracle failure inspection](../oracle-failure-inspection.md). The original plan is preserved verbatim below, including its historical status and relative links.

---

# Oracle fresh-chat contract, failed-Oracle diagnosability, and live group expansion plan

Scope: read when the task touches `ask_oracle` fresh-chat `selection_mode`/`slices` validation, the omitted-`model` rejection and its guidance, persisted Oracle failure summaries, the failed Oracle tool card, or expansion/rendering of activity-cluster and grouped-history blocks during an active run.
Authority: Reference
Last-verified: 2026-10-03

Status: Planned, not implemented. No source has changed for this plan. One material disagreement (§7.2, multi-lane failure persistence) remains open after two challenge rounds; its recommendation is recorded but not silently adopted.

Decision process: two independent Oracle lanes (OracleE `95F2BD07-4A94-417C-AAAF-17CAB847EC35` and OracleD `7F177418-1980-4BF5-9768-B278FBC7C2BB`, both `model_selection: explicit` on the first round and `inherited` on continuations) received an identical brief with file:line evidence that had been verified against the live checkout. Three material disagreements went to anonymous reciprocal challenge (arguments relayed, never lane identity). One converged after round 1 (§7.1). One was decided by the user after round 1, because the lanes swapped positions (§7.3). One survived both rounds with the lanes swapping positions each round (§7.2). Minor points were settled by the plan author after checking the code (§7.4).

User decisions (2026-10-03):
1. Fresh chats (`new_chat:true`) accept both `selection_mode:"none"` and `"explicit_slices"`.
2. An omitted `model` with several qualifying presets keeps being rejected (no silent model choice), but guidance is fixed and the error becomes self-correcting.
3. Grouped tool calls during an active run are collapsed by default; an explicit user click expands a group and it stays expanded as new calls arrive, until the user collapses it.
4. Only **failed** Oracle cards become expandable; successful and pending Oracle cards keep today's click-to-open-chat behavior.
5. The inner list of a manually expanded live group follows the newest call only while the user is at its inner bottom, and stops following if they scroll up inside it.
6. The Oracle contract change and the transcript-inspection changes ship as separate patches.

## 1. Problem and verified evidence

The user frequently sees cards reading only "Oracle • Failed", with no subtitle and no way to expand them. A typical turn: Oracle Failed → Oracle Failed (sometimes with selection get/clear/add in between) → Oracle Utils → a successful plan call carrying an exact preset UUID. Separately, groups such as "Explored & edited (142)" often cannot be expanded.

Line references identify the checkout inspected on 2026-10-03.

| # | Boundary | Evidence and consequence |
|---|---|---|
| E1 | Fresh-chat `selection_mode` rejection | `MCPOracleToolService.swift:2015–2019` throws `selection_mode is only valid for continuation sends with an explicit chat_id` when `new_chat:true` and mode is not `current`; `:2020–2024` rejects `none`/`explicit_slices` whenever `chat_id` is missing. `parseSelectionMode` is the first validation in `prepareAskOracleSend` (`:1708`), before tab resolution, packaging, or provider start. Introduced 2026-08-05 by `abcaf01f` (blame unchanged since); no recorded rationale. Pinned by `MCPAskOracleWorktreeTests.swift:3419–3427`. Real occurrences: OracleA and OracleB fresh re-review lanes were both rejected with this message on 2026-10-03 at 03:55 UTC (session `74F37B98-…`), and the same failure is recorded on 2026-09-22 in the resumable-wait plan §13. Both were fresh-lane re-reviews that wanted context the orchestrator controlled. |
| E2 | Packaging already supports per-send modes | `OracleViewModel+MCP.swift:156–191` `applying(selectionMode:)` replaces the selection with an empty or explicit `StoredSelection` and sets `reviewGitContext: .automaticOnly()` and `gitInclusionOverride: .none`. Nothing depends on chat newness. Explicit slices resolve after tab context exists (`MCPOracleToolService.swift:1797–1809`). The restriction is validation-only. |
| E3 | Fresh-chat model rejection | `validateNewChatModelSelection` (`MCPOracleToolService.swift:2093–2132`, called at `:1714`) rejects `new_chat:true` without `model` when more than one configured preset supports the mode, listing names and UUIDs and telling the agent to consult `oracle_utils op=models`. Introduced 2026-07-29 by `e6b6802d`. `oracle_utils op=models` on 2026-10-03 lists five presets (OracleA–E), all supporting chat/plan/review, so every fresh chat without `model` fails. The fail → Oracle Utils → UUID success sequence matches this error; the exact error text of those calls is not recoverable (E5), so attribution is inference. |
| E4 | Guidance traps | The tool description (`MCPOracleToolProvider.swift:69`) says "Prune selection, use `selection_mode:none`, or continue a long lane in a fresh chat with a concise summary" while the parameter says "Continuation-only" (`:124–125`). The independent-review guidance (`SystemPromptService.swift:795`, sentence since `d2f8f504` on 2026-07-24) says "use `ask_oracle` with mode:\"review\" in a fresh chat" without saying `model` is required; only the named-Oracle fragment (`AgentModePrompts.swift:275–281`) requires an explicit model. The overflow remedy (`ChatToolError.swift:100`) correctly scopes `selection_mode:none` to "the continuation". Batch `consultations` lanes reject `selection_mode` before admission (resumable-wait plan §13). |
| E5 | Saved transcripts drop Oracle error text | `oracleChatSummaryJSON` (`AgentToolResultPersistencePolicy.swift:2368–2430`) keeps chat ID, mode, preset, model selection, `has_response`, `error_count`, and `summary_text`, but no error message or code. A plain-text error has no JSON object, so only the generic object survives. `persistedToolResultSummary` keeps that structured summary for Oracle tools (`:384–389`). Session-history search for these failures finds only assistant prose. |
| E6 | Error framing on the wire | `ask_oracle` validation throws `MCPError.invalidParams`, which reaches agents as a JSON-RPC `-32602 Invalid params: …` error. `ChatToolError` does not conform to `MCPStructuredToolError`; `MCPConnectionManager.toolErrorResult(rawJSON:error:)` (`:1276–1285`) serializes code and message only for that protocol, otherwise `"Error: \(error)"`. Structured `details` therefore cannot be assumed to reach the agent. |
| E7 | The Oracle card is not expandable | `ChatSendResultCard` (`ToolResultCommunicationCards.swift:368–450`) uses `StaticToolCardContainer` (`ToolCardContainer.swift:321+`, no expansion state). Its only action opens an Oracle chat popover, and only when a chat ID resolves (`:418–427`). For a pre-chat failure there is no chat ID, so no action; a plain-text error fails `ChatSendDTO` decoding, so the subtitle is empty (inference from code). `OracleToolCardPresentation.state` reports `.failed` when any lane failed (`:170–171`), and a present-but-empty `results` falls back to a fabricated single lane (`:165`). |
| E8 | Groups locked during active runs | `AgentModeViewModel.swift:9662–9673` makes the latest turn the `dynamicSummaryLockTargetTurnID` while the run is active and the turn has tool activity. `AgentModeView.swift:1678–1681` treats every `.activityCluster`/`.groupedHistory` block in that turn as a lock target, and `:2808–2823` and `:2858–2873` render a plain label instead of the expand button. Present since the initial snapshot (`351e9803`, 2026-05-31). Its likely purpose (inference) is pinned live-bottom stability: `:2219–2243` counts expanded dynamic blocks when a run becomes active and re-pins (DEBUG stress note "Run-active summary collapse"). |
| E9 | Expansion state is seeded, in-memory | `syncTranscriptBlockExpansion(for:)` (`AgentModeView.swift:3479–3506`) seeds every expandable block with its default and overwrites a stored value on a default flip only if it still equals the previous default. A stored entry therefore does not mean the user chose it. State lives in `AgentTranscriptScrollOrchestrationState` (`Views/Transcript/AgentTranscriptScrollOrchestrationState.swift:20–21`) and is not saved with transcripts. |
| E10 | Large groups render eagerly | Expanded content is a `VStack` + `ForEach` (`AgentModeView.swift:3247–3265`) inside a `ScrollView` capped at 220/260 pt (`:2828–2835`). A 142-row group builds every row. Tool-card auto-expand is disabled for lock targets, archived blocks, and non-`.full` retention tiers (`:3058–3075`). |
| E11 | Dead card | `CompressedToolGroupCard.swift` is non-expandable but has no call sites in `Sources`. |

## 2. Goals and non-goals

Goals:
- A fresh single Oracle send can control its context (`none` or `explicit_slices`) without mutating the shared workspace selection.
- An omitted model still fails under the existing multi-preset rule, and the error alone is enough to retry correctly.
- Every guidance surface agrees with the contract.
- A failed Oracle card explains itself, both live and after transcript reload.
- An explicit group expansion survives incoming calls and run completion; large expanded groups build rows lazily.

Non-goals: batch `consultations` support for `selection_mode`/`slices`; a virtual git-diff addressing scheme for slices; automatic model substitution; changes to Oracle scheduling, cancellation, or operation persistence; generalized failure persistence for every tool; persisting progress hints, elapsed time, or stream state; saving block expansion state across reloads; deleting `CompressedToolGroupCard` (separate cleanup).

## 3. Patch split and order

| Patch | Contents | Shipping rule |
|---|---|---|
| **A — Oracle single-send contract and guidance** | `parseSelectionMode` rule, self-correcting model error, tool/schema/Knowledge/system-prompt guidance, overflow remedy wording, deliberate test changes, catalog golden hashes. | Independently shippable; lands atomically with its goldens. Recommended first: it removes the cause of the reported failures. |
| **B — Failed Oracle card diagnosability** | Shared pure Oracle failure projection, failure persistence, redaction, failed-card expansion. | Independently shippable; must handle error text from either version of Patch A. |
| **C — Live group expansion and large-group rendering** | Explicit-choice provenance, lock becomes default-collapse, bottom-sticky inner follow, lazy rendering, failure-count suffix. | Independently shippable. |

## 4. Patch A — Oracle single-send contract

### A1. Selection-mode targeting (`MCPOracleToolService.parseSelectionMode`)

New invariant: a non-`current` `selection_mode` requires an **explicit conversation target**, either `chat_id` (continuation) or `new_chat:true` (fresh chat). Implicit "latest chat in this tab" sends keep rejecting non-`current` modes.

| Targeting | `current` | `none` | `explicit_slices` |
|---|---|---|---|
| `new_chat:true`, no `chat_id` | accepted | **accepted** | **accepted with valid, non-empty slices** |
| explicit `chat_id`, `new_chat` false or omitted | accepted | accepted | accepted with valid, non-empty slices |
| neither | existing behavior | rejected | rejected |
| `new_chat:true` plus `chat_id` | rejected by existing common validation | rejected | rejected |
| `consultations` envelope or lane | existing batch contract | unsupported, rejected before admission | unsupported, rejected before admission |

Replace both guards with one. New message: `selection_mode:<mode> requires an explicit conversation target: pass chat_id to continue a chat or new_chat:true to start one`. Keep all other validation: string types, enum values, non-empty slices, rejecting unused `slices`, conflicting `new_chat`/`chat_id`, model and output-token validation. Invalid input still fails before provider start.

Packaging is unchanged (E2). On a fresh chat, as on a continuation: `none` sends no workspace selection and no automatic or frozen review diff; `explicit_slices` sends only the resolved slices and no automatic diff; `current` is unchanged. A diff artifact may be sliced only if it is an ordinary readable text file that the existing slice resolver accepts; otherwise diff text belongs in `message`.

Before merge, verify two things: no second continuation-only guard exists downstream (search `selection_mode` and `OracleSelectionMode` in `Features/Chat/ViewModels/Oracle/*`), and fresh `review` with `none` is not rejected downstream as empty review context.

### A2. Self-correcting model error (`validateNewChatModelSelection`)

Keep the signature, settings gates, ambiguity predicate (configured, mode-compatible presets; no availability filtering), sorting, and the `MCPError.invalidParams` type. The message gains:
- the stable prefix `oracle_model_required:` (matches the `oracle_*` code family in `ChatToolErrorCode`);
- the requested mode and number of compatible configured presets;
- a statement that this is a pre-provider validation failure;
- "Retry the same call with `model` set to exactly one of these preset UUIDs", followed by every compatible preset's escaped name and UUID in the current deterministic order;
- "This list is current; no `oracle_utils` call is needed";
- the existing `chat_name` display-only sentence.

Keep the substrings the existing test asserts ("requires an explicit model", "chat_name only labels", every name and UUID). Listed presets are *configured*; a listed preset can still fail later with an explicit availability error (known limitation, follow-up candidate).

### A3. Guidance surfaces (each is a golden-hash change)

| Surface | Change |
|---|---|
| `MCPOracleToolProvider.askOracleTool()` paragraph at `:69` | `selection_mode` controls this send's packaging on any send with an explicit target (`chat_id` or `new_chat:true`). In `review` mode, `none` and `explicit_slices` omit the automatic diff, so put diff text in `message` or slice the changed files. `consultations` lanes always package `current`. Keep the wait, cancel, request-ID, capacity, batch, and preset-inheritance text unchanged. |
| `selection_mode` parameter (`:124–125`) | Drop "Continuation-only"; state the explicit-target rule; mark single-send-only. |
| `new_chat` / `model` parameters (`:113–121`) | A fresh chat needs an explicit `model` when more than one preset supports the mode; the rejection lists the exact UUIDs to retry with. |
| `AgentModeMCPToolPolicy.knowledgeAskOracleDescription` | The same fresh-chat model sentence. |
| `AgentModePrompts.Fragments` | Add one shared `oracleFreshChatGuidance` fragment: fresh lanes carry an explicit preset; reuse an exact UUID already known, including one listed by the rejection; use `oracle_utils` only when identity is missing, ambiguous, or stale; `chat_name` never selects a model; controlled-context fresh reviews may use `none` or `explicit_slices` and receive no automatic diff. Update `namedOracleConsultationGuidance` so it does not demand another discovery call when exact identity is already known; keep its identity-verification safeguards. |
| `SystemPromptService.swift:795` | Include the shared fragment next to the fresh independent-review sentence, and say "fresh chat (`new_chat:true` plus an explicit `model`)". |
| `ChatToolError.oracleContextOverflow` remedy (`:100`) | "retry with `selection_mode:none` or `explicit_slices` on the same `chat_id` or a fresh chat". Budget fields unchanged. |

No input-schema parameters are added. Old clients see strictly fewer rejections. An older server still rejects the newly allowed combinations; clients must not silently fall back to `current` after a rejection.

### A4. Patch A tests

- `MCPAskOracleWorktreeTests`, a deliberate contract update: remove the `none + new_chat:true → "only valid for continuation sends"` case (`:3423–3427`); change the two `requires an explicit chat_id` expectations (`:3419–3420`) to the new explicit-target text. Add fresh-chat `none` and `explicit_slices` cases with an explicit model in `review` mode: empty or explicit selection, `gitInclusionOverride == .none`, automatic-only review context, shared selection revision unchanged, invalid slice path rejected before provider start, `current` unchanged. Extend the model-error test with the prefix, the no-`oracle_utils` sentence, and a direct retry using a UUID from the error.
- `ToolCatalogSnapshotTests`: update only the hashes of the edited descriptions (standard and Knowledge).
- A new prompt-guidance test (e.g. `OracleFreshChatGuidanceTests`) rendering the prompt families that recommend fresh Oracle chats.
- Add surgical ledger rows for new tests.

## 5. Patch B — Failed Oracle card diagnosability

### B1. One shared pure projection

Add `Sources/RepoPrompt/Features/AgentMode/Runtime/Transcript/OracleToolResultInspection.swift`. It contains immutable values plus synchronous, non-throwing helpers used by both persistence and the card, so live and reloaded cards cannot diverge. It holds no sessions, view models, operation-store references, or caches.

Diagnostic selection is deterministic: take the first failure diagnostic in source order. In priority:
1. a structured `errors[]` entry with a non-empty message;
2. for a lane envelope, the lowest-index failed lane's error;
3. top-level `error` (string or `{code,message}`), including the `is_error`/`code`/`error` shapes emitted by `MCPConnectionManager.toolErrorResult`;
4. raw non-JSON text, only when trusted status (`toolIsError` or the normalized execution status) establishes failure.

Never take index 0 blindly. Never derive `code` from free text (agents see provider-wrapped text such as `MCP error -32602: Invalid params: oracle_model_required: …`). Successful response text must never become an error because DTO decoding failed.

### B2. Redaction

Reuse an existing repository scrubber if one provides these behaviors (search `Infrastructure/Security` and raw-event logging first); otherwise add a minimal Oracle-local scrubber with its own unit tests. Required behaviors: remove bearer/authorization values and recognized API-key, password, secret, and token assignments; remove URL userinfo and query/fragment values; strip control characters; exclude attached bodies, header dictionaries, stacks, and arbitrary nested error objects. **Redact the full text first, then truncate** at a UTF-8 boundary, so truncation cannot split a token the scrubber would miss. Free-form provider text cannot be guaranteed secret-free; the real protections are field allowlisting, recognized-credential removal, and bounded retention.

### B3. Persisted fields (agreed base contract)

Added only when the result is a failure; successful output stays byte-identical to today, and pending-only or cancelled-only results gain nothing.

| Field | Contract |
|---|---|
| `errors[0]` | `{ "code"?: structured source code only, ≤80 UTF-8 bytes (omit rather than truncate), "message": redacted, ≤512 UTF-8 bytes }` |
| `error_count` | original diagnostic count, ≥1, computed before truncation |
| `error_truncated` | present (true) only when text, a code, or additional diagnostics were omitted |
| `summary_text` | `Failed: ` plus the first line of the same redacted diagnostic, ≤160 bytes; survives the minimal fallback |
| `mode` | existing result value, else a recognized mode from the actual arguments; copy no other arguments |
| existing keys | `chat_id`, preset fields, `model_selection`, `has_response`, tool and status are untouched (`chat_id` powers Open Oracle after reload) |

Budget: 2,048 bytes for the **encoded** Oracle summary, applied before the existing delegated-question-notice layer. The shedding order is: shorten the message to 256 bytes, then drop `code`, then fall back to the existing `minimalResultJSON` with `summary_text`. `persistedToolResultSummary` must use this bounded projection rather than rejecting an oversized candidate and falling through to a status-only object. Re-sanitization is a fixed point (`f(f(x)) == f(x)`): it preserves existing `error_count` and `error_truncated` and never recounts a stored subset. Omit `results` from the diagnostic summary instead of persisting `[]`, because the card's DTO fallback fabricates a lane (E7).

The multi-lane extension (more than one entry, lane identity, aggregate counts) is the open disagreement in §7.2.

### B4. Failed-card UI (`ChatSendResultCard`)

- Decide whether the result failed using the existing trusted resolution: `toolIsError`, the normalized status, or `OracleToolCardPresentation.state == .failed`, which includes any failed lane. A plain-text failure must not require a successful DTO decode.
- **Failed only:** render in `ToolCardContainer` with card-local expansion state, initially collapsed regardless of `agentToolCardAutoExpandEnabled`. The collapsed subtitle is the redacted headline. Expanded content shows the code (if any), the full retained message as selectable monospace text, and "(message truncated when saved)" when truncated. Legacy results with nothing retained say **"Error details unavailable"** and explain on expansion that the saved transcript did not keep them; do not reconstruct details from nearby assistant prose.
- If authoritative routing yields a chat ID (`AgentOracleToolRouting`, `AgentOracleAuthoritativeChatIDPolicy`), show a separate **Open Oracle** trailing control with its own hit target and accessibility action. Header tap toggles disclosure only. Diagnostic parsing never establishes routing identity.
- **Success, pending, queued, cancelling, cancelled:** today's `StaticToolCardContainer` click-to-open behavior, unchanged (user decision 4). `chat_send` is unchanged.
- The live sidecar stays mounted outside the container switch. An invocation failure (for example a failed wait call) must not mark a still-running Oracle operation as terminal.
- Risk: a live card that moves from pending to failed swaps container type mid-run. Mitigation: the static container holds no user state beyond a transient popover; the failure branch starts collapsed; the transcript row keeps `.id(item.id)`, so scroll identity is stable. Add one test asserting row identity is stable across the status change.

### B5. Patch B tests

- New `OracleToolResultInspectionTests`: plain-text, `is_error`/`code`/`error`, and structured failures through sanitize → persist → decode; selection rule with a leading empty entry; redaction-before-truncation (a secret straddling the cut); encoded 2,048-byte bound with Unicode and escaping; success golden unchanged; pending/cancelled-only unchanged; fixed point; DTO round-trip with no fabricated lane; preset-identity rule preserved; delegated notices preserved.
- Card presentation tests (e.g. `OracleToolCardInspectionTests`): non-empty failure subtitle; disclosure with no chat ID; separate Open action; lane failure inside a wait envelope shows as failed; legacy "Error details unavailable"; success/pending still static; row identity stable across pending → failed.
- Existing persistence-policy and card suites: deliberate updates only where failed-Oracle goldens change.

## 6. Patch C — Live group expansion and large groups

### C1. Explicit-choice provenance

- Add a presentation-only `transcriptBlockManualExpansionIDs: Set<String>` to `AgentTranscriptScrollOrchestrationState`, next to `transcriptBlockExpansion` and `transcriptBlockDefaultExpansion`. It is in-memory only, like them.
- One effective-expansion helper, used by `isTranscriptBlockExpanded`, `renderedRows(for:)`, both `transcriptBlockView` branches, and expansion counts:
  - no expandable content → collapsed;
  - ID in the manual set → stored value;
  - lock target without a manual choice → collapsed;
  - otherwise → today's stored/default behavior.
- The toggle flips the **effective** state, not the stored value. The first click on a default-expanded lock target that is showing collapsed must expand it. Both expand and collapse insert into the manual set.
- `syncTranscriptBlockExpansion(for:)` (`:3479–3506`) must not apply default-following to IDs in the manual set, and prunes the set with `validIDs`.
- Render the disclosure button whenever the block supports expansion, including for lock targets.
- `dynamicSummaryLockTargetTurnID` keeps its selection logic and becomes the default-collapse target (doc comment only). Both `toolCardAutoExpandEnabled` policies are unchanged, so expanding a group does not auto-expand its cards.
- Choices survive appends, status updates, and run completion within the presentation instance. A transcript reload returns to defaults, as for every block today.
- Gate: a production projection test proving a live activity cluster's `block.id` is stable as rows append and across group re-projection. If it is not, fix the ID derivation in the projection (the authority), not with a parallel override key.

### C2. Outer scroll: no new scroll-engine behavior

A manual toggle preserves the current outer follow/detach state. It does not write `userDetachedAutoFollow`, add anchor restoration, or cancel follow requests. The existing bottom-clearance handler re-pins on layout growth while pinned (`:2195–2215`). The run-activation handler (`:2219–2243`) counts only groups actually collapsing automatically and excludes the manual set, so a manual expansion never triggers a compensating re-pin. Validate that an in-flight smooth pinned send whose target was computed before the expansion is corrected once layout commits; if not, fix that as a general growth-while-pinned defect in the scroll engine, not a click-specific path.

### C3. Inner follow (user decision 5)

Only for an expanded lock-target activity cluster in the capped `useScroll` branch: wrap the inner list in `ScrollViewReader` and track whether the inner viewport is at its bottom. Use the repository's existing scroll-position observation helpers; verify API availability against the deployment target. On row-count change, scroll to the last row only while at the bottom; stop if the user scrolls up, and resume when they return to the bottom. No follow for grouped history (its sections do not append live), and none once the run ends.

### C4. Lazy rendering

Keep the five-row threshold and the 220/260-point caps; no pagination. In the capped branch, activity clusters use `LazyVStack` for rows. For grouped history, a lazy wrapper around eager sections is insufficient, so add a small helper (e.g. `Views/AgentTranscriptGroupInspection.swift`) that flattens sections into lightweight entries (section header, child-block summary, row, retention placeholder). Each entry carries stable identity and preserves headings, child disclosure, archived placeholders, and per-row render context; render the entries in a `LazyVStack`. Accepted caveat: offscreen lazy rows are recreated, so an inner card a user expanded can collapse after scrolling far away within the capped viewport.

### C5. Failure-count suffix

Append ` • N failed` to cluster and grouped-history headers when N > 0. Count each failed logical tool execution once, using existing execution identity and its latest normalized status. A multi-lane Oracle result with a failed lane contributes one failure; lane counts stay inside the card. Pending and cancelled work does not count. Compute it at the existing summary/projection update boundary, not by parsing JSON in view bodies; prefer extending the projection's existing counts if it already carries them. Older groups use only retained evidence; hide the suffix at zero without claiming everything succeeded.

### C6. Patch C tests

- A new group-inspection suite (e.g. `AgentTranscriptGroupInspectionTests`): effective-expansion truth table (manual set × lock × default × supports-expansion); a first click on a default-expanded lock target expands it; sync does not overwrite manual choices and prunes stale IDs; block ID stable across production appends; run-activation count excludes manual IDs; independent groups do not unlock together; flattened entries preserve section/child/placeholder structure; failure-count deduplication; pending/cancelled excluded.
- Add surgical ledger rows.

## 7. Material disagreements and resolution

### 7.1 M1 — Manual expansion vs. live-bottom auto-follow (converged in round 1)

One lane initially required a manual toggle to detach outer auto-follow, capture and restore the header anchor, and cancel queued follow work. Its argument was that otherwise the clicked header scrolls away. The other lane argued the height change is bounded once by the inner cap, today's toggles do nothing scroll-specific, and the stress-protected scroll engine should not gain a click-specific path. It also noted that detaching on collapse punishes users who collapse a group to get it out of the way. **Outcome:** both converged on §6.2: no outer detach and no scroll-engine API; an explicit-choice set; sync respects and prunes it; run-activation accounting excludes manual IDs. Inner auto-follow remained split (one lane: always follow while live; the other: never, because it yanks the user away from a failure). The user then chose bottom-sticky follow (§6.3).

### 7.2 M2 — Scope of persisted failure diagnostics (OPEN after two rounds; positions swapped each round)

Both lanes agree on the base contract in §5.3: the shared projection, redaction before truncation, the 2,048-byte encoded bound, no code from free text, no pending/progress/elapsed/stream-state at rest, byte-identical success output, a fixed point, and no fabricated lane. They disagree on whether to retain **more than one diagnostic and lane identity**.

- **Position N (narrow):** keep exactly one diagnostic (`errors[0]`) plus `error_count`, `error_truncated`, `summary_text`, and `mode`; no operation IDs, lane identity, or aggregate counts. Multi-lane reload fidelity is a follow-up. Arguments:
  - The reported defect is a failed card that cannot explain itself.
  - The realistic cases (pre-chat validation, a single-lane provider failure, atomic batch rejection) each carry one diagnostic.
  - `error_count` plus `error_truncated` already signal that more failures existed.
  - Lane identity and counts add a durable multi-key contract with an idempotence obligation.
  - Persisted nonterminal counts read as current state after relaunch.
  - Operation IDs correlate only with in-memory state that no longer exists after reload.
- **Position W (wider):** up to four `errors` entries, invocation-level error first and then failed lanes in stable index order. Each entry is `{index?, chat_id?, operation_id?, code? ≤80 B, message}`, with entry 0 ≤512 B and entries 1–3 ≤160 B. Add `lane_count`, `failed_count`, and `nonterminal_count`, computed from the original envelope. Shedding drops entries 1–3 first, then shortens entry 0 to 256 B. The final fallback keeps status, counts, a short primary diagnostic, and its bounded identity. Arguments:
  - A batch or wait result where one lane failed inside an otherwise completed invocation is also a failed card that must explain itself; one entry loses *which* lane failed.
  - Three counts are the minimum to say "2 of 3 failed, 1 unfinished when recorded".
  - Nonterminal counts are labeled "unfinished when recorded", never "still running".
  - Operation IDs are correlation references; loading a card never triggers a wait or recovery.

Round history: in round 1 the narrow lane widened and the wide lane narrowed; in round 2 they swapped again. Position N's final argument was that, with failed-only expansion, lane diagnostics inside a completed wait envelope "have no reader". **That premise is refuted by the code:** `OracleToolCardPresentation.state` returns `.failed` whenever any lane failed (`ToolResultCommunicationCards.swift:170–171`). Such a card is a failed card and is expandable under user decision 4.

**Recommendation (not yet adopted):** Position W, minus `operation_id`. Retain up to four entries with `index` and `chat_id`, where `chat_id` lets the user open the specific failed lane's chat after reload. Keep `lane_count` and `failed_count`, and keep `nonterminal_count` only with "unfinished when recorded" wording. Drop `operation_id`: after reload it correlates with nothing user-reachable, and Position N's argument holds for that field. Implement Position N's single-diagnostic base first within Patch B, then add the multi-entry extension in the same patch only if the reviewer or user accepts this recommendation. Both are additive and storage-compatible.

### 7.3 M3 — Oracle card container (decided by the user after round 1)

One lane proposed converting every Oracle card to the expandable container with a separate Open Oracle control. Its arguments: one interaction model, no container swap when a card goes pending → failed, and inspectable details for every state. The other lane proposed failed-only expansion, keeping the familiar click-to-open for success and pending. In round 1 each lane conceded to the other, swapping positions. **Outcome:** the user chose failed-only expansion (decision 4). The container-swap concern is kept as a risk with a mitigation (§5.4).

### 7.4 Minor points settled by the plan author

- **Error type for the model rejection:** keep `MCPError.invalidParams` with a stable text prefix, rather than switching to `ChatToolError` with structured `details`. Reason: `ChatToolError` is not an `MCPStructuredToolError`, so its details may not reach agents (E6); the text alone satisfies the self-correcting requirement. Prefix spelling: `oracle_model_required:`.
- **Explicit-choice provenance:** required, not optional, because `syncTranscriptBlockExpansion` seeds every block (E9). A "stored value present means the user chose" rule would expand default-expanded lock targets with no click.
- **Patch split:** three patches (A, B, C), consistent with user decision 6.
- **`CompressedToolGroupCard`:** left unchanged; it has no call sites and deleting it does not affect the reported behavior. Remove it in a separate cleanup.
- **Grouped-history laziness:** flattened entries (§6.4), because a lazy wrapper around eager sections does not virtualize.
- **Shared guidance fragment:** one `AgentModePrompts.Fragments` entry referenced from each surface, rather than duplicated sentences.

## 8. Validation

Use coordinated commands. Focused: `make dev-test FILTER=<Suite>` for `MCPAskOracleWorktreeTests`, `ToolCatalogSnapshotTests`, the new prompt-guidance, inspection, card, and group-inspection suites, and existing persistence-policy and card suites touched deliberately. Because Patch B touches Oracle DTO and card behavior, also follow the relevant parts of the [validation workflow](../workflows/validation.md): `make dev-core-test`, `make dev-swift-build PRODUCT=RepoPrompt`, `make dev-swift-build PRODUCT=repoprompt-mcp`, `make dev-lint`, `make guardrails` for new files, and `make dev-build` for a packageable debug artifact. Contribution evidence requires unfiltered `make dev-test-parallel`. Update the curated ledger surgically; never regenerate it.

Live checks need explicit user approval before any app launch or relaunch, and use the CE debug app and `rpce-cli-debug`:
- **A:** with the five-preset configuration, send a fresh `review` with `selection_mode:"none"` and no `model`. Expect one self-correcting rejection, then retry with a listed UUID and succeed with no selection and no diff packaged. Repeat with `explicit_slices`. Establish the packaging content through request capture, not just a successful reply.
- **B:** trigger a pre-chat validation failure. Expect a collapsed headline and selectable expanded text. Reload the transcript and confirm the explanation remains. A wait envelope with a failed lane shows as failed and expands.
- **C:** during a long run, expand a live group of 142+ rows. Confirm it stays expanded as calls arrive, the inner list follows only while at its bottom, the outer transcript keeps its follow state, the expansion survives run end, and the header shows the correct failure count.

Deterministic tests do not establish live behavior. Report what was not run.

## 9. Risks

- **Wire compatibility (A):** additive for previously valid sends. Golden hashes change for the edited descriptions only.
- **Fresh `review` with `none`:** may carry no repository evidence unless the message or slices supply it. That is the chosen contract and is stated in the guidance.
- **Persistence (B):** additive keys; old transcripts keep decoding; previously discarded diagnostics cannot be recovered; older app versions may drop the new keys on re-save (rollback limitation).
- **Secrets at rest (B):** heuristic redaction of free text; mitigated by allowlisted fields, redaction before truncation, and small bounds.
- **Block identity (C):** if live cluster IDs are unstable, the manual choice is lost on append. This is gated by the projection test.
- **Lazy state reset (C):** accepted and documented.
- **Container swap (B):** mitigated as described in §5.4.

## 10. Open questions

1. **§7.2 multi-lane failure persistence:** adopt the recommendation (Position W without `operation_id`) or keep Position N. Needs a reviewer or user decision before the Patch B extension.
2. Does the repository already have a diagnostic scrubber that meets §5.2? Verify before adding one.
3. Is a live activity cluster's `block.id` stable across appends (C1 gate)?
4. Does downstream review packaging reject a fresh `review` with empty context (A1 verification)?
5. For Claude and Codex parents, does a JSON-RPC `-32602` error land in the transcript item's `toolResultJSON` or `text`? Both projection inputs must cover it (B1).
6. Is the persisted status word of a mixed lane envelope "failed", so the reloaded card enters the failure branch? Verify; if not, derive failure from the retained `errors` and `failed_count`.

## 11. Maintainer-guidance check

- **User impact and invariant:** fresh Oracle chats with controlled context are not rejected; an omitted model yields one self-correcting error; every failed Oracle card explains itself, live and after reload; a user's explicit group expansion is honored during runs.
- **Root-cause confidence:**
  - Confirmed: both pre-provider rejections, the lost error text, the hard group lock, and seeded expansion state.
  - Inference: which rejection caused each logged failure, and the lock's scroll-stability purpose.
- **Authority:**
  - `parseSelectionMode` and `validateNewChatModelSelection` for the contract;
  - `OracleSendPackagingContext.applying` for packaging;
  - the new shared projection for Oracle failure persistence and presentation;
  - `AgentTranscriptScrollOrchestrationState` for expansion state;
  - the projection for block identity.
- **State safety:** shared selection is unchanged by send-local modes; persistence is additive with no migration; expansion state stays in memory.
- **Scale and observability:** lazy rendering for large groups; bounded encoded summaries; the failure-count suffix is computed at projection boundaries.
- **Recommended scope:** implement A, B, and C now. Follow-ups: batch-lane selection modes, availability-filtered model candidates, multi-lane reload fidelity beyond §7.2, and removing `CompressedToolGroupCard`.
- **Validation boundary:** the focused suites in §8, then approved live MCP and UI checks.
