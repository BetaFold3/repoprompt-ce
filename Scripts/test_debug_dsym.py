#!/usr/bin/env python3
"""Focused tests for Scripts/debug_dsym.py (build-pipeline plan Step 10, lean scope)."""

from __future__ import annotations

import contextlib
import io
import os
import signal
import struct
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import debug_dsym as dd  # noqa: E402

ARM64 = 0x0100000C
X86_64 = 0x01000007


def thin(uuid: bytes, cputype: int = ARM64, *, with_uuid: bool = True) -> bytes:
    command = struct.pack("<II", 0x1B, 24) + uuid if with_uuid else struct.pack("<II", 0x2, 8)
    return struct.pack("<IiiIIIII", 0xFEEDFACF, cputype, 0, 2, 1, len(command), 0, 0) + command


def fat(*slices: bytes) -> bytes:
    header = struct.pack(">II", 0xCAFEBABE, len(slices))
    offset = 4096
    table = b""
    body = b""
    for index, (cputype, data) in enumerate(zip((ARM64, X86_64), slices)):
        table += struct.pack(">iiIII", cputype, 0, offset + len(body), len(data), 12)
        body += data + b"\0" * (4096 - len(data) % 4096)
    return (header + table).ljust(offset, b"\0") + body


def uuid_text(raw: bytes) -> str:
    text = raw.hex().upper()
    return f"{text[:8]}-{text[8:12]}-{text[12:16]}-{text[16:20]}-{text[20:]}"


OLD = bytes(range(16, 32))
NEW = bytes(range(16))

FAKE_DSYMUTIL = textwrap.dedent('''\
    import os, shutil, sys
    from pathlib import Path
    exe, out = Path(sys.argv[1]), Path(sys.argv[3])
    mode = os.environ.get("FAKE_DSYMUTIL_MODE", "ok")
    if mode == "fail":
        print("error: fake failure")
        sys.exit(3)
    if mode == "pcm":
        for index in range(3):
            print(f"warning: /tmp/ModuleCache/M{index}.pcm: No such file or directory")
    dwarf = out / "Contents" / "Resources" / "DWARF"
    dwarf.mkdir(parents=True, exist_ok=True)
    data = exe.read_bytes()
    if mode == "mismatch":
        data = data[:-16] + bytes(16)
    (dwarf / exe.name).write_bytes(data)
    if mode == "change-exe":
        with exe.open("ab") as handle:
            handle.write(b"\\0")
''')


class PolicyTests(unittest.TestCase):
    def decide(self, argv, requested=None, sentry=None) -> dd.PolicyDecision:
        return dd.classify_policy(argv, requested, sentry)

    def test_unset_and_off_are_identical_debug_skip(self) -> None:
        for argv in (["build", "--product", "RepoPrompt"], ["test", "list", "--skip-build"], ["build", "--show-bin-path"],
                     ["build", "-c", "debug"], ["build", "--configuration=debug"]):
            with self.subTest(argv=argv):
                unset, off = self.decide(argv), self.decide(argv, "off")
                self.assertEqual(unset, off)
                self.assertEqual((unset.effective, unset.reason), ("off", "debug_skip"))

    def test_full_environment_cases(self) -> None:
        cases = (
            (["build"], "on", None, "requested_on"),
            (["build", "-c", "release"], None, None, "configuration_release"),
            (["build", "--configuration", "release"], "off", None, "configuration_release"),
            (["build", "-c", "debug", "-c", "release"], None, None, "configuration_conflicting"),
            (["build", "-c", "profile"], None, None, "configuration_unknown"),
            (["build", "--brand-new-option", "x"], None, None, "configuration_unknown"),
            (["build", "-c"], None, None, "configuration_malformed"),
            (["build", "-c", "--product"], None, None, "configuration_malformed"),
            (["build"], None, "1", "sentry"),
            (["build"], "off", "0", "sentry"),
        )
        for argv, requested, sentry, reason in cases:
            with self.subTest(argv=argv, requested=requested, sentry=sentry):
                decision = self.decide(argv, requested, sentry)
                self.assertEqual((decision.effective, decision.reason), ("on", reason))

    def test_empty_sentry_does_not_force_full_symbols(self) -> None:
        self.assertEqual(self.decide(["build"], None, "").effective, "off")

    def test_scan_is_token_aware(self) -> None:
        # Operands of recognized options and arguments after ``--`` are never configuration.
        for argv in (["test", "--filter", "release"], ["build", "-Xswiftc", "-c"], ["build", "--product", "-c"],
                     ["run", "tool", "--", "-c", "release"], ["test", "--filter=-c"]):
            with self.subTest(argv=argv):
                self.assertEqual(self.decide(argv).configuration, "debug")

    def test_invalid_policy_values_raise(self) -> None:
        for value in ("", "ON", "true", "skip", " off"):
            with self.subTest(value=value), self.assertRaises(dd.PolicyError):
                self.decide(["build"], value)

    def test_banner_reports_policy_and_skip_not_applied(self) -> None:
        skip = self.decide(["build"]).banner()
        self.assertTrue(skip.startswith("rpce-debug-dsym: requested=off effective=off reason=debug_skip"))
        self.assertIn("make dev-dsym", skip)
        release = self.decide(["build", "-c", "release"]).banner()
        self.assertIn("warning=skip-not-applied", release)
        self.assertNotIn("warning=", self.decide(["build"], "on").banner())

    def run_cli(self, argv, env) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, env, clear=False), contextlib.redirect_stdout(out), \
                contextlib.redirect_stderr(err):
            for key in (dd.POLICY_ENV_KEY, dd.SENTRY_ENV_KEY):
                if key not in env:
                    os.environ.pop(key, None)
            code = dd.main(argv)
        return code, out.getvalue(), err.getvalue()

    def test_wrapper_policy_cli(self) -> None:
        code, out, err = self.run_cli(["wrapper-policy", "--", "build", "--product", "RepoPrompt"], {})
        self.assertEqual((code, out), (0, "off\n"))
        self.assertEqual(err.count("rpce-debug-dsym:"), 1)
        code, out, _ = self.run_cli(["wrapper-policy", "--", "build"], {dd.POLICY_ENV_KEY: "on"})
        self.assertEqual((code, out), (0, "on\n"))
        code, out, err = self.run_cli(["wrapper-policy", "--", "build"], {dd.POLICY_ENV_KEY: ""})
        self.assertEqual((code, out), (2, ""))
        self.assertIn("must be 'on' or 'off'", err)
        with mock.patch.object(dd, "classify_environment", side_effect=RuntimeError("boom")):
            code, out, _ = self.run_cli(["wrapper-policy", "--", "build"], {})
        self.assertEqual((code, out), (70, ""))


class UUIDReaderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)

    def write(self, name: str, data: bytes) -> Path:
        path = self.dir / name
        path.write_bytes(data)
        return path

    def test_thin_and_fat_uuids_are_architecture_qualified(self) -> None:
        self.assertEqual(dd.read_uuids(self.write("thin", thin(NEW)))[0], {f"arm64:{uuid_text(NEW)}"})
        both = dd.read_uuids(self.write("fat", fat(thin(NEW), thin(OLD, X86_64))))[0]
        self.assertEqual(both, {f"arm64:{uuid_text(NEW)}", f"x86_64:{uuid_text(OLD)}"})

    def test_malformed_inputs_raise(self) -> None:
        for name, data in (("none", thin(NEW, with_uuid=False)), ("text", b"#!/bin/sh\necho\n"), ("short", b"\xcf\xfa")):
            with self.subTest(name=name), self.assertRaises(dd.MachOError):
                dd.read_uuids(self.write(name, data))

    def test_symlinks_are_not_followed(self) -> None:
        target = self.write("real", thin(NEW))
        (self.dir / "link").symlink_to(target)
        with self.assertRaises(OSError):
            dd.read_uuids(self.dir / "link")


class RegenerationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(os.path.realpath(self.tmp.name)) / "pkg"
        self.bin = self.root / ".build" / "arm64-apple-macosx" / "debug"
        self.bin.mkdir(parents=True)
        self.tool = Path(self.tmp.name) / "fake-dsymutil"
        self.tool.write_text(f"#!{sys.executable}\n" + FAKE_DSYMUTIL, encoding="utf-8")
        self.tool.chmod(0o755)
        self.lines: list[str] = []
        os.environ.pop("FAKE_DSYMUTIL_MODE", None)

    def exe(self, name: str = "RepoPrompt", parent: Path | None = None, uuid: bytes = NEW) -> Path:
        directory = parent or self.bin
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / name
        path.write_bytes(thin(uuid))
        path.chmod(0o755)
        return path

    def dsym(self, exe: Path, uuid: bytes = OLD) -> Path:
        dwarf = exe.parent / f"{exe.name}.dSYM" / "Contents" / "Resources" / "DWARF"
        dwarf.mkdir(parents=True)
        (dwarf / exe.name).write_bytes(thin(uuid))
        return exe.parent / f"{exe.name}.dSYM"

    def bundle_dir(self) -> Path:
        return self.bin / dd.ROOT_TEST_BUNDLE / "Contents" / "MacOS"

    def run_regen(self, selector: str = "RepoPrompt", mode: str = "ok") -> dict:
        with mock.patch.dict(os.environ, {"FAKE_DSYMUTIL_MODE": mode}):
            return dd.regenerate(self.root, selector, machine="arm64", dsymutil=str(self.tool), emit=self.lines.append)

    def tree(self) -> dict:
        found = {}
        for dirpath, dirnames, filenames in os.walk(self.root):
            for name in dirnames + filenames:
                path = Path(dirpath) / name
                st = os.lstat(path)
                found[str(path.relative_to(self.root))] = (st.st_ino, path.read_bytes() if path.is_file() else None)
        return found

    def outside_dsym(self, tree: dict) -> dict:
        return {key: value for key, value in tree.items() if ".dSYM" not in key}

    def test_creates_a_verified_dsym_in_place_and_touches_nothing_else(self) -> None:
        exe = self.exe()
        (self.bin / "RepoPrompt.build").mkdir()
        (self.bin / "RepoPrompt.build" / "main.o").write_bytes(b"object")
        before = self.tree()
        report = self.run_regen()
        self.assertEqual(self.outside_dsym(self.tree()), before)
        self.assertEqual(dd.dsym_uuids(self.bin / "RepoPrompt.dSYM", "RepoPrompt"), dd.read_uuids(exe)[0])
        self.assertEqual(report["products"][0]["uuids"], [f"arm64:{uuid_text(NEW)}"])
        self.assertFalse(report["products"][0]["replaced"])
        self.assertEqual(sorted(os.listdir(self.bin)), ["RepoPrompt", "RepoPrompt.build", "RepoPrompt.dSYM"])
        self.assertTrue(any("RepoPrompt.dSYM created in place uuids=arm64:" in line for line in self.lines))

    def test_regenerates_a_stale_dsym_in_place_at_the_conventional_path(self) -> None:
        exe = self.exe()
        stale = self.dsym(exe, OLD)
        identity = os.lstat(stale).st_ino
        report = self.run_regen()
        self.assertTrue(report["products"][0]["replaced"])
        self.assertEqual(os.lstat(stale).st_ino, identity)  # same bundle directory: no swap, no backup
        self.assertEqual(dd.dsym_uuids(stale, "RepoPrompt"), {f"arm64:{uuid_text(NEW)}"})
        self.assertEqual(sorted(os.listdir(self.bin)), ["RepoPrompt", "RepoPrompt.dSYM"])
        self.assertTrue(any("RepoPrompt.dSYM regenerated in place uuids=arm64:" in line for line in self.lines))

    def test_root_tests_bundle_dsym_is_adjacent_inside_the_bundle(self) -> None:
        exe = self.exe("RepoPromptCEPackageTests", self.bundle_dir())
        self.dsym(exe, OLD)
        self.run_regen("root-tests")
        self.assertEqual(sorted(os.listdir(self.bundle_dir())), ["RepoPromptCEPackageTests", "RepoPromptCEPackageTests.dSYM"])
        self.assertEqual(sorted(os.listdir(self.bin / dd.ROOT_TEST_BUNDLE)), ["Contents"])
        self.assertEqual(dd.dsym_uuids(self.bundle_dir() / "RepoPromptCEPackageTests.dSYM", "RepoPromptCEPackageTests"),
                         {f"arm64:{uuid_text(NEW)}"})

    def test_failures_are_disclosed_and_never_claim_preserved_symbols(self) -> None:
        for mode in ("fail", "mismatch", "change-exe"):
            with self.subTest(mode=mode):
                exe = self.exe()
                if not (self.bin / "RepoPrompt.dSYM").exists():
                    self.dsym(exe, OLD)
                before = self.outside_dsym(self.tree())
                with self.assertRaisesRegex(dd.RegenerationError, "may be missing, partial or stale \\(previous "
                                            "symbols are not preserved\\); rerun `make dev-dsym PRODUCT=RepoPrompt`"):
                    self.run_regen(mode=mode)
                after = self.outside_dsym(self.tree())
                if mode == "change-exe":
                    key = str(exe.relative_to(self.root))
                    self.assertNotEqual(after.pop(key), before.pop(key))
                self.assertEqual(after, before)
                self.assertNotIn("unchanged", "\n".join(self.lines))

    def test_symlinked_ancestry_and_unexpected_destinations_are_rejected(self) -> None:
        self.exe()
        real = self.root / "elsewhere.dSYM"
        real.mkdir()
        (self.bin / "RepoPrompt.dSYM").symlink_to(real)
        with self.assertRaises(dd.RegenerationError):
            self.run_regen()
        self.assertTrue((self.bin / "RepoPrompt.dSYM").is_symlink())
        (self.bin / "RepoPrompt.dSYM").unlink()
        (self.bin / "RepoPrompt.dSYM").write_text("not a bundle")
        with self.assertRaises(dd.RegenerationError):
            self.run_regen()
        self.assertEqual((self.bin / "RepoPrompt.dSYM").read_text(), "not a bundle")
        # A symlinked bundle component: the product is never resolved through it.
        target = self.root / "real-contents"
        (target / "MacOS").mkdir(parents=True)
        (self.bin / dd.ROOT_TEST_BUNDLE).mkdir()
        (self.bin / dd.ROOT_TEST_BUNDLE / "Contents").symlink_to(target)
        self.exe("RepoPromptCEPackageTests", target / "MacOS")
        with self.assertRaises(dd.RegenerationError):
            self.run_regen("root-tests")
        self.assertEqual(os.listdir(target / "MacOS"), ["RepoPromptCEPackageTests"])
        # A symlinked build-root component.
        moved = self.root / "real-triple"
        os.rename(self.root / ".build" / "arm64-apple-macosx", moved)
        (self.root / ".build" / "arm64-apple-macosx").symlink_to(moved)
        with self.assertRaises(dd.RegenerationError):
            self.run_regen()

    def test_selection_rules(self) -> None:
        with self.assertRaisesRegex(dd.RegenerationError, "none of the selected"):
            self.run_regen("all")
        with self.assertRaisesRegex(dd.RegenerationError, "has not been built"):
            self.run_regen("repoprompt-mcp")
        self.exe("repoprompt-mcp")
        report = self.run_regen("all")
        self.assertEqual([item["product"] for item in report["products"]], ["repoprompt-mcp"])
        self.assertEqual(report["omitted"], ["RepoPrompt", "repoprompt-gateway", "root-tests"])
        self.assertIn("dsym: RepoPrompt not built; omitted", self.lines)
        with self.assertRaisesRegex(dd.RegenerationError, "PRODUCT must be one of"):
            self.run_regen("everything")
        missing = Path(self.tmp.name) / "no-build"
        missing.mkdir()
        with self.assertRaisesRegex(dd.RegenerationError, "no native debug build exists"):
            dd.regenerate(missing, "all", machine="arm64", dsymutil=str(self.tool), emit=self.lines.append)

    def test_cancellation_is_disclosed_and_propagates(self) -> None:
        exe = self.exe()
        self.dsym(exe, OLD)
        before = self.outside_dsym(self.tree())
        for error in (KeyboardInterrupt(), SystemExit(128 + signal.SIGTERM)):
            with self.subTest(error=type(error).__name__):
                with mock.patch.object(dd, "run_dsymutil", side_effect=error), self.assertRaises(type(error)):
                    self.run_regen()
                self.assertIn("dsym: interrupted; ", self.lines[-1])
                self.assertIn("may be missing, partial or stale; rerun `make dev-dsym PRODUCT=RepoPrompt`",
                              self.lines[-1])
        self.assertEqual(self.outside_dsym(self.tree()), before)

    def test_dsymutil_targets_the_conventional_adjacent_path_directly(self) -> None:
        exe = self.exe()
        calls = []
        real = dd.run_dsymutil

        def record(argv, timeout):
            calls.append(list(argv))
            return real(argv, timeout)

        with mock.patch.object(dd, "run_dsymutil", side_effect=record):
            self.run_regen()
        self.assertEqual(calls, [[str(self.tool), str(exe), "-o", str(self.bin / "RepoPrompt.dSYM")]])

    def test_pcm_warnings_and_duration_are_reported(self) -> None:
        self.exe()
        report = self.run_regen(mode="pcm")
        self.assertEqual(report["products"][0]["pcmWarnings"], 3)
        self.assertIsInstance(report["products"][0]["durationSeconds"], float)
        self.assertTrue(any("pcmWarnings=3" in line for line in self.lines))

    def test_regenerate_cli(self) -> None:
        err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err), \
                mock.patch.object(dd.signal, "signal"):
            self.assertEqual(dd.main(["regenerate", "--product", "everything", "--package-root", str(self.root)]), 1)
            self.assertEqual(dd.main(["regenerate", "--unknown"]), 64)
        self.assertIn("PRODUCT must be one of", err.getvalue())
        with self.assertRaises(SystemExit) as raised:
            dd._terminate(signal.SIGTERM, None)
        self.assertEqual(raised.exception.code, 128 + signal.SIGTERM)


if __name__ == "__main__":
    unittest.main()
