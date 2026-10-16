#!/usr/bin/env python3
"""Focused tests for Scripts/verify_build_lane_flags.py (optimized-diagnostics lane spec §5).

Fixtures are inline and mirror the SwiftPM llbuild manifest dialect observed in
real `.build/debug.yaml` and `release.yaml` plans: column-0 sections,
`  "<key>":` command blocks, single-line JSON `inputs`/`args`, sources passed
through `@<Module>.build/sources`, and link commands that read
`@<Product>.product/Objects.LinkFileList`.
"""

from __future__ import annotations

import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import verify_build_lane_flags as vbl  # noqa: E402

ROOT = "/repo"
SWIFTC = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SDK = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.4.sdk"
FIRST_PARTY = sorted(vbl.FIRST_PARTY_MODULES)
THIRD_PARTY = ["Logging", "NIOCore", "KeyboardShortcuts", "MarkdownUI"]
LANE_FIRST_PARTY_DEFINES = ["-DDEBUG", "-DRPCE_OPTIMIZED_DIAGNOSTICS"]


def build_dir(conf: str) -> str:
    return f"{ROOT}/.build/arm64-apple-macosx/{conf}"


def compile_args(
    module: str, *, conf: str, mode_flags: list[str], defines: list[str], config_defines: list[str] | None = None
) -> list[str]:
    """Real argv order: SwiftPM's configuration defines follow -DSWIFT_PACKAGE (debug adds -DDEBUG there);
    manifest `.define(...)` settings follow -swift-version."""
    out = build_dir(conf)
    if config_defines is None:
        config_defines = ["-DDEBUG"] if conf == "debug" else []
    return [
        SWIFTC,
        "-module-name", module,
        "-emit-dependencies", "-emit-module",
        "-emit-module-path", f"{out}/Modules/{module}.swiftmodule",
        "-output-file-map", f"{out}/{module}.build/output-file-map.json",
        "-parse-as-library",
        *(["-whole-module-optimization", "-num-threads", "28"] if conf == "release" else ["-incremental"]),
        "-c", f"@{out}/{module}.build/sources",
        "-I", f"{out}/Modules",
        "-target", "arm64-apple-macosx14.0",
        *mode_flags,
        "-j28", "-DSWIFT_PACKAGE", *config_defines, "-DSWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE",
        "-module-cache-path", f"{out}/ModuleCache",
        "-parseable-output", "-parse-as-library",
        "-emit-objc-header", "-emit-objc-header-path", f"{out}/{module}.build/include/{module}-Swift.h",
        "-swift-version", "5", *defines,
        "-sdk", SDK, "-g",
        "-Xcc", "-isysroot", "-Xcc", SDK, "-Xcc", "-fPIC", "-Xcc", "-g",
        "-package-name", module.lower(),
    ]


def release_mode() -> list[str]:
    return ["-whole-module-optimization", "-num-threads", "28", "-serialize-diagnostics", "-O"]


def debug_mode() -> list[str]:
    return ["-incremental", "-enable-batch-mode", "-serialize-diagnostics", "-Onone", "-enable-testing"]


def compile_block(module: str, args: list[str], *, conf: str = "release", key: str | None = None) -> str:
    out = build_dir(conf)
    key = key or f"C.{module}-arm64-apple-macosx-{conf}.module"
    sources = [f"{ROOT}/Sources/{module}/A.swift", f"{ROOT}/Sources/{module}/B.swift"]
    return "\n".join(
        [
            f"  {json.dumps(key)}:",
            "    tool: shell",
            f"    inputs: {json.dumps(sources + [f'{out}/{module}.build/sources'], separators=(',', ':'))}",
            f"    outputs: {json.dumps([f'{out}/{module}.build/A.swift.o', f'{out}/Modules/{module}.swiftmodule'], separators=(',', ':'))}",
            f"    description: \"Compiling Swift Module '{module}' (2 sources)\"",
            f"    args: {json.dumps(args, separators=(',', ':'))}",
            "",
        ]
    )


def link_block(module: str, product: str, *, conf: str = "release", bundle: bool = False) -> str:
    out = build_dir(conf)
    args = [
        SWIFTC, "-framework", "Sparkle", "-lc++", "-F", out, "-L", out,
        "-o", f"{out}/{product}",
        "-module-name", module,
        "-Xlinker", "-no_warn_duplicate_libraries",
        *(["-Xlinker", "-bundle"] if bundle else ["-emit-executable"]),
        "-Xlinker", "-rpath", "-Xlinker", "@loader_path",
        f"@{out}/{product}.product/Objects.LinkFileList",
        "-target", "arm64-apple-macosx14.0", "-sdk", SDK, "-g",
    ]
    suffix = "test" if bundle else "exe"
    return "\n".join(
        [
            f"  \"C.{product}-arm64-apple-macosx-{conf}.{suffix}\":",
            "    tool: shell",
            f"    inputs: [\"{out}/{module}.build/A.swift.o\"]",
            f"    outputs: [\"{out}/{product}\"]",
            f"    description: \"Linking ./.build/arm64-apple-macosx/{conf}/{product}\"",
            f"    args: {json.dumps(args, separators=(',', ':'))}",
            "",
        ]
    )


def other_blocks(conf: str = "release") -> str:
    out = build_dir(conf)
    return "\n".join(
        [
            f"  \"{out}/Logging.build/sources\":",
            "    tool: write-auxiliary-file",
            f"    inputs: [\"<sources-file-list>\",\"{ROOT}/.build/checkouts/swift-log/Sources/Logging/Logging.swift\"]",
            f"    outputs: [\"{out}/Logging.build/sources\"]",
            f"    description: \"Write auxiliary file {out}/Logging.build/sources\"",
            "",
            f"  \"{out}/CNIOLinux.build/shim.c.o\":",
            "    tool: clang",
            f"    inputs: [\"{ROOT}/.build/checkouts/swift-nio/Sources/CNIOLinux/shim.c\"]",
            f"    outputs: [\"{out}/CNIOLinux.build/shim.c.o\"]",
            "    description: \"Compiling CNIOLinux shim.c\"",
            "    args: [\"/usr/bin/clang\",\"-DDEBUG=1\",\"-c\",\"shim.c\"]",
            f"    deps: \"{out}/CNIOLinux.build/shim.c.d\"",
            "",
            "  \"C.RepoPrompt-arm64-apple-macosx-release.exe-entitlements\":",
            "    tool: shell",
            f"    inputs: [\"{out}/RepoPrompt\"]",
            f"    outputs: [\"{out}/RepoPrompt-entitlement.plist\"]",
            "    description: \"Applying debug entitlements to ./.build/arm64-apple-macosx/release/RepoPrompt\"",
            f"    args: [\"codesign\",\"--force\",\"--sign\",\"-\",\"{out}/RepoPrompt\"]",
            "",
            "  \"<RepoPrompt-arm64-apple-macosx-release.module>\":",
            "    tool: phony",
            "    inputs: []",
            "    outputs: [\"<RepoPrompt-arm64-apple-macosx-release.module>\"]",
            "",
        ]
    )


def manifest(blocks: list[str], conf: str = "release") -> str:
    return "\n".join(
        [
            "client:",
            "  name: basic",
            "  file-system: device-agnostic",
            "tools: {}",
            "targets:",
            f"  \"RepoPrompt-arm64-apple-macosx-{conf}.module\": [\"<RepoPrompt-arm64-apple-macosx-{conf}.module>\"]",
            "default: \"main\"",
            "nodes:",
            f"  \"{ROOT}/Sources/RepoPrompt/\":",
            "    is-directory-structure: true",
            "    content-exclusion-patterns: [\".git\",\".build\"]",
            "commands:",
            other_blocks(conf),
            *blocks,
        ]
    )


def lane_first_party(module: str, *, defines: list[str] | None = None, mode: list[str] | None = None) -> str:
    return compile_block(
        module,
        compile_args(
            module,
            conf="release",
            mode_flags=release_mode() if mode is None else mode,
            defines=LANE_FIRST_PARTY_DEFINES if defines is None else defines,
        ),
    )


def lane_third_party(module: str, *, defines: list[str] | None = None) -> str:
    return compile_block(module, compile_args(module, conf="release", mode_flags=release_mode(), defines=defines or []))


def lane_test(module: str, *, defines: list[str] | None = None) -> str:
    mode = release_mode() + ["-enable-testing"]
    return compile_block(module, compile_args(module, conf="release", mode_flags=mode, defines=defines or []))


def lane_links() -> list[str]:
    return [
        link_block("RepoPrompt", "RepoPrompt"),
        link_block("repoprompt_mcp", "repoprompt-mcp"),
        link_block("RepoPromptCEPackageTests", "RepoPromptCEPackageTests.xctest/Contents/MacOS/RepoPromptCEPackageTests", bundle=True),
    ]


def lane_manifest(*, replace: dict[str, str] | None = None, drop: tuple[str, ...] = (), extra: tuple[str, ...] = ()) -> str:
    replace = replace or {}
    blocks = [replace.get(module, lane_first_party(module)) for module in FIRST_PARTY if module not in drop]
    blocks += [replace.get(module, lane_third_party(module)) for module in THIRD_PARTY if module not in drop]
    blocks += lane_links()
    blocks += list(extra)
    return manifest(blocks)


def run_verifier(text: str) -> tuple[int, str, str]:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "release.yaml"
        path.write_text(text, encoding="utf-8")
        stdout, stderr = io.StringIO(), io.StringIO()
        code = vbl.run(str(path), stdout=stdout, stderr=stderr)
    return code, stdout.getvalue(), stderr.getvalue()


class VerifierPassTests(unittest.TestCase):
    def test_lane_plan_passes(self) -> None:
        code, out, err = run_verifier(lane_manifest())
        self.assertEqual(code, 0, err)
        self.assertEqual(err, "")
        self.assertIn("13 modules of 13 expected, 13 compile commands, 0 failing: OK", out)
        self.assertIn("third-party (no DEBUG, no lane marker): 4 modules, 4 compile commands, 0 failing: OK", out)
        self.assertIn("link commands ignored: 3", out)
        self.assertTrue(out.rstrip().endswith("result: PASS"))

    def test_dormant_test_modules_are_exempt(self) -> None:
        text = lane_manifest(
            extra=(
                lane_test("RepoPromptTests"),
                lane_test("RepoPromptCEPackageTests"),
                lane_test("NIOCoreTests"),
            )
        )
        code, out, err = run_verifier(text)
        self.assertEqual(code, 0, err)
        self.assertIn("test modules (no DEBUG, no lane marker): 3 modules, 3 compile commands, 0 failing: OK", out)

    def test_wmo_alias_is_accepted(self) -> None:
        args = [
            "-wmo" if token == "-whole-module-optimization" else token
            for token in compile_args("RepoPromptUI", conf="release", mode_flags=release_mode(), defines=LANE_FIRST_PARTY_DEFINES)
        ]
        self.assertNotIn("-whole-module-optimization", args)
        code, _, err = run_verifier(lane_manifest(replace={"RepoPromptUI": compile_block("RepoPromptUI", args)}))
        self.assertEqual(code, 0, err)

    def test_split_define_spelling_is_accepted(self) -> None:
        spaced = lane_first_party("RepoPromptShared", defines=["-D", "DEBUG", "-D", "RPCE_OPTIMIZED_DIAGNOSTICS"])
        self.assertIn('"-D","DEBUG"', spaced)
        code, _, err = run_verifier(lane_manifest(replace={"RepoPromptShared": spaced}))
        self.assertEqual(code, 0, err)

    def test_link_command_for_first_party_module_is_ignored(self) -> None:
        # The executable's link command carries -module-name RepoPrompt but no defines and no -O.
        summary = vbl.parse_build_plan(lane_manifest())
        self.assertEqual(summary.ignored_links, 3)
        self.assertEqual(sum(1 for command in summary.compiles if command.module == "RepoPrompt"), 1)
        self.assertNotIn("RepoPromptCEPackageTests", {command.module for command in summary.compiles})

    def test_xcc_values_do_not_count_as_swift_flags(self) -> None:
        third = compile_block(
            "Logging",
            compile_args("Logging", conf="release", mode_flags=release_mode() + ["-Xcc", "-DDEBUG", "-Xcc", "-Onone"], defines=[]),
        )
        code, _, err = run_verifier(lane_manifest(replace={"Logging": third}))
        self.assertEqual(code, 0, err)


class VerifierFailureTests(unittest.TestCase):
    def assertFails(self, text: str, *needles: str) -> str:
        code, out, err = run_verifier(text)
        self.assertEqual(code, 1, out)
        self.assertTrue(out.rstrip().endswith("result: FAIL"), out)
        for needle in needles:
            self.assertIn(needle, err)
        return err

    def test_one_of_two_compile_commands_without_debug_fails(self) -> None:
        good = lane_first_party("RepoPromptApp")
        bad = compile_block(
            "RepoPromptApp",
            compile_args("RepoPromptApp", conf="release", mode_flags=release_mode(), defines=["-DRPCE_OPTIMIZED_DIAGNOSTICS"]),
            key="C.RepoPromptApp-arm64-apple-macosx-release.module-emit",
        )
        err = self.assertFails(
            lane_manifest(replace={"RepoPromptApp": good + "\n" + bad}),
            "FAIL first-party RepoPromptApp [C.RepoPromptApp-arm64-apple-macosx-release.module-emit]: missing -DDEBUG",
        )
        self.assertNotIn("[C.RepoPromptApp-arm64-apple-macosx-release.module]", err)

    def test_missing_core_module_fails(self) -> None:
        self.assertFails(
            lane_manifest(drop=("RepoPromptShared",)),
            "FAIL first-party RepoPromptShared: no Swift compile command in the build plan",
        )

    def test_link_only_first_party_module_counts_as_missing(self) -> None:
        self.assertFails(
            lane_manifest(drop=("RepoPrompt",)),
            "FAIL first-party RepoPrompt: no Swift compile command in the build plan",
        )

    def test_debug_in_third_party_module_fails(self) -> None:
        for defines in (["-DDEBUG"], ["-D", "DEBUG"]):
            with self.subTest(defines=defines):
                self.assertFails(
                    lane_manifest(replace={"NIOCore": lane_third_party("NIOCore", defines=defines)}),
                    "FAIL third-party NIOCore [C.NIOCore-arm64-apple-macosx-release.module]: third-party module has -DDEBUG",
                )

    def test_lane_marker_in_third_party_module_fails(self) -> None:
        self.assertFails(
            lane_manifest(replace={"Logging": lane_third_party("Logging", defines=["-DRPCE_OPTIMIZED_DIAGNOSTICS"])}),
            "third-party module has -DRPCE_OPTIMIZED_DIAGNOSTICS",
        )

    def test_lane_marker_on_test_module_fails(self) -> None:
        self.assertFails(
            lane_manifest(extra=(lane_test("RepoPromptTests", defines=["-DRPCE_OPTIMIZED_DIAGNOSTICS"]),)),
            "FAIL test RepoPromptTests [C.RepoPromptTests-arm64-apple-macosx-release.module]: "
            "test module has -DRPCE_OPTIMIZED_DIAGNOSTICS",
        )

    def test_debug_on_test_module_fails(self) -> None:
        for module in ("RepoPromptTests", "NIOCoreTests"):
            with self.subTest(module=module):
                self.assertFails(
                    lane_manifest(extra=(lane_test(module, defines=["-DDEBUG"]),)),
                    f"FAIL test {module} [C.{module}-arm64-apple-macosx-release.module]: test module has -DDEBUG",
                )

    def test_onone_fails(self) -> None:
        with_both = lane_first_party("RepoPromptUI", mode=release_mode() + ["-Onone"])
        onone_only = lane_first_party("RepoPromptUI", mode=["-whole-module-optimization", "-Onone"])
        self.assertFails(lane_manifest(replace={"RepoPromptUI": with_both}), "RepoPromptUI", "has -Onone")
        self.assertFails(lane_manifest(replace={"RepoPromptUI": onone_only}), "has -Onone", "missing -O")

    def test_other_optimization_levels_fail(self) -> None:
        osize = lane_first_party("RepoPromptUI", mode=["-whole-module-optimization", "-Osize"])
        self.assertFails(lane_manifest(replace={"RepoPromptUI": osize}), "has -Osize", "missing -O")

    def test_enable_testing_on_first_party_fails(self) -> None:
        self.assertFails(
            lane_manifest(replace={"RepoPromptMCPCore": lane_first_party("RepoPromptMCPCore", mode=release_mode() + ["-enable-testing"])}),
            "FAIL first-party RepoPromptMCPCore [C.RepoPromptMCPCore-arm64-apple-macosx-release.module]: has -enable-testing",
        )

    def test_no_whole_module_optimization_fails(self) -> None:
        for flag in ("-no-whole-module-optimization", "-no-wmo"):
            with self.subTest(flag=flag):
                self.assertFails(
                    lane_manifest(replace={"RepoPromptApp": lane_first_party("RepoPromptApp", mode=release_mode() + [flag])}),
                    "FAIL first-party RepoPromptApp [C.RepoPromptApp-arm64-apple-macosx-release.module]: "
                    "has -no-whole-module-optimization",
                )

    def test_missing_whole_module_optimization_fails(self) -> None:
        args = [token for token in compile_args("RepoPromptPlatform", conf="release", mode_flags=["-O"], defines=LANE_FIRST_PARTY_DEFINES)
                if token != "-whole-module-optimization"]
        self.assertFails(
            lane_manifest(replace={"RepoPromptPlatform": compile_block("RepoPromptPlatform", args)}),
            "missing -whole-module-optimization",
        )

    def test_missing_defines_on_first_party_fail(self) -> None:
        self.assertFails(
            lane_manifest(replace={"RepoPromptClaudeCompatibleProvider": lane_first_party("RepoPromptClaudeCompatibleProvider", defines=["-DDEBUG"])}),
            "RepoPromptClaudeCompatibleProvider",
            "missing -DRPCE_OPTIMIZED_DIAGNOSTICS",
        )
        self.assertFails(
            lane_manifest(replace={"RepoPromptGateway": lane_first_party("RepoPromptGateway", defines=["-Xcc", "-DDEBUG", "-DRPCE_OPTIMIZED_DIAGNOSTICS"])}),
            "FAIL first-party RepoPromptGateway [C.RepoPromptGateway-arm64-apple-macosx-release.module]: missing -DDEBUG",
        )

    def test_unknown_repoprompt_module_fails(self) -> None:
        self.assertFails(
            lane_manifest(extra=(lane_first_party("RepoPromptNewTarget"),)),
            "FAIL unknown RepoPromptNewTarget [C.RepoPromptNewTarget-arm64-apple-macosx-release.module]: "
            "unclassified RepoPrompt* module",
        )

    def test_default_debug_plan_is_rejected(self) -> None:
        blocks = [
            compile_block(module, compile_args(module, conf="debug", mode_flags=debug_mode(), defines=["-DDEBUG"]), conf="debug")
            for module in FIRST_PARTY
        ]
        blocks += [
            compile_block(module, compile_args(module, conf="debug", mode_flags=debug_mode(), defines=[]), conf="debug")
            for module in THIRD_PARTY
        ]
        blocks.append(link_block("RepoPrompt", "RepoPrompt", conf="debug"))
        err = self.assertFails(
            manifest(blocks, conf="debug"),
            "missing -DRPCE_OPTIMIZED_DIAGNOSTICS",
            "has -Onone",
            "has -enable-testing",
            "missing -whole-module-optimization",
            "third-party module has -DDEBUG",
        )
        self.assertNotIn("missing -DDEBUG", err)

    def test_plain_release_plan_is_rejected(self) -> None:
        blocks = [lane_first_party(module, defines=[]) for module in FIRST_PARTY] + [lane_third_party(m) for m in THIRD_PARTY]
        err = self.assertFails(manifest(blocks), "missing -DDEBUG", "missing -DRPCE_OPTIMIZED_DIAGNOSTICS")
        self.assertEqual(err.count("missing -DDEBUG"), len(FIRST_PARTY))


class MalformedPlanTests(unittest.TestCase):
    def assertMalformed(self, text: str, needle: str) -> None:
        code, out, err = run_verifier(text)
        self.assertEqual(code, 1, out)
        self.assertIn("result: FAIL (malformed build plan)", out)
        self.assertIn(needle, err)

    def test_malformed_inputs_fail_closed(self) -> None:
        good = lane_manifest()
        shared_args = json.dumps(
            compile_args("RepoPromptShared", conf="release", mode_flags=release_mode(), defines=LANE_FIRST_PARTY_DEFINES),
            separators=(",", ":"),
        )
        cases = {
            "empty file": ("", "expected exactly one column-0 'commands:' section, found 0"),
            "no commands section": (good.replace("commands:\n", "kommands:\n"), "found 0"),
            "two commands sections": (good + "\ncommands:\n", "found 2"),
            "truncated args JSON": (good.replace(shared_args, shared_args[:-40]), "unreadable args"),
            "args not strings": (good.replace(shared_args, "[1,2]"), "args is not an array of strings"),
            "stray line": (good.replace("    tool: phony\n", "    tool: phony\n  stray\n"), "unexpected line in commands section"),
            "multi-line field": (good.replace("    tool: phony\n", "    tool: phony\n      continued\n"), "unexpected line"),
            "field before block": (good.replace("commands:\n", "commands:\n    tool: shell\n"), "field outside a command block"),
            "duplicate key": (good + lane_first_party("RepoPromptShared"), "duplicate command key"),
            "duplicate field": (good.replace("    tool: phony\n", "    tool: phony\n    tool: phony\n"), "duplicate field 'tool'"),
            "missing tool": (good.replace("    tool: phony\n", ""), "missing tool"),
            "legacy swift-compiler tool": (good.replace("    tool: phony\n", "    tool: swift-compiler\n"), "unsupported swift-compiler tool"),
            "no compile commands": (manifest(lane_links()), "no Swift compile commands found"),
            "top-level line after commands": (good + "trailer:\n" + lane_third_party("Atomics"), "unexpected top-level line after commands section"),
            "broken quoted tool": (good.replace("    tool: phony\n", '    tool: "shell\n'), "unreadable tool"),
        }
        for name, (text, needle) in cases.items():
            with self.subTest(name):
                self.assertMalformed(text, needle)

    def test_module_name_without_value_fails_closed(self) -> None:
        args = [SWIFTC, "-c", f"@{build_dir('release')}/X.build/sources", "-O", "-module-name"]
        self.assertMalformed(lane_manifest(extra=(compile_block("X", args),)), "-module-name without a value")

    def test_swift_sources_without_module_name_fail_closed(self) -> None:
        args = [SWIFTC, "-c", f"@{build_dir('release')}/Y.build/sources", "-O", "-DDEBUG"]
        self.assertMalformed(
            lane_manifest(extra=(compile_block("Y", args),)),
            "swiftc with Swift sources but no -module-name",
        )

    def test_unclassified_swiftc_command_fails_closed(self) -> None:
        # Swift sources but no -c: neither a compile nor a link.
        args = [token for token in compile_args("RepoPromptUI", conf="release", mode_flags=release_mode(), defines=LANE_FIRST_PARTY_DEFINES)
                if token != "-c"]
        self.assertMalformed(
            lane_manifest(replace={"RepoPromptUI": compile_block("RepoPromptUI", args)}),
            "unclassified swiftc command for module 'RepoPromptUI'",
        )

    def test_unexpected_argv_response_file_fails_closed(self) -> None:
        args = compile_args("RepoPromptUI", conf="release", mode_flags=release_mode(), defines=LANE_FIRST_PARTY_DEFINES)
        args.append(f"@{build_dir('release')}/RepoPromptUI.build/flags.resp")
        self.assertMalformed(
            lane_manifest(replace={"RepoPromptUI": compile_block("RepoPromptUI", args)}),
            "may hide flags",
        )


class CommandLineTests(unittest.TestCase):
    SCRIPT = str(SCRIPT_DIR / "verify_build_lane_flags.py")

    def invoke(self, *argv: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, self.SCRIPT, *argv], capture_output=True, text=True, timeout=60)

    def test_exit_codes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            passing = Path(tmp) / "pass.yaml"
            passing.write_text(lane_manifest(), encoding="utf-8")
            failing = Path(tmp) / "fail.yaml"
            failing.write_text(lane_manifest(drop=("RepoPromptMCPClientKit",)), encoding="utf-8")
            malformed = Path(tmp) / "malformed.yaml"
            malformed.write_text("commands:\n  junk\n", encoding="utf-8")
            not_utf8 = Path(tmp) / "binary.yaml"
            not_utf8.write_bytes(b"commands:\n\xff\xfe\n")

            result = self.invoke("--build-yaml", str(passing))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len([line for line in result.stdout.splitlines() if ": " in line and "modules" in line]), 4)
            self.assertIn("result: PASS", result.stdout)

            result = self.invoke("--build-yaml", str(failing))
            self.assertEqual(result.returncode, 1)
            self.assertIn("RepoPromptMCPClientKit: no Swift compile command", result.stderr)

            for path in (malformed, not_utf8, Path(tmp) / "missing.yaml"):
                with self.subTest(path=path.name):
                    result = self.invoke("--build-yaml", str(path))
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("result: FAIL", result.stdout)

        result = self.invoke()
        self.assertEqual(result.returncode, 2)
        self.assertIn("--build-yaml", result.stderr)

    def test_verifier_does_not_modify_its_input(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "release.yaml"
            path.write_text(lane_manifest(), encoding="utf-8")
            before = path.stat()
            self.invoke("--build-yaml", str(path))
            after = path.stat()
            self.assertEqual((before.st_mtime_ns, before.st_size), (after.st_mtime_ns, after.st_size))
            self.assertEqual(sorted(p.name for p in Path(tmp).iterdir()), ["release.yaml"])


if __name__ == "__main__":
    unittest.main()
