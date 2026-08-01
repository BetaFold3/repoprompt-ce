# Coordinated development workflow

Scope: read when the task touches local setup, builds, tests, packaging, the debug app, MCP CLI, or developer-daemon coordination.
Authority: Authoritative
Last-verified: 2026-08-01

## Choose the coordinated path

Follow the [pinned coordination invariants](../../../AGENTS.md#invariants-pinned--apply-always), then use the `make dev-*` targets shown by [`make help`](../../../Makefile). The conductor daemon auto-starts, serializes jobs that share lanes, admits Swift/Xcode-heavy work through machine-wide slots, and protects the singleton debug app with a machine-wide live-app lock.

Heavy admission defaults to one job; change `REPOPROMPT_DEV_HEAVY_SLOTS=N` only when concurrent heavy work is intentional. Run-only artifact test jobs use a separate machine-wide `xctest` slot (`REPOPROMPT_DEV_XCTEST_SLOTS`, default 1) instead of the heavy slot; a job that holds its lanes while waiting for a machine-wide slot reports `waiting-heavy-slot` or `waiting-xctest-slot` for its slot class.

Coordinated test jobs default to bounded execution: a filter must resolve against the curated ledger or a source suite before any build starts (exit 64 otherwise), a filtered run that executes zero tests fails (exit 66), XCTest phase deadlines contain hangs (exit 70; startup 90s after `Build complete!`, active-method budget `max(90s, 4×ledger runtime+30s)` — 180s for methods without ledger runtime — between-method 60s), and filtered jobs time out at 20 minutes. After every successful root test job the daemon records a build ticket (source snapshot, env gates, toolchain); `make dev-test-artifact FILTER=<SuiteName>` re-runs the recorded bundle in seconds via `swift test --skip-build`, reporting `artifact_scope: current` or a prominent stale label. See the [validation workflow](validation.md#fast-test-loop-semantics) for the exit-code contract and evidence rules.

Direct swift invocations deliberately do not receive per-job environment values such as the conductor job ticket: SwiftPM keys its manifest and build-plan caches on the child environment, and a unique per-job value forces a full re-plan on every coordinated swift job.

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

A debug package is written to `.build/debug/RepoPrompt.app`; architecture-specific SwiftPM products are normally under `.build/<architecture>-apple-macosx/debug/`. If the daemon is unavailable and direct packaging fails or hangs, capture traced output with `VERBOSE=1 ./Scripts/package_app.sh debug 2>&1 | tee /tmp/repoprompt-build.log`.

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
