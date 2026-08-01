# Dev-loop test backend measurement — 2026-07-31 UTC

## Environment

- Measurement window: 2026-07-31T20:57:38Z–2026-07-31T21:05:36Z
- Swift: `swift-driver version: 1.148.6 Apple Swift version 6.3.1 (swiftlang-6.3.1.1.2 clang-2100.0.123.102)`
- Swift target: `arm64-apple-macosx26.0`
- CPU: Apple M3 Ultra
- Memory: 274,877,906,944 bytes (256 GiB)
- Warm build directory: 8.2G by `du -sh .build`
- Initial working tree: clean
- Conductor before coordinated/direct phases: no active or queued jobs
- Timing: `/usr/bin/time -p`; all wall-clock values below are seconds.
- Focus suite: `ClaudeCodeProviderUsageTests` (1 XCTest method)

## Phase A — coordinated baseline

All commands used `make dev-test FILTER=ClaudeCodeProviderUsageTests`, which submitted `swift test --filter ClaudeCodeProviderUsageTests` through conductor.

| Scenario | Run | Wall | `Build complete!` | XCTest execution | Result | Compile observations |
|---|---:|---:|---:|---:|---|---|
| A1 warm no-op | 1 | 30.57 | 26.30 | 1 test in 0.003 | pass | no `Compiling` line |
| A1 warm no-op | 2 | 22.94 | 21.43 | 1 test in 0.002 | pass | no `Compiling` line |
| A2 test-file touch | 1 | 18.80 | 17.57 | 1 test in 0.002 | pass | 1 line: `Compiling RepoPromptTests ClaudeCodeProviderUsageTests.swift` |
| A3 app-file touch | 1 | 31.34 | 30.04 | 1 test in 0.002 | pass | 2 lines: `Compiling RepoPromptApp ClaudeCodeProvider.swift`; `Compiling RepoPromptTests ClaudeCodeProviderUsageTests.swift` |
| A4 post-revert warm restore | 1 | 28.25 | 26.91 | 1 test in 0.002 | pass | 1 line: `Compiling RepoPromptApp ClaudeCodeProvider.swift` |

A1 warm no-op median (two-sample midpoint): **26.755s** (reported as 26.76s).

Coordinated job tickets:

- A1.1: `173864a8-d626-43ca-87dd-a784732dd9fe`
- A1.2: `6b394f24-2f54-4c05-b01e-689e219219c6`
- A2: `5cc959f2-5584-4620-8c40-5cf6eca5043b`
- A3: `be3273b0-fa9f-43df-a2a8-f38414987ffc`
- A4: `cbbeb82d-fb96-4183-ab3a-39178121eb6c`

Protocol deviations forced by checkout/tool state:

- The requested A3 path `Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/ClaudeCodeProvider.swift` does not exist in this checkout. The sole current match, `Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCodeProvider.swift`, was measured.
- The requested A2 `git checkout -- <file>` revert failed because the managed sandbox could not create `.git/index.lock`. A2 and A3 were instead reverted by removing only the exact appended blank line/comment. `git diff --exit-code -- <file>` returned 0 after each revert.
- A4 rebuilt the restored app source because its mtime changed, leaving the build graph fully built for Phase B.

## Phase B — backend benchmark

Bundle used throughout:

`.build/arm64-apple-macosx/debug/RepoPromptCEPackageTests.xctest`

### B2 — SwiftPM `--skip-build`

No run emitted a `Build complete!` line, as expected for `--skip-build`.

| Run | Wall | User | Sys | XCTest execution | Exit |
|---:|---:|---:|---:|---:|---:|
| 1 | 13.77 | 15.70 | 13.56 | 1 test in 0.002 | 0 |
| 2 | 0.68 | 0.50 | 0.14 | 1 test in 0.002 | 0 |
| 3 | 0.69 | 0.51 | 0.15 | 1 test in 0.002 | 0 |
| 4 | 0.70 | 0.51 | 0.15 | 1 test in 0.002 | 0 |
| 5 | 0.69 | 0.51 | 0.15 | 1 test in 0.002 | 0 |

Median: **0.69s**.

Before these five valid samples, one sandboxed attempt failed in 1.13s because SwiftPM's nested `sandbox-exec` was denied. It ran no tests and is excluded. The five valid samples ran outside the tool sandbox. The first valid run paid a 13.77s manifest/planning/cache cost; the following four were sub-second.

### B3 — direct `xcrun xctest`

Working class invocation:

`xcrun xctest -XCTest RepoPromptTests.ClaudeCodeProviderUsageTests <bundle>`

| Run | Wall | User | Sys | XCTest execution | Test Case lines | Exit |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 0.07 | 0.04 | 0.02 | 1 test in 0.003 | 2 (start/pass) | 0 |
| 2 | 0.06 | 0.04 | 0.01 | 1 test in 0.003 | 2 | 0 |
| 3 | 0.06 | 0.04 | 0.01 | 1 test in 0.002 | 2 | 0 |
| 4 | 0.06 | 0.04 | 0.01 | 1 test in 0.003 | 2 | 0 |
| 5 | 0.06 | 0.04 | 0.01 | 1 test in 0.003 | 2 | 0 |

Median: **0.06s**.

The fully qualified class form worked on the first attempt; no fallback form was needed.

### B4/B5 parity

| Check | Backend | Wall | XCTest execution | Result |
|---|---|---:|---:|---|
| Bundle.module resources: `CodeMapGoldenTests` | `swift test --skip-build --filter` | 1.85 | 4 tests in 1.152 | pass |
| Bundle.module resources: `CodeMapGoldenTests` | direct `xcrun xctest` | 1.19 | 4 tests in 1.126 | pass |
| Git child processes: `GitBranchSwitchServiceTests` | `swift test --skip-build --filter` | 3.53 | 9 tests in 2.820 | pass |
| Git child processes: `GitBranchSwitchServiceTests` | direct `xcrun xctest` | 2.87 | 9 tests in 2.808 | pass |

Both parity pairs had identical pass/fail outcomes and test counts.

### B6 method selection

Invocation:

`xcrun xctest -XCTest 'RepoPromptTests.ClaudeCodeProviderUsageTests/testCompletionPayloadReportsCacheInclusiveInputAcrossTypedFallbackAndBoundaries' <bundle>`

Result: exit 0; exactly one Test Case started and passed; `Executed 1 test`; wall 0.07s; XCTest time 0.003s.

### Backend decision

Decision rule:

`adopt --skip-build if skip median <= max(3s, 1.25 * direct median)`

Observed threshold:

`max(3.00, 1.25 * 0.06) = max(3.00, 0.075) = 3.00s`

Observed `--skip-build` median: `0.69s <= 3.00s`.

**Decision: adopt `swift test --skip-build --filter` as the fast-run backend under the supplied rule.** Direct `xcrun xctest` is lower-latency in absolute terms (0.06s median), but the rule deliberately allows the more portable SwiftPM backend up to the 3s floor.

## Phase C — structural verification

### Aggregate test bundle

- Exactly one root-package `.xctest` bundle was found within `.build` at max depth 4.
- Bundle: `RepoPromptCEPackageTests.xctest`
- Bundle allocated size: 837,896 KiB (`du -sh`: 818M), including a large dSYM.
- Aggregate executable: `Contents/MacOS/RepoPromptCEPackageTests`
- Executable size: 367,547,272 bytes (`ls -lh`: 351M).
- This confirms the root package currently has one aggregate test executable rather than per-suite test products.

### Toolchain product-selection flags

- `swift test --help`: no `--test-product` and no `--product` selection flag.
- `swift build --help`: `--product <product>` exists; `--test-product` does not.
- Therefore this toolchain exposes no per-test-product selection flag for `swift test`.

### `-disable-bridging-pch` provenance

`git log -S disable-bridging-pch --oneline -- Package.swift` returns only:

`351e9803 Initial RepoPrompt CE snapshot`

The flag entered with the initial snapshot on 2026-05-31 and remains in the current app target settings. That commit and the nearby Package.swift lines contain no rationale beyond the initial-snapshot subject, so repository history provides **no recorded rationale** for disabling the bridging PCH.

The five most recent Package.swift commits at measurement time were:

1. `f65322ba Harden Sentry privacy and release promotion`
2. `5c1504f1 Split RepoPrompt into thin executable and app target (#437)`
3. `dccf051c Add minimal Sentry runtime wiring`
4. `73f2decd Add impacted XCTest lane and harden test tooling (#374)`
5. `d691b1f7 build(telemetry): link Sentry conditionally and document privacy model (#323)`

### Recorded compile flags

`.build/arm64-apple-macosx/debug/description.json` records `-Onone`, `-enable-batch-mode`, and `-j28` (208 occurrences each for the first two flags; `-j28` is the unique compact job flag).

## Phase D — optional verbose planning decomposition

Command shape: `swift test --skip-build --filter ClaudeCodeProviderUsageTests --verbose 2>&1 | head -50`, timed as a shell pipeline.

- Wall: 6.19s; user: 8.02s; sys: 10.89s.
- The first 50 lines were dominated by compiling and linking Package.swift manifests for the root package and dependencies (for example JSONSchema, Neon, SwiftOpenAI, swift-sdk, tree-sitter packages, and swift-log) after `Planning build`.
- This diagnostic pipeline truncates at 50 lines and is not a valid backend timing sample; it demonstrates that pre-test time is manifest evaluation/dependency planning rather than XCTest execution.

## Caveats

- Sample sizes are small: coordinated no-op n=2, each edit scenario n=1, backend comparisons n=5, parity checks n=1 per backend.
- Machine load was not controlled or sampled; this was an interactive workstation. Conductor adds daemon submission/wait overhead to Phase A.
- The two no-op samples vary by 7.63s, and the single edit observations should not be interpreted as stable distributions. In particular, the test-file edit happened to be faster than both no-op samples.
- The first valid `--skip-build` sample was a manifest/cache outlier (13.77s) while the next four were 0.68–0.70s. The requested median remains 0.69s, but cold/new-process cache behavior deserves consideration.
- `/usr/bin/time` user/sys for coordinated Phase A describes the short make/conductor client, not daemon build CPU.
- The direct SwiftPM commands required execution outside the measurement tool's sandbox because nested SwiftPM `sandbox-exec` was otherwise blocked. Direct `xcrun xctest` ran successfully without that exception.
- Timings are specific to Apple M3 Ultra, this dependency graph, this warm 8.2G `.build`, and Swift 6.3.1.
- No suite hung, and no cancellation was needed.

## Raw local logs

Command logs are under `/tmp/rpce-devloop-A*.log`, `/tmp/rpce-devloop-B*.log`, and `/tmp/rpce-devloop-D1-verbose-head.log`. Conductor job logs remain under its daemon jobs directory keyed by the tickets listed above. These are local raw evidence and were not added to the repository.
