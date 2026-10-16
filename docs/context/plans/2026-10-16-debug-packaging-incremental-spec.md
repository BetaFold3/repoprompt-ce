# Debug packaging: incremental `./conductor build` and staging reuse — technical spec

Scope: read when the task touches debug app packaging speed in `Scripts/package_app.sh` (`IS_RELEASE=0` paths), incremental packaging keys and caches (`Scripts/debug_package_cache.py`), signed Sparkle/helper reuse, hidden-sibling assembly and publish, proportional verification, the packaging no-op skip, live-bundle staging reuse in `conductor run`, or retiring `Scripts/fast_package_fingerprint.py`.
Authority: Reference
Last-verified: 2026-10-16

This spec merges two reconciled Oracle drafts. Nothing in it is implemented, measured live, or reviewed against an implementation yet. Anchors are `file:line` plus a quoted anchor string where useful; if a line has drifted, the string wins. Calibration: developer tooling in a solo-owner private fork. Only realistic breakage counts, and a loud non-zero failure that names the exact recovery is an adequate remedy.

## Goal

Cut the time debug packaging spends outside compilation and linking, without changing release packaging, signing identities, bundle IDs or update channels. Three cases matter:

1. A no-change `./conductor build` into an existing destination (the owner uses `/Applications`).
2. A one-file app edit with unchanged nested components (Sparkle and the two helpers).
3. A no-change `./conductor run` or relaunch into a new, empty staging destination.

Every debug invocation still ends with a launchable, correctly signed bundle. Every failure is loud and names its recovery.

## Done when

- Debug runs one real `swift build` for all three executable products.
- Debug no longer signs the main executable separately, provided the Step 2 live comparison matches.
- Changed packages are assembled in a hidden sibling and published only after every required check passes. A partial bundle never occupies the destination, and a failed publish never deletes the only copy of the previous bundle.
- After an app-only edit, Sparkle and the helpers are neither re-signed nor (in proportional mode) deep-verified.
- A no-change `build` into an intact destination does no assembly or signing. It still runs the mandatory checks and still prints `Created:`.
- A no-change `run` gets a complete staged bundle by cloning the live bundle, never by depending on earlier staging contents.
- `REPOPROMPT_DEBUG_PACKAGE_CACHE=off` disables all reuse and forces full signing and verification.
- Release, local self-signed and universal packaging are byte-identical in script text apart from the `IS_RELEASE` gating. Every pinned assertion still holds or moves with equal strength.
- Tests and paired same-tree measurements demonstrate the behaviour. Advisory, provisional targets, re-derived in Step 0: a no-change `package_app.sh` total ≤ 4 s (from 9–10 s), and non-compile phases after an edit ≤ 3.5 s. Missing a target blocks nothing.

## Non-goals

- Changing root XCTest ticket invalidation. `build` still invalidates before it executes (`operation_invalidates_root_build_ticket`, `conductor.py:2752–2759`, called at `:4386–4387`). A no-op is known only after SwiftPM ran, and that SwiftPM shares `.build/<triple>/debug` with `swift test`.
- Skipping SwiftPM on source stamps, Swift compile speed, or changing `conductor swift-build --product all`.
- Piecemeal in-place assembly, a retained complete-package cache, per-build whole-bundle or main-executable hashing, and caching `doctor.sh --quiet` (measured 0.37 s; deferred).
- A new lock. Concurrent direct `package_app.sh` runs are explicitly unsupported (P2, deferred); the conductor heavy slot is the supported serialization.
- Resistance to hostile tampering with user-owned local caches.
- Any change to conductor's stop, launch, lock ordering or staged activation. Conductor's own rollback in `activate_staged_debug_bundle` deletes its backup unconditionally (`conductor.py:7951–7967`, `shutil.rmtree(backup, ignore_errors=True)`). Fixing it is a separate follow-up that could apply the publish rule below.
- Editing or re-recording `Scripts/Fixtures/build-metrics/v1/*`.

## Design

### Baseline facts and constraints

- **Measured on the owner's machine.** `/Applications`, `.build` and Application Support share one APFS volume (device 16777232). The bundle is 356 MB: main executable 320 MB, helpers 27 MB and 21 MB. These logical sizes don't sum consistently, so Step 0 records logical and allocated size. `shasum -a 256` of the main executable takes 0.74 s. A no-change package takes 9–10 s, roughly 3 s Swift, 2 s layout and 4 s sign/verify, from the existing 1-second phase lines. bash is 5.3.3, so `$EPOCHREALTIME` exists.
- **Today's flow in `package_app.sh`.** Three product builds (`:258–265`) and `--show-bin-path` (`:267–269`). Then `rm -rf "$APP_BUNDLE"` (`:298`) and in-place assembly. Then Sparkle, helper and main-executable signs (`:516–519`) and the outer sign (`:527–531`). Then deep verify (`:532–536`), identity (`:537`), post-sign architecture (`:538–542`), layout (`:549`) and smoke (`:550–560`).
- **Real debug destination.** It is `~/Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app` (`package_app.sh:276`, mirrored by `debug_app_bundle_path`, `conductor.py:7675–7681`). `.build/debug/RepoPrompt.app` is only the compatibility link (`:278`, `:566–578`). `docs/context/workflows/development.md:85` states this wrongly.
- **Keys never use bundle copies of executables.** `install_name_tool -add_rpath` (`:374`) rewrites the bundle copy of the main executable, so keys use `$BUILD_DIR` executables. The main executable is never cached.
- **Gate on `IS_RELEASE`.** Local self-signed release also takes the host-native branch (`:247–270` when `PUBLIC_UNIVERSAL_RELEASE=0`), so every cut gates on `IS_RELEASE`, never on `PUBLIC_UNIVERSAL_RELEASE`.
- **`conductor run` never passes `fast`.** `package_debug_app_under_heavy` (`conductor.py:7885–7919`) runs `package_app.sh debug` and overrides only `REPOPROMPT_DEBUG_APP_BUNDLE` (`:7898`). The staged destination `<live parent>/.staging/<token>/RepoPrompt.app` (`:7871–7874`) does not exist when packaging starts.
- **Conductor already swaps atomically.** `swap_staged_debug_bundle_into_place` (`conductor.py:7922–7938`) calls `renamex_np(..., 0x2 RENAME_SWAP)` through `ctypes`. Same-volume swap and rename keep the staged root inode, which becomes the live inode.
- **The old fingerprint hashes every byte of the finished bundle** (`fast_package_fingerprint.py:24–54`, `_manifest_paths` and `_hash_entry`). Any app edit invalidates it, so `fast` only ever helped no-change builds.
- **`sign_sparkle_framework()` already exists** (`:464–471`). Its five pinned `sign_path` lines are `$framework`-relative, so a cache can call it on a work directory without touching the pin.
- **`APP_SIGN_ARGS` never contains `--deep`** (`:520–531`). The outer sign therefore does not re-sign nested code.

### Cut ranking

| Rank | Cut | Payoff (advisory) | Risk | Disposition | Step |
|---|---|---|---|---|---|
| 1 | A: one debug `swift build` | ~1.5–2 s every build | Low | Keep | 1 |
| 2 | D3: drop the debug main-executable sign | One codesign pass over 320 MB | Low | Keep if the live comparison matches | 2 |
| — | C′: fresh sibling assembly and publish | ~0 s; protects the destination | Med | Mandatory foundation | 3 |
| 3 | E+F: input keys and proportional verification | ~1–2 s after an edit | Low–med | Keep, behind `fast` until Step 7 | 4 |
| 4 | D1/D2: signed Sparkle and helper caches | ~0.5–1 s after an edit | Med | Keep | 5 |
| 5 | B: no-op skip and staging reuse | ~5 s on no-change `build` and `run` | Med | Keep; no complete-package cache | 6 |
| — | Bin-path cache | Unknown | Low | Only if Step 0 measures ≥ 0.5 s | 1/4 |
| — | Vendor-verification receipt | Unknown | Med | Only if Step 0 measures ≥ 0.3 s | 4 |
| — | C: piecemeal in-place assembly; a new lock | — | Med–high | Drop; C′ makes stale files impossible by construction | — |

Steps follow dependencies, not rank. C′ comes first because stamps key on the published root inode and every reuse path publishes through it.

### Shared helper and modes

- **The helper.** `Scripts/debug_package_cache.py` is a new stdlib-only CLI, invoked as `python3 -I -S "$CONTROL_PLANE_SCRIPTS_DIR/debug_package_cache.py" <subcommand>`, the pattern `canonical_swift.sh:85` uses for `debug_dsym.py`. It does not import `conductor.py`, choose signing identities, or duplicate signing policy. Its logic lives in importable functions so tests can inject stat records, `find-identity` text and rename/swap callables.
- **Output.** `key=value` lines, the first being `schema=1`. `package_app.sh` reads them with `while IFS='=' read -r k v` and a `case` over known keys; an unknown key fails loudly. No `eval`, no bash associative arrays.
- **Misses versus errors.** A stale or missing entry is a normal miss. An operational error exits non-zero with context.

| Subcommand | Step | Purpose |
|---|---|---|
| `publish --new P --dest D --temp-parent T` | 3 | Publish (§C′) |
| `cleanup-stale --parent DIR --max-age 3600` | 3 | Remove stale `.rpce-package-*` siblings |
| `resolve-identity --sign-identity S` (stdin: `find-identity` output) | 4 | Print `cert=<sha1>\|adhoc\|unresolved` |
| `plan …` | 4 (extended in 5–6) | Print keys, mode, outcome, deep-set decision and `receipts_allowed` |
| `record …` / `forget …` | 4 (stamps in 6) | Write receipts; evict on failure |
| `component-lookup` / `component-commit` | 5 | Signed component cache |
| `inventory --bundle B` | 6 | Destination inventory |

**Escape variable.** `REPOPROMPT_DEBUG_PACKAGE_CACHE=on|off`; unset means `on`, and any other value fails before any build or mutation.
- `off` disables component caches, the no-op skip, live-bundle reuse and the bin-path and vendor receipts. It does no cache or receipt reads or writes, and forces full signing and full verification.
- `off` still uses the single build, the outer-only main sign and safe publication.
- Release ignores the variable and never enters the helper.

**Proportional mode.** In Steps 4–6 it comes from the existing `fast` argument (`package_app.sh:85–92`). Step 7 proposes it as the default (Q1). After that, `fast` stays an accepted no-op compatibility alias, and its forwarding and lane tests stay.

### Cut A: one debug SwiftPM build (Step 1)

- **Release is untouched.** The change applies only inside the host-native branch (`package_app.sh:254–270`) and only when `IS_RELEASE=0`. The KeyboardShortcuts patch phase (`:255–256`) keeps its place. Release keeps its three `phase "Building … ($CONF, host-native)"` calls byte for byte and in order.
- **Debug runs one phase,** `phase "Building debug products ($CONF, host-native)"`, which calls `canonical_swift.sh build "${SWIFT_BUILD_ARGS[@]}"` with no `--product`. `canonical_swift.sh` itself is unchanged.
- **Check the default graph.** Building without `--product` builds every root non-test target, and `Package.swift:126–130` declaring three products does not prove the default graph. Step 1 runs `swift package describe --type json` to check that no extra root targets get built. If any do, it measures their cost before keeping the cut.
- **Missing products still fail.** The existing `Missing built executable` check (`:305`) fails clearly when a product is absent.
- **Replan check.** `canonical_swift.sh:3` records 14–27 s replans caused by environment deltas. Whether alternating `--product` builds with product-less builds also replans is unverified; Step 1 checks it.

**Bin path.** Keep the single canonical `--show-bin-path` call (`:267–269`). Step 0 measures it. Add a cache only if the warm median is ≥ 0.5 s net of key cost.
- The key would cover `Package.swift` and `Package.resolved` bytes, `canonical_swift.sh` and its transitive policy inputs, `CONF`, `uname -m`, `xcode-select -p`, the resolved `swift-frontend` stat tuple, and every environment variable `canonical_swift.sh` reads. The closure test enforces the environment list.
- A hit requires all three executables to exist in the cached directory. Otherwise the entry is discarded and the real query runs; a query failure stays fatal.

### Cut D3: drop the debug main-executable sign (Step 2)

- **Change.** Wrap `sign_path "$APP_BUNDLE/Contents/MacOS/$APP_NAME"` (`:519`) in `if (( IS_RELEASE ))`. In debug, the outer bundle sign (`:527–531`) then signs the main executable.
- **Gate.** A one-time live comparison, not a runtime check. Package identical inputs with the baseline and candidate scripts. For the bundle, both helpers and Sparkle, compare:
  - `Identifier`, `CDHash`, `TeamIdentifier` and the `Authority` chain (`codesign -dv --verbose=4`);
  - entitlements (`codesign -d --entitlements :-`);
  - the designated requirement (`codesign -d -r-`).
- **On any difference,** keep the sign call and record the diff in evidence.

### Cut C′: fresh hidden-sibling assembly and atomic publish (Step 3, mandatory for debug)

**Assembly.**
1. After the build-path printout (`:281`) and before `Creating app bundle layout` (`:297`), debug sets `PACKAGE_DEST="$APP_BUNDLE"` and runs `mkdir -p` on its parent, which staging needs. It creates `TEMP_PARENT="$(dirname "$PACKAGE_DEST")/.rpce-package-<pid>-<random>"` and reassigns `APP_BUNDLE="$TEMP_PARENT/$(basename "$PACKAGE_DEST")"`.
2. Compute `APP_BUNDLE_MATCHES_COMPAT` (`:299`) against `$PACKAGE_DEST`. In debug, move the early `rm -rf "$COMPAT_APP_BUNDLE"` (`:301`) to after publish.
3. All assembly, signing and verification keep operating on `$APP_BUNDLE`. The pinned strings `sign_path "$APP_BUNDLE" "${APP_SIGN_ARGS[@]}"` and the `.bundle` copy loop (`:318`) therefore survive.
4. `rm -rf "$APP_BUNDLE"` (`:298`) becomes release-only. Starting empty removes obsolete files without a deletion ledger. Normalization (`normalize_swiftpm_resource_bundles.sh`, `:320`) is the only step that mutates the bundle, and it runs before signing. A reused signed bundle is never normalized.
5. After every check passes, run `publish`. Then reset `APP_BUNDLE="$PACKAGE_DEST"` before the compatibility link (`:566–578`) and `Created:` (`:579`).

The temp parent is the destination's sibling, so publish is always a same-volume rename. Sentry dSYM generation (`:283–295`) reads only `$BUILD_DIR`, so the new path doesn't affect it.

**`publish`** (Python, single process):
1. Reject a destination that is a final-component symlink, or that exists but is not a directory.
2. Write `T/.retain` before touching the destination.
3. **Destination absent** (always the case for staging): `rename(new, dest)`.
4. **Destination present:** call `renamex_np(new, dest, RENAME_SWAP)` through `ctypes`, with the signature and flag copied from `conductor.py:7922–7938`; the module does not import conductor. On success the old bundle sits at `new`'s former path inside `T`.
5. **Swap unsupported** (`ENOTSUP`, `EINVAL`, `ENOSYS`, or a missing symbol): fall back to two renames with rollback.
   1. `rename(dest, T/previous-<basename>)`. On failure nothing has changed: exit 1.
   2. `rename(new, dest)`. On success, go to step 7.
   3. Otherwise restore with `rename(T/previous-<basename>, dest)`. If that succeeds, exit 1 with `publish failed; previous bundle restored`.
   4. **If the restore fails (P1 fix):** keep the backup and `.retain`, exit 3, and print `PUBLISH FAILED: <dest> is missing. Previous bundle preserved at <backup>. New bundle at <new>. Recover: mv "<backup>" "<dest>"`. Never copy conductor's unconditional backup deletion (`conductor.py:7951–7967`).
6. **Any other swap error:** exit 1; the destination is untouched.
7. **Success:** remove `T/.retain`, then delete `T` on a best-effort basis. If the delete fails, warn and leave `T` for stale cleanup.

The fallback is recoverable but not crash-atomic. The destination may be briefly absent, but it never holds a partial bundle.

**`finish()`** (`:71–82`; the `trap 'finish $?' EXIT` text at `:83` is unchanged) deletes `$TEMP_PARENT` only if the destination still exists and `.retain` is absent. Otherwise it keeps the directory and reprints the recovery line.

**Stale cleanup.** At debug startup, `cleanup-stale` removes `.rpce-package-*` siblings of the destination that are older than 1 hour. It never removes one containing `.retain`; it prints the recovery line instead. It never touches conductor's `.staging` directories.

**Lifecycle.**
- The installed bundle is untouched until publish. Today's `rm -rf` already removes it from under a running app, so the swap is no regression.
- On failure, conductor removes the whole staging parent (`cleanup_staged_debug_bundle`). Staged publish targets an absent destination and never creates a backup, so that cleanup can never delete an only copy.

### Cut F: input keys and receipts (Step 4)

**Encoding.** Each key is the SHA-256 of a schema-versioned, labelled, NUL-separated stream. Missing values are written explicitly. Large outputs are keyed by trusting normal linker and filesystem metadata, not by cryptographic content identity. No per-build SHA-256 of the 320 MB executable remains.

| Record | Fields | Used for |
|---|---|---|
| Product record | `(dev, ino, size, mtime_ns, ctime_ns)` plus mode | `$BUILD_DIR/{RepoPrompt,repoprompt-mcp,repoprompt-gateway}`. `ctime_ns` can't be set from userland, so a rewrite with a restored mtime still invalidates |
| Tree manifest | Sorted full membership; per entry `(rel, type, mode, size, mtime_ns, ctime_ns, ino, symlink_target)`; directory symlinks are not followed | `$BUILD_DIR/*.bundle` and `$BUILD_DIR/Sparkle.framework`. A superset of what gets copied only causes extra misses |
| Repo-input record | `(rel, type, mode, symlink_target, sha256)` | Small repository inputs |

**Sparkle source basis.** Step 0 compares Sparkle stat manifests across two no-change builds. If they churn, Sparkle is keyed on the vendor-tree hash. That is sound because the vendor verifier always checks the build copy against the vendor tree.

| Key | Contents |
|---|---|
| `input_key` (bundle level) | Schema version; canonical `ROOT_DIR` and worktree name (provenance records both); `CONF`, `APP_NAME`, `DISPLAY_NAME`, `BUNDLE_ID`, `URL_SCHEME`, `MARKETING_VERSION`, `BUILD_NUMBER`, the storage and signing-mode markers, `ARCHITECTURE_POLICY`, `REPOPROMPT_ENABLE_SENTRY` and every other `ENV_INPUTS` variable; the signing-policy key; the three product records; tree manifests of every `$BUILD_DIR/*.bundle` and of Sparkle (or the vendor hash); repo inputs `AppBundle/Info.plist.template`, `LICENSE`, `THIRD_PARTY_NOTICES.md`, the `ThirdPartyLicenses/` and `AppResources/` trees, and the version sources read by `load_release_metadata.sh`; the control-script closure digest; Git branch, commit and dirty flag |
| Excluded from `input_key` | The destination path; generated provenance bytes and timestamps; output signatures and inventories; dSYMs |
| Signing-policy key | `cert` (below); `SIGNING_MODE_MARKER`, `DEBUG_STORAGE_BACKEND_MARKER`, `USE_ADHOC_SIGNING`; the macOS build (`sw_vers -buildVersion`); the `/usr/bin/codesign` stat tuple; `CODESIGN_ALLOCATE` and its resolved stat, when set; the control-script digest, which covers the exact signing-argument text |

**Provenance.** Git state is in the key, so a hit always carries accurate provenance. On a no-op hit the provenance bytes are preserved; build time means assembly time. The cost is one repackage per commit or dirty flip. Unavailable Git metadata keeps today's explicit `null` values (`:392–400`).

**Control-script closure.** The helper defines `INPUT_SCRIPTS`, `NESTED_SCRIPTS`, `REPO_INPUTS`, `ENV_INPUTS`, `DECLARED_DYNAMIC` and `CLOSURE_EXCLUSIONS` (a dict mapping each name to a reason). Basenames must be unique.
- **`INPUT_SCRIPTS`:** `package_app.sh`, `debug_package_cache.py`, `load_release_metadata.sh`, `normalize_swiftpm_resource_bundles.sh`, `validate_required_swiftpm_resource_bundles.sh`, `verify_sparkle_vendor.sh`, `validate_app_architectures.sh`, `validate_embedded_mcp_helper_layout.sh`, `smoke_embedded_mcp_helper.sh`, `run_without_github_tokens.sh` and `validate_json.py`, plus the data files they read and every `DECLARED_DYNAMIC` entry.
- **Dynamic dependencies are declared explicitly.** Today's example is `$CONTROL_PLANE_SCRIPTS_DIR/$FAST_PACKAGE_LAYOUT_VALIDATOR_NAME` (`:438`), which Step 4 removes.
- **Exclusions:**
  - `doctor.sh`: no output effect.
  - `canonical_swift.sh` and `patch_keyboard_shortcuts_resource_lookup.sh`: their effect reaches the key through product stats.
  - `build_swiftpm_release_products.sh` and `write_app_artifact_manifest.py`: release-only.
  - `upload_sentry_debug_symbols.sh` and `debug_dsym.py`: Sentry runs disable bundle reuse.
- **Not all of `Scripts/`.** Hashing it would let unrelated conductor edits invalidate signing caches.

**Signing identity.** Step 4 merges the two `security find-identity` calls (`:179`, `:207`) into one `security find-identity -v -p codesigning`. The output is kept in a shell variable and reused for auto-detection and for the existing warning, whose text is unchanged. `resolve-identity` mirrors how `codesign -s` resolves an identity:

| Condition | `cert` |
|---|---|
| Ad-hoc signing | `adhoc` |
| `SIGN_IDENTITY` is a 40-hex SHA-1 (case-insensitive) of one valid identity | That SHA-1 |
| `SIGN_IDENTITY` is a name substring matching exactly one valid identity | That identity's SHA-1 |
| Anything else (ambiguous or no match) | `unresolved`: print `WARNING: signing identity not uniquely resolved; package caches disabled`, disable all reuse and receipts, force the deep set, and let today's signing attempt proceed |

Keys never use a display name alone, so a certificate renewed under the same name invalidates them.

**Receipts.**
- They are written only when the run succeeded, `receipts_allowed=1` and the cache is not `off`.
- The verified record is written only after every deep check passed in the same run. Stamps are written after publish.
- A failed receipt write warns and does not fail the run; the next run is a miss.

**Self-heal.** If `finish()` sees a non-zero status after `plan` ran, it calls `forget` on the destination stamp, the reuse source's stamp, the verified record and every component entry used in this run. The error message names `REPOPROMPT_DEBUG_PACKAGE_CACHE=off` and `rm -rf .build/debug/package-cache`. There is no automatic in-run retry.

**Retiring the old fingerprint.** Step 4:
- deletes `fast_package_fingerprint.py`, `FAST_PACKAGE_*` (`:423–446`, `:532–560`) and `.build/debug/fast-package-verified.sha256` (old files are simply ignored);
- retargets `test_release_tooling.py:31–70` and the split marker at `:191–195`;
- replaces the `Scripts/fast_package_fingerprint.py` entry in `swift_build_benchmark.py` `RUNTIME_FILES` (`:95–107`) with `Scripts/debug_package_cache.py`.

### Cut E: proportional verification (Steps 4 and 7)

| Set | Checks | When |
|---|---|---|
| Mandatory (M) | Vendor Sparkle verification (`verify_sparkle_vendor.sh`, `:371–372`); `validate_required_swiftpm_resource_bundles.sh`; architecture check (pre-sign at `:375` on fresh assembly, on the candidate for reused bundles); new non-deep `codesign --verify --strict "$APP_BUNDLE"`; `verify_signed_app_identity`; `validate_embedded_mcp_helper_layout.sh`; per-component checks if Step 4's experiment requires them | Every successful debug outcome: fresh, `noop-dest`, `noop-clone` |
| Deep (D) | `codesign --verify --deep --strict` (`:532–536`); post-sign architecture check (`:538–542`); helper smoke (`:550–553`) | Per the rule below |

**Vendor verification receipt.** Vendor verification stays mandatory unless Step 0 measures a warm median ≥ 0.3 s. A receipt may then replace it, but it must cover the stat manifests of both compared trees, the expected vendor manifest and the verifier's transitive inputs. A verifier failure is always fatal.

**`nested_key`.**
- **Covers:** the signing-policy key; `sparkle_key` and both helper keys; every copied SwiftPM resource-bundle manifest (a conservative superset); `ARCHITECTURE_POLICY`; and the `NESTED_SCRIPTS` digest (architecture, layout, smoke and token-stripping scripts, plus `debug_package_cache.py`).
- **Excludes:** the main executable, `Info.plist`, top-level resources, Git state and provenance. These still invalidate `input_key`, and the non-deep strict verify covers them.

**Deep-set rule.** D runs unless all of these hold:
1. proportional mode is on;
2. the cache is not `off`;
3. `cert` is resolved;
4. `nested_key` equals the verified record;
5. no nested component was freshly signed in this run.

Fresh outer-bundle signing alone does not force D; otherwise a main-only edit would never benefit. Full mode always runs D. Consequence: until Step 5 adds component caches, every fresh assembly freshly signs every nested component, so D always runs. Step 4 is therefore validated through `plan` with injected states, and the first live skip appears in Step 5.

**Mandatory nested-tamper experiment (Step 4).**
1. Flip one byte in a code page of a signed nested helper inside a signed bundle.
2. Run the non-deep outer `codesign --verify --strict`.

If the outer verify rejects the flip, record the evidence. If it accepts it, add a non-deep `codesign --verify --strict` of each cached component whenever it is used, including through `noop-dest` and `noop-clone`. For Sparkle the check covers its five signed paths, not only the framework root. Tamper tests cover a helper and Sparkle's nested code.

### Cuts D1/D2: signed Sparkle and helper caches (Step 5)

The cache root is `$ROOT_DIR/.build/debug/package-cache/v1/`:

```
components/sparkle/<key>/Sparkle.framework, receipt.json, .complete
components/helpers/<name>/<key>/<name>,     receipt.json, .complete
stamps/<dev>-<ino>.json      # keyed by the published bundle ROOT inode (Step 6)
verified-nested              # one line: last nested_key whose full deep set passed
queries/                     # only if Step 0 qualifies bin-path or vendor-verify reuse
```

**Write discipline.** There is no lock. Every writer:
1. writes to a unique sibling `<final>.tmp.<pid>.<random>`;
2. writes `.complete` last;
3. renames it to `<final>`. If `<final>` already exists, the temp copy is discarded; trees are never merged.

Readers ignore entries without `.complete`. Single files use a temp file plus `os.replace`. Entries are immutable once published.

**Keys.** `sparkle_key` is the Sparkle source basis plus the signing-policy key. `helper_key_<name>` is `<name>`, the `$BUILD_DIR/<name>` product record and the signing-policy key.

**On a miss:**
1. Copy the unsigned input into the temp entry.
2. Sign it with the existing functions and arguments:
   - Sparkle: `sign_sparkle_framework <temp>/Sparkle.framework`;
   - helpers: `chmod +x`, then today's helper `sign_path` arguments (`:517–518`).
3. Verify it and record its inventory in `receipt.json`.
4. Run `component-commit`.

Helpers keep their basename in both the temp signing path and the final path (`<key>.tmp.…/repoprompt-mcp`, then `<key>/repoprompt-mcp`). A loose Mach-O signed without `--identifier` takes its Identifier from its basename, and a test checks this.

**On a hit:**
1. Check the entry's inventory against `receipt.json`. A mismatch evicts the entry and counts as a miss.
2. Print `CACHE HIT: <component> <key>`.

**Materialize.** On both hit and miss, `clone_tree src dst` tries `cp -c -R -p` (an APFS clone). If that fails, it runs `rm -rf dst` and then `cp -R -p`, printing `clone unavailable; copied` once.
- Never copy over a partial clone.
- Never hard-link a cache entry into a candidate; signing must not mutate cached inodes.
- This replaces the helper copy in the executable loop (`:304–308`) and the helper signs at `:517–518`.
- Release keeps signing bundle copies directly and never uses the cache.

**Pruning.** After a successful run, keep the 2 newest entries per component kind and name, and the 8 newest stamps, by mtime. Never prune an entry used in this run.

### Cut B: no-op skip and staging reuse (Step 6)

**Placement.** `plan` runs after the bin path is known and before Sentry dSYM generation (`:283`).

**Bundle-level reuse is disabled** under `IS_RELEASE`; `REPOPROMPT_ENABLE_SENTRY=1` or a truthy `REPOPROMPT_UPLOAD_SENTRY_SYMBOLS` (those side effects stay on the fresh path); cache `off`; or `cert=unresolved`.

**Stamp** (`stamps/<dev>-<ino>.json`, named for the published root inode).
- **Contents:** `version`, `inputKey`, `nestedKey`, the component keys, `builtAt`, a diagnostic-only `bundlePath`, and the inventory.
- **Inventory:** one entry per item below the root, `(rel, type, mode, size, mtime_ns, ino, symlink_target)`, computed after publish. It ignores ctime and xattrs, because launches and Gatekeeper add provenance metadata. It ignores the root's own timestamps, because a rename across parents can touch them.
- **Inode survival:** rename and swap keep the root inode through conductor activation (`activate_staged_debug_bundle`, called at `conductor.py:~8057`). An inode alone never proves reuse; the key and the inventory must match too.

| Outcome | Condition | Action |
|---|---|---|
| `noop-dest` | The destination exists, its stamp's `inputKey` matches, and the live inventory equals the stamp's | Print `PACKAGE NO-OP: <dest> unchanged since <builtAt>`. Run M on the destination, plus D per the rule. No assembly, signing or publish. Then the compatibility link and `Created:` |
| `noop-clone` | The destination is absent, and `REPOPROMPT_DEBUG_APP_REUSE_SOURCE` names an existing, different bundle whose stamp and inventory match the current `inputKey` | Print `PACKAGE REUSE: cloning <source>`. `clone_tree` it into the hidden sibling, run M there (plus D per the rule), `publish`, then `record` a new stamp from the post-publish inventory |
| `fresh` | Anything else, including a missing, corrupt, unknown-schema or mismatched stamp or inventory | Full assembly (§C′, §D1/D2). A corrupt stamp also warns and calls `forget` |

**Staging.** Add one env line, `env["REPOPROMPT_DEBUG_APP_REUSE_SOURCE"] = str(live_bundle)`, next to `conductor.py:7898` in `package_debug_app_under_heavy`. Nothing else in conductor changes.
- The clone only reads the live source, so it is safe while the app runs.
- The clone is verified before publish, because conductor's own check (`:7910–7914`) only tests that `Contents/MacOS/RepoPrompt` is executable.
- After activation the stamp follows the staged inode into the live path, so the next `run` can clone again. The previous live bundle's stamp is orphaned and later pruned.

**Failures.**
- A bundle file is edited, touched or added (for example Finder's `.DS_Store`): inventory mismatch, so `fresh`.
- The bundle is deleted and recreated: new inode, so `fresh`.
- A reused bundle fails M: loud failure, and `forget` drops both stamps. An installed bundle is never deleted just because reuse was rejected.

## Tests and fixtures

### Pinned tests

| Pin | Disposition |
|---|---|
| `test_release_tooling.py:31–70` (fast fingerprint) | Retarget to `debug_package_cache` key functions, keeping the resource- and script-sensitivity assertions. Add: rewriting the generated provenance bytes leaves the key unchanged, and changing the Git commit or the dirty flag changes it |
| `test_release_tooling.py:191–195` (codesign argv probe) | The probe splits on `sign_path(){`…`\n}\nsign_sparkle_framework(){` and on `APP_SIGN_ARGS=()`…`if (( FAST_PACKAGE_CAN_SKIP_VERIFICATION )); then`. Step 4 removes that end marker: retarget it to the new deep-verify marker with the same captured body, and keep `sign_path()` directly followed by `sign_sparkle_framework()` |
| `test_release_tooling.py:253–276` | Unchanged: the five `$framework`-relative Sparkle `sign_path` lines, `APP_SIGN_ARGS=()`, no `--deep`, `trap 'finish $?' EXIT`, `local status="$1" now total` |
| `test_release_tooling.py:1678–1702` | Keep the release `phase "Building $APP_NAME ($CONF, host-native)"` text and ordering, and the `.bundle` copy and outer-sign strings. Add: the KeyboardShortcuts patch precedes `phase "Building debug products ($CONF, host-native)"`, and that build line has no `--product` |
| `rm -rf "$APP_BUNDLE"` | Searched 2026-10-16: no `Scripts/test_*.py` pins it. Search again before Step 3 |
| `test_conductor_lifecycle.py:226–243` | Unchanged: `--fast` forwarding (`["debug", "fast"]`) and the `["build", "debugArtifact"]` lanes. `/.staging/` stays asserted (`:~6010`) |
| `Fixtures/build-metrics/v1/package-debug/case.json` | Don't edit; new traces naturally show one build segment. Before Step 1, search `swift_pipeline_metrics.py` and its tests for live three-segment assumptions |

### New tests

The new tests go in `Scripts/test_release_tooling.py` or a new `Scripts/test_debug_package_cache.py`. Command-matrix tests use fake tools, labelled as stub evidence.

- **Publish (Step 3).** Using injected rename and swap callables, cover:
  - swap success; an absent destination;
  - swap unsupported, then fallback success;
  - replacement fails and restore succeeds (exit 1, original intact);
  - replacement fails and restore fails: backup kept, `.retain` present, exit 3, and the message contains the exact backup path and `mv` command;
  - any other swap errno leaves the destination untouched;
  - symlink and non-directory destinations are rejected.

  Also add:
  - a source-contract test that `renamex_np` and `RENAME_SWAP` (`0x2`) match `conductor.py:7922–7938`, asserting the rollback deliberately differs;
  - `cleanup-stale` honours the 1-hour age and never removes a `.retain` directory;
  - a static check that `finish()` deletes `$TEMP_PARENT` only under the stated rule.
- **Keys and closure (Step 4).** Using injected stat records:
  - Each of these changes `input_key`: a product's `mtime_ns`, or its `ctime_ns` alone; a deleted or added resource; a mode change; a retargeted symlink; a file-to-symlink change; a `cert` change; a commit or dirty change.
  - A main-executable change leaves `nested_key` unchanged; a helper change changes it.
  - Unrelated `conductor.py` edits change no key.
  - The closure test scans `package_app.sh` and every helper it invokes, transitively, for `$CONTROL_PLANE_SCRIPTS_DIR/<file>`, `${CONTROL_PLANE_SCRIPTS_DIR}/<file>`, `$ROOT_DIR/<path>` and `REPOPROMPT_*` reads. Each hit must be in a key list or in `CLOSURE_EXCLUSIONS` with a non-empty reason, and every `DECLARED_DYNAMIC` entry must exist.
- **Identity and modes (Step 4).**
  - From fixture `find-identity` text: an exact SHA-1 resolves; a unique substring resolves; an ambiguous or unmatched one gives `unresolved`; ad-hoc gives `adhoc`.
  - `unresolved` and `off` each give all-miss, a forced deep set and no writes.
  - An invalid escape value exits non-zero before mutation.
  - A matching verified record plus one freshly signed component still forces D.
  - `forget` removes every named entry.
- **Component cache (Step 5).**
  - An entry without `.complete` is ignored; a colliding commit discards its temp copy.
  - Pruning keeps 2 entries per component and 8 stamps, and never removes an entry used in this run.
  - A clone failure removes the partial output before the plain-copy retry.
  - Helper paths end in `/<name>`, for temp and final paths alike.
  - Darwin-only: ad-hoc sign a copy of `/usr/bin/true` at `…tmp…/repoprompt-mcp` through the same code path, commit it, and assert `Identifier=repoprompt-mcp`.
  - The helper and Sparkle tamper tests.
- **Stamps and plan (Step 6).**
  - Stamp round-trip.
  - The inventory ignores ctime, xattrs (darwin `xattr -w`) and root timestamps after a cross-parent rename.
  - `plan` gives `noop-dest`, `noop-clone` or `fresh` under an inventory mutation, an inode change, source equal to destination, a missing source, a corrupt stamp, and Sentry enabled.
  - M runs on both no-op paths (static check).
  - `test_conductor_lifecycle.py`: `package_debug_app_under_heavy` sets `REPOPROMPT_DEBUG_APP_REUSE_SOURCE`, its target still contains `/.staging/`, and root-ticket invalidation stays unconditional.
- **Live macOS (Steps 2–6).**
  - The Step 2 signature comparison.
  - Stable-certificate and ad-hoc paths.
  - The tamper experiment.
  - Same-volume swap, and a forced fallback with failure injection.
  - No partial bundle at the destination after `kill -9` during signing.

## Measurement

**Instrumentation (Step 0).**
- `phase()` (`:15–22`) keeps its `==> ` line unchanged and adds a separate record, `[package-timing] phase="<previous>" elapsed_ms=<n> total_ms=<n>`, using `$EPOCHREALTIME` (`elapsed_ms=?` if unset).
- On exit it prints `[package-timing] summary outcome=fresh|noop-dest|noop-clone deep=ran|skipped:<reason> total_ms=<n>`.
- `$EPOCHREALTIME` is not monotonic. Totals therefore come from an outer harness with a monotonic clock, and samples with clock jumps are repeated.
- No Python process runs per marker.
- A new `Scripts/summarize_package_phases.py` emits per-phase medians, IQRs and `non_compile_ms = total − build phases`.

**Step 0 component timings.**
- `doctor.sh --quiet` (0.37 s measured).
- Each `python3` startup: `paths_same`, Info.plist, provenance, `validate_json.py` and the old fingerprint.
- `verify_sparkle_vendor.sh` and `--show-bin-path`.
- A prototype stat walk of the `input_key` inputs, including hashing `AppResources/`.
- The non-deep strict verify.
- Sparkle and product stat churn across two no-change builds (`stat -f '%i %m %c'`).
- Logical versus allocated bundle size.

**Arms.**
- **Baseline:** `git worktree add /tmp/rpce-baseline <base>`, run as `/tmp/rpce-baseline/Scripts/package_app.sh debug` with `REPOPROMPT_RELEASE_SOURCE_ROOT=<main checkout>` and `REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR=/tmp/rpce-baseline/Scripts` (`package_app.sh:6–7`), so both arms share `ROOT_DIR` and `.build`.
- **Candidate:** the working tree.
- **Destinations:** each arm gets its own destination on the same volume, so the baseline's `rm -rf` cannot invalidate the candidate's stamp. Both use the owner's usual `SIGN_IDENTITY`.

**Scenarios.**
- **S1:** no change, existing destination.
- **S2:** the same one-file app edit, toggling a trailing comment before each run. Build phases are reported but not compared; `non_compile_ms` is.
- **S3:** empty staging via `./conductor run`, alternating `REPOPROMPT_DEBUG_PACKAGE_CACHE=off` with the default.

**Protocol.**
- Discard one warm-up pair, then take 7 alternating pairs (ABAB). If Step 1 shows that alternation forces replans, switch to ABBA blocks and discard the first run after each switch.
- Keep cold-cache runs separate.
- Record `sysctl -n vm.loadavg` per run; report it, but don't filter on it.
- Report per-phase medians and IQRs, the median differences, and command counts.

**Evidence** lives in `.agent-artifacts/debug-packaging-incremental/` in the main checkout, git-excluded via `.git/info/exclude`. `step-N/` holds raw logs, `summary.json` and the `codesign` dumps; `step-0/thresholds.md` holds the bin-path, vendor-verify and Sparkle-basis outcomes. Every item is labelled live, stub or source inspection. Raw evidence never goes into this plan.

## Steps

Order: 0 → 1 → 2 → 3 → 4 → 5 → 6 → 7. Steps 1 and 2 are independent of the rest. 3 precedes 4–6, 4 precedes 5, 5 precedes 6, and 7 is last. Each step is one revertible commit. After reverting Step 4 or later, run `rm -rf .build/debug/package-cache`.

### Step 0 — Instrumentation and baseline

Step 0 — done | rounds 0/2 | open: none | downgraded: none | assumed: single-arm baseline in this worktree; script totals exclude conductor waits (step-0/findings.md) | deferred: pre-existing release-tooling lint-scope assertion reproduced at HEAD; actual run/activation per owner Decision; evidence: step-0/thresholds.md, step-0/reviews/disposition.md

- **Change:** add the `[package-timing]` records and the exit summary; add `summarize_package_phases.py`; add a test that `swift_pipeline_metrics.py` ignores `[package-timing]` lines; no other behaviour change.
- **Validation:** `python3 -m unittest Scripts/test_release_tooling.py` and the metrics tests pass; one debug package succeeds; the S1–S3 baselines and every component timing are recorded.
- **Done when:** the baseline and `thresholds.md` are in evidence, and the advisory targets have been re-derived.

### Step 1 — Single debug SwiftPM build

Step 1 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:

- **Change:** add the debug-only `Building debug products` phase with no `--product`; release keeps its three phases; add the heading and ordering tests; add the bin-path cache only if Step 0 qualified it.
- **Validation:** `swift package describe --type json` shows no extra root targets get built; five alternations of `./conductor swift-build --product RepoPrompt` with `./conductor build` show no replan above 3 s; the release-branch diff is empty; S1 and S2 are measured.
- **Done when:** one real debug build produces all three products, and the build phases sum lower than the baseline.

### Step 2 — Drop the debug main-executable sign

Step 2 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:

- **Change:** gate `:519` on `IS_RELEASE`, and add a static test for the gate.
- **Validation:** run the live comparison against the baseline worktree on identical inputs; deep verify passes; the app launches through `./conductor run`.
- **Done when:** every compared field is equal. Otherwise the step is reverted and the diff recorded under `deferred:`.

### Step 3 — Fresh sibling assembly and publish

Step 3 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:

- **Change:** add `debug_package_cache.py` with only `publish` and `cleanup-stale`; add the `PACKAGE_DEST`/`TEMP_PARENT` handling; make `rm -rf "$APP_BUNDLE"` release-only; change `finish()` to the new rule; move compatibility-link updates to after publish; add the publish tests.
- **Validation:** repeat the `rm -rf` pin search; the fault-injection tests pass, including a failed restore followed by cleanup; live: killing packaging during signing leaves the existing app launchable; identity, smoke and verify pass inside the hidden parent; `conductor run` still activates its staged bundle.
- **Done when:** a failed package leaves the destination untouched, and every publish failure path is tested.

### Step 4 — Keys, plan and proportional verification behind `fast`

Step 4 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:

- **Change:** add `resolve-identity`, `plan`, `record` and `forget`, and the closure lists; merge the `find-identity` calls; add the non-deep strict verify to M; put D behind the deep-set rule, with proportional mode from `fast`; parse `REPOPROMPT_DEBUG_PACKAGE_CACHE`; add `forget` to `finish()`; retire the old fingerprint (§F) and retarget the pins; add the key, closure, identity and mode tests; add the vendor receipt only if Step 0 qualified it.
- **Validation:** all tests pass; the live tamper experiment is recorded, and the per-component remedy is specified if the outer verify misses the flip; live: `off` runs D and writes nothing; an ambiguous identity substring warns, runs D and writes no receipt; a corrupted verified record runs D.
- **Accepted interim regression:** until Step 5, a no-change `fast` build loses the old exact-match skip.
- **Done when:** the new keys replace whole-bundle hashing, and non-`fast` runs still run D every time.

### Step 5 — Signed Sparkle and helper caches

Step 5 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:

- **Change:** add `component-lookup`/`component-commit`, `clone_tree` and pruning; route Sparkle and the helpers through the cache, with the Sparkle basis from Step 0; add per-component verification if Step 4 requires it; add the cache tests, including the darwin Identifier test.
- **Validation:** Identifier and CDHash match the Step 4 output for both helpers and Sparkle; the first run runs D; a second edit-build shows `CACHE HIT` for all three components and skips D under `fast`; a helper rebuild forces D; a cross-volume `REPOPROMPT_DEBUG_APP_BUNDLE` (a mounted disk image) uses the copy fallback; S2 is measured.
- **Done when:** an app-only edit re-signs only the main bundle.

### Step 6 — No-op skip and staging reuse

Step 6 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:

- **Change:** add `inventory`, the stamps and the three outcomes; add the `conductor.py` env line; add the plan, stamp and lifecycle tests.
- **Validation:** S1 into `/Applications` hits `noop-dest`, prints `Created:` and refreshes the compatibility link; after launching the app, a no-change build is still `noop-dest`; S3 hits `noop-clone`, publishes, activates and launches, and a second `run` clones again (record the root inode before and after activation); `touch` on a bundle file, deleting the destination, or enabling Sentry gives `fresh`; ticket invalidation is unchanged.
- **Done when:** S1 and S3 are measured, and every outcome is covered by tests.

### Step 7 — Docs and the default flip

Step 7 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:

- **Change:** fix `docs/context/workflows/development.md:85`, which names `.build/debug/RepoPrompt.app` (only the compatibility link) as the destination; document the real destination, the outcomes, cache location and pruning, the escape variable and recovery commands including `.retain` recovery, assembly-time provenance, and that direct concurrent runs are unsupported; if Q1 is yes, make proportional mode the default and keep `fast` as an accepted alias.
- **Validation:** the affected suites pass, and the `--fast` pins still hold; `off` runs every check; default `conductor run` skips D when `nested_key` is unchanged; the final S1–S3 measurements are taken.
- **Done when:** the docs match the behaviour, and the evidence records the gains and the rollout choice.

## Risks and recovery

| Risk | Severity | Detection and recovery |
|---|---|---|
| Publish deletes the backup after a failed restore | P1 if implemented wrongly | Prevented by design: the backup and `.retain` are kept, exit 3, the exact `mv` is printed, and cleanup never removes it. Covered by failure-injection tests |
| Fallback publish leaves the destination briefly absent | Accepted | Not crash-atomic, but never partial. Recover from the printed backup path |
| A stale or corrupt component cache gives a wrongly signed nested component | P2 | The inventory check, M or per-component verify fails loudly, and `forget` evicts the entry |
| Skipping D misses nested breakage | P2 | Needs an unchanged `nested_key` plus an M miss. The Step 4 experiment closes the known gap |
| A key misses an input (closure gap) | P2 | The closure test fails on any unlisted reference; dynamic inputs must be declared |
| A false hit on a product stat tuple | P3 | Unrealistic for linker output; out of scope |
| The combined build compiles extra targets or replans | P2 | Step 1 checks; revert Step 1 |
| Release script text changes | P1 if it happens | Pinned tests and the empty release diff; revert |
| Concurrent direct runs | Unsupported (P2, deferred) | Unique temp paths and atomic commits. Worst case: extra misses or a loud verify failure |

**Recovery.**
- `REPOPROMPT_DEBUG_PACKAGE_CACHE=off ./conductor build` bypasses all reuse and runs every check.
- For persistent corruption, run `rm -rf .build/debug/package-cache` while no packaging job is running. It affects speed only.
- After a failed restore, run the printed `mv` command, quitting the app first if needed.
- Rolling back to the old scripts ignores the new receipts, and the next package rebuilds normally.

## Decisions

- 2026-10-16: For Step 0, the owner approved fresh non-live staging package measurements instead of repeated `conductor run`; actual run/activation checks remain for the later behavior-changing steps.

## Owner questions

These are recommendations only; the owner has not decided anything yet.

- **Q1. Should proportional verification become the debug default in Step 7?** *Recommend yes,* with `REPOPROMPT_DEBUG_PACKAGE_CACHE=off` as the single escape and `fast` kept as an alias. D is skipped only when its exact inputs are unchanged and no nested component was freshly signed. `conductor run` never passes `fast`, so staging never benefits without the flip. Until this is answered, Steps 4–6 keep proportional mode behind `fast`.
- **Q2. Should a `build-metrics/v2/package-debug` fixture be recorded after Step 1?** *Recommend only if parser coverage needs it.* v1 stays untouched either way.
