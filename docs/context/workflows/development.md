# Coordinated development workflow

Scope: read when the task touches local setup, builds, tests, packaging, the debug app, MCP CLI, or developer-daemon coordination.
Authority: Authoritative
Last-verified: 2026-08-10

## Choose the coordinated path

Follow the [pinned coordination invariants](../../../AGENTS.md#invariants-pinned--apply-always), then use the `make dev-*` targets shown by [`make help`](../../../Makefile). The conductor daemon auto-starts, serializes jobs that share lanes, admits Swift/Xcode-heavy work through machine-wide slots, and protects the singleton debug app with a machine-wide live-app lock.

Heavy admission defaults to one job; change `REPOPROMPT_DEV_HEAVY_SLOTS=N` only when concurrent heavy work is intentional. Run-only `dev-test-artifact` jobs use a separate machine-wide `xctest` slot (`REPOPROMPT_DEV_XCTEST_SLOTS`, default 1) instead of the heavy slot. Source-validating `dev-test-parallel` holds the local `build` lane plus both machine-wide heavy and XCTest slots across its build and runner phases. A job that holds its local lanes while waiting for a machine-wide slot reports `waiting-heavy-slot` or `waiting-xctest-slot` for its slot class.

Coordinated test jobs default to bounded execution: a filter must resolve against the curated ledger or a source suite before any build starts (exit 64 otherwise), a filtered serial run that executes zero tests fails (exit 66), source/artifact integrity failures in the parallel lane fail closed (exit 67), and serial XCTest phase deadlines contain hangs (exit 70; startup 90s after `Build complete!`, active-method budget `max(90s, 4×ledger runtime+30s)` — 180s for methods without ledger runtime — between-method 60s). The parallel runner applies its own ledger-derived per-suite deadlines. Successful root serial and parallel jobs record a compatible artifact-provenance ticket; `make dev-test-artifact FILTER=<SuiteName>` re-runs that recorded bundle in seconds via `swift test --skip-build`, reporting `artifact_scope: current` or a prominent stale label. See the [validation workflow](validation.md#fast-test-loop-semantics) for the exit-code contract and evidence rules.

All coordinated and packaging SwiftPM invocations construct one byte-identical minimal environment through `Scripts/canonical_swift.sh`. Per-job values such as the conductor job ticket are excluded because SwiftPM keys its manifest-evaluation and build-plan caches on the exact child environment. The daemon runs as a launchd Interactive agent so coordinated jobs are not QoS-clamped; `REPOPROMPT_DEV_DAEMON_LAUNCHD=0` forces the legacy direct spawn.

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

Debug signing and secure-storage behavior are documented in the [local-build README](../../../README.md#build-and-launch-locally). An explicit `DEBUG_SECURE_STORAGE_BACKEND=keychain` is also supported for a signed debug app with a TeamIdentifier; otherwise debug builds use ephemeral in-memory storage. Release builds follow the [release workflow](../../releasing.md).

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
