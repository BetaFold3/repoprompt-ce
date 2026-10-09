# Coordinated development workflow

Scope: read when the task touches local setup, builds, tests, packaging, the debug app, MCP CLI, or developer-daemon coordination.
Authority: Authoritative
Last-verified: 2026-08-10

## Choose the coordinated path

Follow the [pinned coordination invariants](../../../AGENTS.md#invariants-pinned--apply-always), then use the `make dev-*` targets shown by [`make help`](../../../Makefile). The conductor daemon auto-starts, serializes jobs that share lanes, admits Swift/Xcode-heavy work through machine-wide slots, and protects the singleton debug app with a machine-wide live-app lock.

Heavy admission defaults to one job; change `REPOPROMPT_DEV_HEAVY_SLOTS=N` only when concurrent heavy work is intentional. Run-only `dev-test-artifact` jobs use a separate machine-wide `xctest` slot (`REPOPROMPT_DEV_XCTEST_SLOTS`, default 1) instead of the heavy slot. Source-validating `dev-test-parallel` holds the local `build` lane plus both machine-wide heavy and XCTest slots across its build and runner phases. A job that holds its local lanes while waiting for a machine-wide slot reports `waiting-heavy-slot` or `waiting-xctest-slot` for its slot class.

Coordinated test jobs default to bounded execution: a filter must resolve against the curated ledger or a source suite before any build starts (exit 64 otherwise), a filtered serial run that executes zero tests fails (exit 66), source/artifact integrity failures in the parallel lane fail closed (exit 67), and serial XCTest phase deadlines contain hangs (exit 70; startup 90s after `Build complete!`, active-method budget `max(90s, 4×ledger runtime+30s)` — 180s for methods without ledger runtime — between-method 60s). The parallel runner applies its own ledger-derived per-suite deadlines. Successful root serial and parallel jobs record a compatible artifact-provenance ticket; `make dev-test-artifact FILTER=<SuiteName>` re-runs that recorded bundle in seconds via `swift test --skip-build`, reporting `artifact_scope: current` or a prominent stale label. See the [validation workflow](validation.md#fast-test-loop-semantics) for the exit-code contract and evidence rules.

All coordinated and packaging SwiftPM invocations construct the same minimal environment through `Scripts/canonical_swift.sh` for a given effective configuration and debug-symbol policy. Queries, listings and no-build invocations use that same policy environment; switching between full and skip intentionally changes it. Per-job values such as the conductor job ticket are excluded because SwiftPM keys its manifest-evaluation and build-plan caches on the exact child environment. The daemon runs as a launchd Interactive agent so coordinated jobs are not QoS-clamped; `REPOPROMPT_DEV_DAEMON_LAUNCHD=0` forces the legacy direct spawn.

`Scripts/canonical_swift.sh` explicitly selects `--build-system native` for build and test commands, including test listing, artifact re-runs, and `--show-bin-path`. Xcode 27 / Swift 6.4 otherwise defaults to `swiftbuild`, which uses a different `.build/out` layout and can replay stale XCFramework errors from its on-disk build description even after the vendor plist is fixed. Keep the engine consistent with the native SwiftPM artifact paths used by packaging and the test runner; removing an absent `DebugSymbolsPath` from Sparkle metadata alone does not invalidate that other engine's cached description. No whole-cache deletion is needed for the coordinated native path. The same branch also pins `--no-color-diagnostics`. SwiftPM's default diagnostic color depends on whether output is a TTY. Watchdog test jobs run under a PTY and builds run through a pipe, so without the pin the compiler argv differed and every build↔test switch re-emitted modules. Compiler diagnostics are therefore uncolored. `debug_dsym.py` must recognize every flag the wrapper injects, or ordinary debug builds classify as `configuration_unknown`.

### Debug symbols

The debug policy is `RPCE_DEBUG_DSYM=on|off`, unset `off`; invalid values including empty fail before mutation. Effective debug skip adds `SWIFT_DRIVER_DSYMUTIL_EXEC=/usr/bin/true` consistently across builds and queries; release, ambiguous configuration and nonempty Sentry keep full symbols. `on` affects future links, while coordinated `make dev-dsym PRODUCT=all|RepoPrompt|repoprompt-mcp|repoprompt-gateway|root-tests` regenerates symbols for existing binaries without building. Symbols remain outside fingerprint-v2 compatibility. The new operation and policy forwarding require the current conductor protocol: its normal upgrade path replaces only an idle older daemon and refuses replacement while jobs are active or queued.

The index store policy is `RPCE_INDEX_STORE=on|off`, unset `off` (opt in with `on`); invalid values including empty exit 2 before Swift. Off adds `--disable-index-store` to every qualified debug build/test invocation, including listing and `--show-bin-path`, independent of `RPCE_DEBUG_DSYM`; release, ambiguous configuration and nonempty Sentry are untouched, and no known consumer reads the store. Only argv changes, so toggling costs one full rebuild; direct SwiftPM calls bypass this flag policy and switching back can cost another full rebuild. Forwarding needs conductor protocol 17: an idle older daemon is replaced on the next command; a busy one refuses until idle.

Regeneration is in place, with no staging/swap framework or automatic stale-symbol cleanup. On the qualified Apple LLDB 2100 / Xcode 26.4.1 toolchain, a UUID-mismatched adjacent dSYM was ignored during normal lookup; debug-map objects still supported test file:line breakpoints and local values in off mode. Preserve those objects for debugging. In-place failure can leave incomplete symbols; UUID verification reports that instead of promising backup restoration. Roll back with `RPCE_DEBUG_DSYM=on` for future builds and `make dev-dsym` for existing products. Requalify the undocumented driver hook and debugging after toolchain changes.

The 2026-10-08 lean rollout used ten alternating warmed one-file test edits per mode in one CE tree: on median 18.655 s, off 11.654 s (7.001 s / 37.5% faster). Null medians were 1.641 / 1.645 s (off +0.004 s). Default-off packaging and focused `AgentContextRatioDisplayTests` passed, as did 954 conductor selftests. In a minimal SwiftPM XCTest fixture using the candidate wrapper, conductor, helper and Makefile, a live test breakpoint showed values; a deliberate crash named the function before regeneration and its adjusted non-top-frame call-site address resolved to file:line against matching regenerated DWARF. The raw return PC was compiler-generated:0 both before and after, and the debug map already supplied the adjusted line. This does not prove unfiltered-root tests or quiet-host statistics. No automated `dev-dsym-check`, calibration, bootstrap or thermal admission gate applies.

### Performance investigation boundaries

Per-job `phaseMetrics.segments[].dsymPolicy` records the observed wrapper policy, not a filesystem inference. The legacy calibrated Swift build harness (`make dev-bench`) works only on revisions before the Step 10 helper/default-skip policy. It refuses later target refs before mutating worktrees because its historical unset-policy full/full labels would be wrong. Its current error mentions an ignored private recipe unavailable in other clones; that pointer and the Makefile help wording remain nonblocking follow-up. For current revisions, use an explicit on/off same-tree comparison and report the edited file, filter, timing boundary, alternation and medians; do not label the legacy harness as usable for future pipeline qualification. Explicitly setting `on` in future full-symbol harness arms is backlog, not implemented here.

The bounded 2026-10-08 pre-test investigation found an edit-associated interval after `Build complete!` and before the first suite about 2.7 s longer than a null run; it did not identify its process or cause. Both arms in that historical full/full capture generated full symbols, regardless of their `ab-on` / `ab-skip` location labels. Cold residuals include other intervals; do not describe all historical residual time as test startup. No speculative fix was landed. Packaging dispatches directly to its three product builds and executes the bin-path query once; printing that command is not a second execution. No duplicate query or cheap reuse fix was found. Process tracing and unexplained residuals remain optional follow-up, not build gates. Earlier accepted startup-target misses and contamination-inconclusive hashing gains remain evidence limitations, not claims of clean qualification.

The 2026-10-08 Swift compile follow-ups measured the `RepoPromptApp` emit-module bottleneck on a noisy host. In one cold build, among bodies warned at ≥200 ms, only `WindowRoutingService.updateCachedTools()` appeared in the emit-module job (525 ms; cause unconfirmed). Its visible type-check warnings totalled 807 ms (282 ms declaration-only), which identifies a marginal candidate lever from visible warnings, not an upper bound on total work; incremental savings are unverified. No hotspot was fixed and no code was extracted. An interface-neutral body-only `RepoPromptShared` edit can leave that shared `.swiftmodule` unchanged, so the app's emit-module job is skipped (3/3; full focused conductor-test medians, n=3 each: Core edit 11.151 s vs app edit 19.856 s). Commit-weighted savings estimates for a split are only an optimistic interface-locality proxy. With the index store off, app edits showed no measurable speed gain (n=2 per setting). On 2026-10-09 that build↔test emit-only rework was traced to the PTY/pipe diagnostic-color argv difference and fixed by the wrapper pin above. Measurement was advisory, with single samples: settled build→test→build reran with 0 production module emissions (12.1 s / 13.1 s, previously 32.9 s / 34.2 s).

### Parallel source-validating root tests

`make dev-test-parallel` is the promoted full-root contribution lane (`WORKERS=8` by default; `FILTER=<suite-regex>` is optional). It needs no prior ticket: the conductor invalidates any old root ticket, snapshots source, runs `Scripts/canonical_swift.sh build --build-tests`, rejects source drift, fingerprints the discovered root XCTest artifact, and then runs the direct-`xctest` worker pool. After the runner exits it rechecks source, environment gates, toolchain, artifact path, and artifact fingerprint before atomically recording a compatible artifact-provenance ticket. Per-job workdirs, test censuses, and strict candidate manifests live under the conductor jobs directory.

An unfiltered green run is full-root contribution evidence. Any `FILTER` is prominently labeled filtered and never satisfies full-root PR-ready evidence. The acceptance gate passed on 2026-08-07 with 10/10 consecutive green 8-worker runs (p50 about 166s, p90 about 194s, versus about 798s serial); the residual crash-retry tail sits in gateway/remote-session suites and is auto-retried by the runner. Serial `make dev-test` remains supported as the focused iteration path and fallback.

Daemon lanes coordinate submitted jobs, not source edits. Don't edit inputs during a build; wait for the build or edit activity to settle, then retry failures caused by concurrent modification. Mutating format jobs also claim the `build` lane; non-mutating format-check and lint use `style`, while format-tools status is unlaned.

For reconnectable work, use a stable request key:

```bash
./conductor build --async --request-key debug-package
./conductor job wait --request-key debug-package
```

Inspect queued or active work with `./conductor job list`; use `job status`, `job wait`, and `job cancel` with the returned ticket or request key. Add `--full-log` when concise failure highlights are insufficient; use `--verbose` only when delegated scripts need to capture extra diagnostics.

## Handle the debug app deliberately

Use `make dev-run` for the ordinary queued build/package/launch path. Use `make dev-launch-existing` only when the shared debug bundle already exists and no rebuild is needed. Use `./conductor app relaunch` only for a user-directed newest lifecycle action; it may supersede older queued lifecycle work. Follow the just-in-time approval invariant in [`AGENTS.md`](../../../AGENTS.md) before any visible launch, relaunch, stop, or other protected action.

A build/package failure before lifecycle activation does not replace or stop the running bundle. Don't assume an in-flight run or smoke job survives an overriding stop or relaunch; inspect its ticket.

Debug signing and secure-storage behavior are documented in the [local-build README](../../../README.md#build-and-launch-locally). An explicit `DEBUG_SECURE_STORAGE_BACKEND=keychain` is supported only for a strictly verified Apple Development debug signature with the exact debug bundle ID and a source-authorized team (`648A27MST5` or `AM9B9Y6HBV`). A package marker alone does not authorize persistence. The original team retains its existing debug Keychain service; `AM9B9Y6HBV` uses a separate `.team.AM9B9Y6HBV` service. Official release trust remains pinned to `648A27MST5`. Ad-hoc, unapproved, or mismatched signatures use ephemeral in-memory storage; keys saved there must be re-entered after restarting into an authorized build. Release builds follow the [release workflow](../../releasing.md).

The generated Xcode workspace is disposable. Follow the [Xcode workspace workflow](../../architecture/xcode-workspace.md); don't edit or commit `.build/xcode`.

A debug package is written to `.build/debug/RepoPrompt.app`; architecture-specific SwiftPM products are normally under `.build/<architecture>-apple-macosx/debug/`. `make dev-build FAST=1` explicitly opts into fast debug packaging; when package inputs match the last fully verified build it keeps all signing and identity/layout checks but skips redundant deep signature verification, post-sign architecture validation, and the embedded-helper smoke. The default remains fully verified, and release packaging ignores fast mode.

If the daemon is unavailable and direct packaging fails or hangs, capture traced output with `VERBOSE=1 ./Scripts/package_app.sh debug 2>&1 | tee /tmp/repoprompt-build.log`.

## Use the CE debug CLI

Use `rpce-cli-debug`, not production `rp-cli` or `rp-cli-debug`, when validating this app. Inspect or install it with:

```bash
make debug-cli-status
make install-debug-cli
./Scripts/doctor.sh --install-debug-cli
```

If the PATH link is unavailable, use:

```bash
"$HOME/Library/Application Support/RepoPrompt CE/repoprompt_ce_cli_debug" -e 'windows'
```

For a non-disruptive live check against an already-running CE debug app, start with `make dev-smoke`. Use `./conductor smoke --agent-run` only when provider credentials and model access are available. A manual MCP probe can use:

```bash
rpce-cli-debug -e 'windows'
rpce-cli-debug -w 1 -e 'workspace switch repoprompt-ce'
rpce-cli-debug -w 1 -e 'tree --type roots'
rpce-cli-debug -w 1 -c agent_manage -j '{"op":"list_agents","roles_only":true}'
```

### Enable Codex computer use for one explicit turn

Codex computer use is a persisted, default-off opt-in exposed through `app_settings` key `agent_mode.codex_computer_use_enabled`; there is no Settings-screen toggle. Enabling the key only makes an explicit `/computer-use` turn eligible:

```bash
rpce-cli-debug -w <window-id> -c app_settings -j '{"op":"set","key":"agent_mode.codex_computer_use_enabled","value":true}'
```

The production admission path rejects `/computer-use` in Safe Managed and Knowledge sessions and independently clamps the controller capability off for both. See the [computer-use implementation report](../../technical_implementation_reports/2026-09-03-codex-computer-use-enablement-report.html) for the implementation, safety, and validation record.

### Diagnose missing native Codex MCP tools

If every RepoPrompt tool is missing, inspect the Codex MCP startup error before
changing tool permissions or Oracle presets. Codex 0.154.0-alpha.6.2 advertises
`experimental: {"codex/auth-change": {}}`; the pinned Swift MCP SDK's
`Client.Capabilities.experimental` accepts only string values and rejects that
initialize request before tool discovery.

`MCPInitializeCompatibility` adapts only incoming initialize requests at the
app's UNIX socket boundary, ignoring unsupported non-string experimental entries
while retaining standard capabilities, client identity and string entries.
Wire diagnostics retain the original frame, and the existing initialization
approval hook still runs. Remove this adapter when the SDK supports arbitrary
JSON experimental values. Validate this boundary with
`make dev-test FILTER=MCPInitializeCompatibilityTests`.

### Run the transient OMP DEBUG smoke

`Scripts/smoke_omp_agent_mode.sh` is the one-command OMP post-relaunch smoke. Use it only after one coordinated relaunch has installed the current DEBUG binary, with fresh explicit approval obtained immediately before that relaunch. The script itself requires an already-running current DEBUG app and never launches, stops, relaunches, switches workspaces, or resumes a session.

For the first smoke, obtain only the target window's positive ID before running the script. Use the known catalog sentinel exact model ID `ohMyPi:default` (`AgentModel.defaultModel.rawValue == "default"`):

```bash
Scripts/smoke_omp_agent_mode.sh \
  --window-id <positive-window-id> \
  --model-id 'ohMyPi:default' \
  --output-parent /tmp
```

Ordinary `list_agents` discovery includes OMP only after the window has a successfully connected OMP provider. The qualification script does not depend on that public connection state: it acquires the strict transient lease first and then verifies the exact supplied ID through `list_agents`. For a later smoke with an explicit discovered OMP model, copy its exact ID from the private `list_agents.json` evidence produced by the first script run, or obtain it from a connected window.

The script acquires one hidden DEBUG-only process-owned qualification lease through `__repoprompt_debug_diagnostics`, verifies the supplied exact model ID through `list_agents`, and supplies the lease UUID only through the dedicated DEBUG `_omp_qualification_lease_id` start parameter. The lease is exclusive, process-local, expiring, non-persistent, absent from RELEASE, and transactionally bound by the app to the created session/run; discovery availability is not authorization. The script requires terminal exact-connection zero raw tool calls/in-flight calls/scopes, unchanged target-workspace identity and bounded no-follow content snapshots of tracked/index/existing-untracked state for every active root (Git-ignored paths are excluded), one strictly ordered post-baseline route with a distinct launched OMP ancestor and bundled helper descendant correlated by executable and process-start identity, and terminal expected-PID/policy cleanup. Every CLI call is output-bounded and process-group-owned with TERM/KILL/reap; failure cleanup cancels the exact nonterminal session, releases the exact lease, and verifies the lease inactive. The script never launches, stops, relaunches, switches workspaces, or resumes. This remains a qualification-only path independent of normal public availability and resume. The lease authorizes only its exact hidden DEBUG transaction; ordinary connected OMP starts and exact-or-error resume use the public production path without a lease. Treat the private evidence directory as temporary sensitive working evidence; do not publish or stage its raw JSON.

Use `agent_run` for an end-to-end provider probe only when credentials and model access are available:

```bash
rpce-cli-debug -w 1 -c agent_run -j '{"op":"start","model_id":"explore","session_name":"CE debug CLI smoke","message":"Reply exactly with CE_AGENT_RUN_SMOKE_OK and stop. Do not edit files.","detach":true}'
rpce-cli-debug -w 1 -c agent_run -j '{"op":"wait","session_id":"<session_id>","timeout":120}'
```

Before a live Agent Mode or Claude investigation, enable the DEBUG-only diagnostics through `app_settings`:

```bash
rpce-cli-debug -w 1 -c app_settings -j '{"op":"list","group":"agent_mode","detailed":true}'
rpce-cli-debug -w 1 -c app_settings -j '{"op":"set","key":"agent_mode.claude_raw_event_logging_enabled","value":true}'
rpce-cli-debug -w 1 -c app_settings -j '{"op":"set","key":"agent_mode.claude_raw_event_log_file_path","value":"/tmp/repoprompt-ce-claude-raw-events"}'
rpce-cli-debug -w 1 -c app_settings -j '{"op":"set","key":"agent_mode.perf_diagnostics_enabled","value":true}'
```

If a key is unavailable, verify `rpce-cli-debug --version` resolves to the current CE debug build. Treat raw CLI responses and diagnostic logs as private working evidence; don't stage them unless the task intentionally distills them into a durable document.

## Enable the optional local hook

CI is authoritative. To use the repository hook as a local accelerator, first inspect any existing hook configuration, then opt in:

```bash
git config --get core.hooksPath
git config core.hooksPath .githooks
```

Don't overwrite an intentional hook setup; compose `.githooks/pre-commit` into the existing manager instead. The hook checks current working-tree structure through the same script as CI; CI remains authoritative, and the hook does not replace staged-index contribution preflight.

Use `make clean` to remove `.build` only after coordinated jobs have stopped; don't delete build state underneath an active conductor job.
