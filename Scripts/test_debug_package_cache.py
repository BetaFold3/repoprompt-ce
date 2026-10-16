#!/usr/bin/env python3
"""Focused tests for Scripts/debug_package_cache.py and its package_app.sh wiring (plan Step 3).

Publish failure paths use injected rename/swap callables over real temporary directories.
The darwin-only cases exercise the real renamex_np swap on disposable directories.
"""

from __future__ import annotations

import errno
import io
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock
from typing import Callable, List, Optional, Tuple

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import debug_package_cache as dpc  # noqa: E402

BUNDLE = "RepoPrompt.app"


def os_rename(source: Path, destination: Path) -> None:
    os.rename(source, destination)


def simulated_swap(source: Path, destination: Path) -> None:
    """Exchange two paths the way renamex_np(RENAME_SWAP) does, for non-darwin injection."""
    holding = source.parent / ".swap-holding"
    os.rename(destination, holding)
    os.rename(source, destination)
    os.rename(holding, source)


def raising(code: int) -> Callable[[Path, Path], None]:
    def call(source: Path, destination: Path) -> None:
        raise OSError(code, os.strerror(code), str(source), None, str(destination))

    return call


class RecordingRename:
    """Delegates to os.rename, failing the calls whose (source name, destination name) are listed."""

    def __init__(self, fail_on: Tuple[Tuple[str, str], ...] = ()) -> None:
        self.fail_on = set(fail_on)
        self.calls: List[Tuple[str, str]] = []

    def __call__(self, source: Path, destination: Path) -> None:
        key = (Path(source).name, Path(destination).name)
        self.calls.append(key)
        if key in self.fail_on:
            raise OSError(errno.EIO, "injected rename failure", str(source), None, str(destination))
        os.rename(source, destination)


class PublishTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="rpce-dpc-test-"))
        self.addCleanup(shutil.rmtree, self.root, True)
        self.dest = self.root / BUNDLE
        self.temp_parent = self.root / ".rpce-package-123-abcdefgh"
        self.temp_parent.mkdir()
        self.new = self.temp_parent / BUNDLE
        self.backup = self.temp_parent / f"previous-{BUNDLE}"
        self.make_bundle(self.new, "new")

    @staticmethod
    def make_bundle(path: Path, marker: str) -> None:
        (path / "Contents").mkdir(parents=True)
        (path / "Contents" / "marker").write_text(marker, encoding="utf-8")

    @staticmethod
    def marker(path: Path) -> Optional[str]:
        target = path / "Contents" / "marker"
        return target.read_text(encoding="utf-8") if target.exists() else None

    def publish(self, **kwargs) -> Tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        kwargs.setdefault("rename", RecordingRename())
        kwargs.setdefault("swap", simulated_swap)
        code = dpc.publish(self.new, self.dest, self.temp_parent, out=out, err=err, **kwargs)
        return code, out.getvalue(), err.getvalue()

    def assert_schema(self, stdout: str, outcome: str) -> None:
        self.assertEqual(stdout.splitlines(), ["schema=1", f"outcome={outcome}"])

    def test_absent_destination_is_renamed_and_temp_parent_removed(self) -> None:
        swap_calls: List[Tuple[Path, Path]] = []
        code, out, _ = self.publish(swap=lambda s, d: swap_calls.append((s, d)))
        self.assertEqual(code, 0)
        self.assert_schema(out, "renamed")
        self.assertEqual(self.marker(self.dest), "new")
        self.assertEqual(swap_calls, [])
        self.assertFalse(self.temp_parent.exists())

    def test_swap_success_publishes_and_removes_previous_with_temp_parent(self) -> None:
        self.make_bundle(self.dest, "old")
        rename = RecordingRename()
        code, out, _ = self.publish(rename=rename)
        self.assertEqual(code, 0)
        self.assert_schema(out, "swapped")
        self.assertEqual(self.marker(self.dest), "new")
        self.assertEqual(rename.calls, [])
        self.assertFalse(self.temp_parent.exists())

    def test_swap_unsupported_falls_back_to_two_renames(self) -> None:
        for code_value in (errno.ENOTSUP, errno.EINVAL, errno.ENOSYS):
            with self.subTest(errno=errno.errorcode[code_value]):
                self.tearDown_reset()
                self.make_bundle(self.dest, "old")
                rename = RecordingRename()
                code, out, err = self.publish(rename=rename, swap=raising(code_value))
                self.assertEqual(code, 0, err)
                self.assert_schema(out, "fallback")
                self.assertEqual(self.marker(self.dest), "new")
                self.assertEqual(rename.calls, [(BUNDLE, self.backup.name), (BUNDLE, BUNDLE)])
                self.assertFalse(self.temp_parent.exists())

    def tearDown_reset(self) -> None:
        shutil.rmtree(self.root)
        self.root.mkdir()
        self.temp_parent.mkdir()
        self.make_bundle(self.new, "new")

    def test_fallback_moving_destination_aside_fails_leaves_everything_unchanged(self) -> None:
        self.make_bundle(self.dest, "old")
        rename = RecordingRename(fail_on=((BUNDLE, self.backup.name),))
        code, out, err = self.publish(rename=rename, swap=raising(errno.ENOTSUP))
        self.assertEqual(code, 1)
        self.assert_schema(out, "failed")
        self.assertIn("destination untouched", err)
        self.assertEqual(self.marker(self.dest), "old")
        self.assertEqual(self.marker(self.new), "new")
        self.assertFalse((self.temp_parent / ".retain").exists())

    def test_replacement_fails_and_restore_succeeds(self) -> None:
        self.make_bundle(self.dest, "old")
        rename = RecordingRename(fail_on=((BUNDLE, BUNDLE),))
        code, out, err = self.publish(rename=rename, swap=raising(errno.ENOTSUP))
        self.assertEqual(code, 1)
        self.assert_schema(out, "restored")
        self.assertIn("publish failed; previous bundle restored", err)
        self.assertEqual(self.marker(self.dest), "old")
        self.assertFalse(self.backup.exists())
        self.assertFalse((self.temp_parent / ".retain").exists())
        self.assertEqual(rename.calls, [(BUNDLE, self.backup.name), (BUNDLE, BUNDLE), (self.backup.name, BUNDLE)])

    def test_replacement_and_restore_fail_preserve_backup_retain_and_recovery_then_cleanup_keeps_it(self) -> None:
        self.make_bundle(self.dest, "old")
        rename = RecordingRename(fail_on=((BUNDLE, BUNDLE), (self.backup.name, BUNDLE)))
        removed: List[Path] = []
        code, out, err = self.publish(
            rename=rename, swap=raising(errno.ENOTSUP), remove_tree=lambda p: removed.append(p)
        )
        expected_mv = f'mv "{self.backup}" "{self.dest}"'
        self.assertEqual(code, 3)
        self.assert_schema(out, "retained")
        self.assertIn(f"PUBLISH FAILED: {self.dest} is missing. Previous bundle preserved at {self.backup}.", err)
        self.assertIn(f"New bundle at {self.new}.", err)
        self.assertIn(f"Recover: {expected_mv}", err)
        self.assertFalse(os.path.lexists(self.dest))
        self.assertEqual(self.marker(self.backup), "old")
        self.assertEqual(self.marker(self.new), "new")
        retain = (self.temp_parent / ".retain").read_text(encoding="utf-8")
        self.assertIn(expected_mv, retain)
        self.assertEqual(removed, [], "publish must never delete anything after a failed restore")

        # A later run's stale cleanup (well past the age limit) keeps the retained directory.
        cleanup_err = io.StringIO()
        cleanup_out = io.StringIO()
        status = dpc.cleanup_stale(
            self.root, 3600, now=lambda: time.time() + 10 * 3600, out=cleanup_out, err=cleanup_err
        )
        self.assertEqual(status, 0)
        self.assertEqual(cleanup_out.getvalue().splitlines(), ["schema=1", "removed=0", "retained=1"])
        self.assertIn(expected_mv, cleanup_err.getvalue())
        self.assertEqual(self.marker(self.backup), "old")

        # The printed recovery restores the previous bundle.
        subprocess.run(["mv", str(self.backup), str(self.dest)], check=True)
        self.assertEqual(self.marker(self.dest), "old")

    def test_other_swap_errors_leave_destination_untouched(self) -> None:
        for code_value in (errno.EXDEV, errno.EACCES, errno.EBUSY):
            with self.subTest(errno=errno.errorcode[code_value]):
                self.tearDown_reset()
                self.make_bundle(self.dest, "old")
                rename = RecordingRename()
                code, out, err = self.publish(rename=rename, swap=raising(code_value))
                self.assertEqual(code, 1)
                self.assert_schema(out, "failed")
                self.assertIn("destination untouched", err)
                self.assertEqual(rename.calls, [])
                self.assertEqual(self.marker(self.dest), "old")
                self.assertEqual(self.marker(self.new), "new")
                self.assertFalse((self.temp_parent / ".retain").exists())

    def test_symlink_and_file_destinations_are_rejected_before_any_mutation(self) -> None:
        target = self.root / "elsewhere.app"
        self.make_bundle(target, "elsewhere")
        cases = {
            "symlink-to-directory": lambda: self.dest.symlink_to(target),
            "dangling-symlink": lambda: self.dest.symlink_to(self.root / "missing.app"),
            "regular-file": lambda: self.dest.write_text("x", encoding="utf-8"),
        }
        for label, make in cases.items():
            with self.subTest(label):
                if os.path.lexists(self.dest):
                    self.dest.unlink()
                make()
                rename = RecordingRename()
                swap_calls: List[Tuple[Path, Path]] = []
                code, out, err = self.publish(rename=rename, swap=lambda s, d: swap_calls.append((s, d)))
                self.assertEqual(code, 1)
                self.assert_schema(out, "rejected")
                self.assertIn("publish rejected", err)
                self.assertEqual((rename.calls, swap_calls), ([], []))
                self.assertEqual(self.marker(target), "elsewhere")
                self.assertEqual(self.marker(self.new), "new")
                self.assertFalse((self.temp_parent / ".retain").exists())

    def test_layout_guards_reject_non_sibling_or_misnamed_inputs(self) -> None:
        other = self.root / "nested" / ".rpce-package-9-zzzzzzzz"
        other.mkdir(parents=True)
        self.make_bundle(other / BUNDLE, "other")
        out, err = io.StringIO(), io.StringIO()
        self.assertEqual(dpc.publish(other / BUNDLE, self.dest, other, out=out, err=err), 1)
        self.assertIn("not a sibling", err.getvalue())

        plain = self.root / "plain-temp"
        plain.mkdir()
        self.make_bundle(plain / BUNDLE, "plain")
        err = io.StringIO()
        self.assertEqual(dpc.publish(plain / BUNDLE, self.dest, plain, out=io.StringIO(), err=err), 1)
        self.assertIn(".rpce-package-*", err.getvalue())
        self.assertFalse(os.path.lexists(self.dest))

    def test_temp_parent_delete_failure_still_succeeds_and_leaves_no_retain(self) -> None:
        def fail_remove(path: Path) -> None:
            raise OSError(errno.EPERM, "injected")

        code, out, err = self.publish(remove_tree=fail_remove)
        self.assertEqual(code, 0)
        self.assert_schema(out, "renamed")
        self.assertIn("stale cleanup will remove it later", err)
        self.assertTrue(self.temp_parent.exists())
        self.assertFalse((self.temp_parent / ".retain").exists())

    def test_absent_destination_rename_failure_keeps_new_bundle(self) -> None:
        rename = RecordingRename(fail_on=((BUNDLE, BUNDLE),))
        code, out, _ = self.publish(rename=rename)
        self.assertEqual(code, 1)
        self.assert_schema(out, "failed")
        self.assertFalse(os.path.lexists(self.dest))
        self.assertEqual(self.marker(self.new), "new")
        self.assertFalse((self.temp_parent / ".retain").exists())

    def test_partial_retain_write_failure_removes_retain_and_leaves_destination(self) -> None:
        self.make_bundle(self.dest, "old")
        original = dpc._Publisher.write_retain

        def partial_write(publisher, text: str) -> None:
            publisher.retain.write_text("", encoding="utf-8")
            raise OSError(errno.ENOSPC, "injected partial write")

        dpc._Publisher.write_retain = partial_write
        self.addCleanup(setattr, dpc._Publisher, "write_retain", original)
        rename = RecordingRename()
        swap_calls: List[Tuple[Path, Path]] = []
        code, out, err = self.publish(rename=rename, swap=lambda s, d: swap_calls.append((s, d)))
        self.assertEqual(code, 1)
        self.assert_schema(out, "failed")
        self.assertIn("destination untouched", err)
        self.assertEqual((rename.calls, swap_calls), ([], []))
        self.assertEqual(self.marker(self.dest), "old")
        self.assertFalse(os.path.lexists(self.temp_parent / ".retain"))

    def test_cli_publish_prints_schema_first(self) -> None:
        result = subprocess.run(
            [
                sys.executable, "-I", "-S", str(SCRIPT_DIR / "debug_package_cache.py"), "publish",
                "--new", str(self.new), "--dest", str(self.dest), "--temp-parent", str(self.temp_parent),
            ],
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[0], "schema=1")
        self.assertEqual(self.marker(self.dest), "new")

    @unittest.skipUnless(sys.platform == "darwin", "renamex_np is macOS-only")
    def test_darwin_real_swap_keeps_new_root_inode(self) -> None:
        self.make_bundle(self.dest, "old")
        new_inode = self.new.stat().st_ino
        out, err = io.StringIO(), io.StringIO()
        code = dpc.publish(self.new, self.dest, self.temp_parent, out=out, err=err)
        self.assertEqual(code, 0, err.getvalue())
        self.assert_schema(out.getvalue(), "swapped")
        self.assertEqual(self.marker(self.dest), "new")
        self.assertEqual(self.dest.stat().st_ino, new_inode)
        self.assertFalse(self.temp_parent.exists())


class CleanupStaleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.parent = Path(tempfile.mkdtemp(prefix="rpce-dpc-cleanup-"))
        self.addCleanup(shutil.rmtree, self.parent, True)

    def make(self, name: str, *, age: float, retain: bool = False) -> Path:
        path = self.parent / name
        (path / BUNDLE).mkdir(parents=True)
        if retain:
            (path / ".retain").write_text(f'Recover: mv "{path}/previous-{BUNDLE}" "dest"\n', encoding="utf-8")
        stamp = time.time() - age
        os.utime(path, (stamp, stamp))
        return path

    def test_age_retain_prefix_and_symlink_rules(self) -> None:
        old = self.make(".rpce-package-1-aaaaaaaa", age=2 * 3600)
        young = self.make(".rpce-package-2-bbbbbbbb", age=10 * 60)
        retained = self.make(".rpce-package-3-cccccccc", age=5 * 3600, retain=True)
        staging = self.make(".staging", age=9 * 3600)
        live = self.make(BUNDLE, age=9 * 3600)
        outside = Path(tempfile.mkdtemp(prefix="rpce-dpc-outside-"))
        self.addCleanup(shutil.rmtree, outside, True)
        link = self.parent / ".rpce-package-4-dddddddd"
        link.symlink_to(outside)
        stamp = time.time() - 9 * 3600
        os.utime(outside, (stamp, stamp))

        out, err = io.StringIO(), io.StringIO()
        self.assertEqual(dpc.cleanup_stale(self.parent, 3600, out=out, err=err), 0)
        self.assertEqual(out.getvalue().splitlines(), ["schema=1", "removed=1", "retained=1"])
        self.assertFalse(old.exists())
        for kept in (young, retained, staging, live, outside):
            self.assertTrue(kept.exists(), kept)
        self.assertTrue(link.is_symlink())
        self.assertIn("previous-RepoPrompt.app", err.getvalue())

    def test_removal_failure_warns_and_continues(self) -> None:
        stuck = self.make(".rpce-package-5-eeeeeeee", age=2 * 3600)

        def fail_remove(path: Path) -> None:
            raise OSError(errno.EACCES, "injected", str(path))

        out, err = io.StringIO(), io.StringIO()
        self.assertEqual(dpc.cleanup_stale(self.parent, 3600, remove_tree=fail_remove, out=out, err=err), 0)
        self.assertEqual(out.getvalue().splitlines(), ["schema=1", "removed=0", "retained=0"])
        self.assertIn(f"WARNING: could not remove stale package directory {stuck}", err.getvalue())
        self.assertTrue(stuck.exists())

    def test_missing_parent_is_a_no_op_and_file_parent_is_an_error(self) -> None:
        out = io.StringIO()
        self.assertEqual(dpc.cleanup_stale(self.parent / "absent", 3600, out=out, err=io.StringIO()), 0)
        self.assertEqual(out.getvalue().splitlines()[0], "schema=1")
        regular = self.parent / "file"
        regular.write_text("x", encoding="utf-8")
        self.assertEqual(dpc.cleanup_stale(regular, 3600, out=io.StringIO(), err=io.StringIO()), 1)

    def test_cli_rejects_negative_max_age(self) -> None:
        result = subprocess.run(
            [sys.executable, "-I", "-S", str(SCRIPT_DIR / "debug_package_cache.py"), "cleanup-stale",
             "--parent", str(self.parent), "--max-age", "-1"],
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 2)


class SourceContractTests(unittest.TestCase):
    def test_renamex_np_contract_matches_conductor_and_rollback_deliberately_differs(self) -> None:
        conductor = (SCRIPT_DIR / "conductor.py").read_text(encoding="utf-8")
        helper = (SCRIPT_DIR / "debug_package_cache.py").read_text(encoding="utf-8")
        swap_body = conductor.split("def swap_staged_debug_bundle_into_place(", 1)[1].split("\ndef ", 1)[0]
        activate_body = conductor.split("def activate_staged_debug_bundle(", 1)[1].split("\ndef ", 1)[0]
        argtypes = "renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]"
        for text in (swap_body, helper):
            self.assertIn("ctypes.CDLL(None, use_errno=True).renamex_np", text)
            self.assertIn(argtypes, text)
            self.assertIn("renamex_np.restype = ctypes.c_int", text)
        flag = re.search(r"rename_swap = (0x[0-9a-fA-F]+)", swap_body)
        self.assertIsNotNone(flag)
        self.assertEqual(int(flag.group(1), 16), dpc.RENAME_SWAP)
        self.assertEqual(dpc.RENAME_SWAP, 0x2)
        # Conductor deletes its backup unconditionally; the helper never deletes a backup.
        self.assertIn("shutil.rmtree(backup, ignore_errors=True)", activate_body.split("finally:", 1)[1])
        self.assertNotIn("rmtree(backup", helper)
        self.assertNotIn("import conductor", helper)
        # Only plan's Git-state reader shells out (git, as the debug provenance does); publish and
        # cleanup never do.
        import inspect

        for function in (dpc._Publisher, dpc.publish, dpc.renamex_swap, dpc.cleanup_stale):
            self.assertNotIn("subprocess", inspect.getsource(function), function)
        self.assertEqual(helper.count("subprocess.run("), 1)
        self.assertIn("subprocess.run([\"git\", \"-C\", str(root), *args]", helper)


class PackageScriptWiringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")

    def finish_body(self) -> str:
        return self.script.split("\nfinish(){\n", 1)[1].split("\n}\ntrap 'finish $?' EXIT", 1)[0]

    def test_finish_deletes_temp_parent_only_when_destination_exists_and_not_retained(self) -> None:
        body = self.finish_body()
        self.assertEqual(self.script.count('rm -rf "$TEMP_PARENT"'), 1)
        guard = '        if [[ -e "$PACKAGE_DEST" && ! -e "$TEMP_PARENT/.retain" ]]; then\n            rm -rf "$TEMP_PARENT"'
        self.assertIn(guard, body)
        self.assertIn('if [[ -n "${TEMP_PARENT:-}" && -d "$TEMP_PARENT" ]]; then', body)
        self.assertLess(self.script.index('PACKAGE_DEST=""\nTEMP_PARENT=""'), self.script.index("trap 'finish $?' EXIT"))

    def run_finish(self, *, dest_exists: bool, retain: Optional[str]) -> Tuple[subprocess.CompletedProcess, Path]:
        root = Path(tempfile.mkdtemp(prefix="rpce-dpc-finish-"))
        self.addCleanup(shutil.rmtree, root, True)
        dest = root / BUNDLE
        if dest_exists:
            dest.mkdir()
        temp_parent = root / ".rpce-package-7-ffffffff"
        (temp_parent / BUNDLE).mkdir(parents=True)
        if retain is not None:
            (temp_parent / ".retain").write_text(retain, encoding="utf-8")
        probe = f"""set -euo pipefail
package_timing_record(){{ :; }}
PACKAGE_TIMING_OUTCOME=fresh PACKAGE_TIMING_DEEP=ran PACKAGE_TIMING_TOTAL_MS=0 START_TIME="$(date +%s)" CONF=debug
PACKAGE_DEST={shlex.quote(str(dest))}
TEMP_PARENT={shlex.quote(str(temp_parent))}
finish(){{
{self.finish_body()}
}}
finish 1
"""
        result = subprocess.run(["bash", "-c", probe], text=True, capture_output=True)
        return result, temp_parent

    def test_finish_rule_functionally(self) -> None:
        result, temp_parent = self.run_finish(dest_exists=True, retain=None)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(temp_parent.exists())

        result, temp_parent = self.run_finish(dest_exists=True, retain="PUBLISH FAILED: recover line")
        self.assertTrue(temp_parent.exists())
        self.assertIn("PUBLISH FAILED: recover line", result.stderr)

        result, temp_parent = self.run_finish(dest_exists=False, retain=None)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(temp_parent.exists())
        self.assertIn("is missing", result.stderr)

    def test_debug_assembles_in_hidden_sibling_and_release_keeps_in_place_text(self) -> None:
        layout = self.script.split('phase "Creating app bundle layout"\n', 1)[1].split('run mkdir -p "$APP_BUNDLE/Contents/MacOS"', 1)[0]
        release_text = """if (( IS_RELEASE )); then
run rm -rf "$APP_BUNDLE"
APP_BUNDLE_MATCHES_COMPAT="$(paths_same "$APP_BUNDLE" "$COMPAT_APP_BUNDLE")"
if [[ "$APP_BUNDLE_MATCHES_COMPAT" != "1" ]]; then
    run rm -rf "$COMPAT_APP_BUNDLE"
fi
else
"""
        self.assertTrue(layout.startswith(release_text), layout)
        self.assertEqual(self.script.count('run rm -rf "$APP_BUNDLE"'), 1)
        debug = layout[len(release_text):]
        for needle in (
            'PACKAGE_DEST="$APP_BUNDLE"',
            'debug_package_cache.py" cleanup-stale --parent "$(dirname "$PACKAGE_DEST")" --max-age 3600',
            'APP_BUNDLE_MATCHES_COMPAT="$(paths_same "$PACKAGE_DEST" "$COMPAT_APP_BUNDLE")"',
            'TEMP_PARENT="$(mktemp -d "$(dirname "$PACKAGE_DEST")/.rpce-package-$$-XXXXXXXX")"',
            'APP_BUNDLE="$TEMP_PARENT/$(basename "$PACKAGE_DEST")"',
        ):
            self.assertIn(needle, debug)
        self.assertNotIn("rm -rf", debug)
        self.assertLess(debug.index("cleanup-stale"), debug.index("mktemp -d"))
        self.assertIn('python3 -I -S "$CONTROL_PLANE_SCRIPTS_DIR/debug_package_cache.py"', debug)

    def test_publish_follows_every_check_and_precedes_compat_link_and_created(self) -> None:
        script = self.script
        publish = script.index('debug_package_cache.py" publish --new "$APP_BUNDLE" --dest "$PACKAGE_DEST" --temp-parent "$TEMP_PARENT"')
        for check in (
            'run codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"',
            "\nverify_signed_app_identity\n",
            '"Post-sign packaged app"',
            'run "$CONTROL_PLANE_SCRIPTS_DIR/validate_embedded_mcp_helper_layout.sh" "$APP_BUNDLE"',
            'smoke_embedded_mcp_helper.sh" "$APP_BUNDLE"',
            'upload_sentry_debug_symbols.sh" "$SENTRY_SYMBOLS_DIR"',
        ):
            self.assertLess(script.index(check), publish, check)
        block = script[script.rindex("if (( ! IS_RELEASE )); then", 0, publish):]
        block = block.split('\nif [[ "$APP_BUNDLE_MATCHES_COMPAT" != "1" ]]; then\n    phase "Updating compatibility', 1)[0]
        self.assertIn('phase "Publishing debug app bundle"', block)
        self.assertLess(block.index("publish --new"), block.index('APP_BUNDLE="$PACKAGE_DEST"'))
        self.assertLess(block.index('APP_BUNDLE="$PACKAGE_DEST"'), block.index('run rm -rf "$COMPAT_APP_BUNDLE"'))
        self.assertLess(publish, script.index('run ln -sfn "$APP_BUNDLE" "$COMPAT_APP_BUNDLE"'))
        self.assertLess(publish, script.index("printf 'Created: %s\\n' \"$APP_BUNDLE\""))


# --- Step 4: identity, keys, closure and modes ---------------------------------------------------

SHA_A = "0F676823BBA28843A51A823BEAD1906B9804DA1B"
SHA_B = "754A0E794FC9D43E00B421F99FA1C913B5B4D23D"
SHA_C = "1111111111111111111111111111111111111111"
LISTING = f"""  1) {SHA_A} "Apple Development: Dev One (TEAM123456)"
  2) {SHA_B} "RepoPrompt CE Local Self-Signed Code Signing"
     2 valid identities found
"""


class ResolveIdentityTests(unittest.TestCase):
    def test_resolution_mirrors_codesign_selection(self) -> None:
        renewal = LISTING + f'  3) {SHA_C} "Apple Development: Dev One (TEAM123456)"\n'
        two_keychains = LISTING + f'  3) {SHA_A} "Apple Development: Dev One (TEAM123456)"\n'
        cases = [
            ("-", "", "adhoc"),
            (SHA_A, LISTING, SHA_A),
            (SHA_A.lower(), LISTING, SHA_A),
            (SHA_C, LISTING, "unresolved"),
            ("Apple Development: Dev One (TEAM123456)", LISTING, SHA_A),
            ("Self-Signed", LISTING, SHA_B),
            ("e", LISTING, "unresolved"),  # ambiguous substring
            ("No Such Identity", LISTING, "unresolved"),
            ("apple development", LISTING, "unresolved"),  # case-sensitive like the existing grep -F
            ("Apple Development", renewal, "unresolved"),  # renewal overlap: same name, two certs
            ("Apple Development", two_keychains, SHA_A),  # one cert listed twice
            ("", LISTING, "unresolved"),
            ("Apple Development", "", "unresolved"),
        ]
        for sign_identity, listing, expected in cases:
            with self.subTest(sign_identity=sign_identity):
                self.assertEqual(dpc.resolve_identity(sign_identity, listing), expected)

    def test_cli_prints_schema_first_and_warns_when_unresolved(self) -> None:
        def run(identity: str, listing: str) -> subprocess.CompletedProcess:
            return subprocess.run(
                [sys.executable, "-I", "-S", str(SCRIPT_DIR / "debug_package_cache.py"), "resolve-identity",
                 "--sign-identity", identity], input=listing, text=True, capture_output=True)

        resolved = run("Self-Signed", LISTING)
        self.assertEqual((resolved.returncode, resolved.stdout, resolved.stderr), (0, f"schema=1\ncert={SHA_B}\n", ""))
        unresolved = run("e", LISTING)
        self.assertEqual(unresolved.stdout, "schema=1\ncert=unresolved\n")
        self.assertIn(dpc.UNRESOLVED_WARNING, unresolved.stderr)
        self.assertEqual(run("-", "").stdout, "schema=1\ncert=adhoc\n")


class KeyFixture:
    """A temp repo/scripts/build tree plus injectable product stat records."""

    def __init__(self, test: unittest.TestCase) -> None:
        self.base = Path(tempfile.mkdtemp(prefix="rpce-dpc-keys-"))
        test.addCleanup(shutil.rmtree, self.base, True)
        self.root = self.base / "repo"
        self.scripts = self.root / "Scripts"
        self.build = self.root / ".build" / "debug"
        for directory in (self.scripts, self.build / "Sparkle.framework" / "Versions" / "B", self.root / "AppBundle",
                          self.root / "ThirdPartyLicenses", self.root / "AppResources"):
            directory.mkdir(parents=True)
        for name in dpc.INPUT_SCRIPTS:
            (self.scripts / name).write_text(f"{name}\n", encoding="utf-8")
        (self.scripts / "conductor.py").write_text("conductor-v1\n", encoding="utf-8")
        for rel in ("AppBundle/Info.plist.template", "LICENSE", "THIRD_PARTY_NOTICES.md", "version.env",
                    "ThirdPartyLicenses/pcre2.txt", "AppResources/Configuration.json"):
            (self.root / rel).write_text(f"{rel}\n", encoding="utf-8")
        (self.build / "Sparkle.framework" / "Versions" / "B" / "Sparkle").write_text("sparkle\n", encoding="utf-8")
        os.symlink("B", self.build / "Sparkle.framework" / "Versions" / "Current")
        self.resource_bundle = self.build / "RepoPrompt_RepoPrompt.bundle"
        (self.resource_bundle / "Contents" / "Resources").mkdir(parents=True)
        self.resource = self.resource_bundle / "Contents" / "Resources" / "data.json"
        self.resource.write_text("{}\n", encoding="utf-8")
        self.products = {name: {"st_dev": 1, "st_ino": 100 + index, "st_size": 1000, "st_mtime_ns": 5, "st_ctime_ns": 5,
                                "st_mode": 0o100755} for index, name in enumerate(dpc.PRODUCTS)}
        self.codesign = {"st_dev": 2, "st_ino": 9, "st_size": 10, "st_mtime_ns": 1, "st_ctime_ns": 1, "st_mode": 0o100755}
        self.fields = {name: f"value-{name}" for name in dpc.PLAN_FIELDS}
        self.environ = {"PATH": "/usr/bin"}
        self.git = ["main", "a" * 40, False]
        self.cert = SHA_A
        self.os_build = "25A1"

    def stat_fn(self, path: Path):
        import types

        if path.parent == self.build and path.name in self.products:
            return types.SimpleNamespace(**self.products[path.name])
        if path.name in ("codesign", "codesign_allocate"):
            return types.SimpleNamespace(**self.codesign)
        return os.stat(path)

    def keys(self) -> dict:
        return dpc.compute_keys(cert=self.cert, root=self.root, scripts_dir=self.scripts, build_dir=self.build,
                                fields=dict(self.fields), environ=dict(self.environ), git=tuple(self.git),
                                os_build=self.os_build, stat_fn=self.stat_fn)


class KeyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fx = KeyFixture(self)
        self.original = self.fx.keys()

    def assert_changes(self, mutate: Callable[[], object], expected: set) -> None:
        """The keys that differ between the state before and after ``mutate``."""
        before = self.fx.keys()
        mutate()
        after = self.fx.keys()
        self.assertEqual({name for name in after if after[name] != before[name]}, expected)

    def test_keys_are_stable_hex_digests(self) -> None:
        self.assertEqual(set(self.original), set(dpc.PLAN_KEYS))
        self.assertTrue(all(re.fullmatch(r"[0-9a-f]{64}", value) for value in self.original.values()))
        self.assertEqual(self.fx.keys(), self.original)

    def test_main_executable_stat_changes_only_input_key(self) -> None:
        main = self.fx.products["RepoPrompt"]
        self.assert_changes(lambda: main.update(st_mtime_ns=6), {"input_key"})
        main.update(st_mtime_ns=5)
        self.assertEqual(self.fx.keys(), self.original)
        # A rewrite that restores mtime still changes ctime, which userland cannot set.
        self.assert_changes(lambda: main.update(st_ctime_ns=7), {"input_key"})
        self.assert_changes(lambda: main.update(st_mode=0o100644), {"input_key"})

    def test_helper_stat_changes_its_helper_key_and_input_key(self) -> None:
        self.assert_changes(lambda: self.fx.products["repoprompt-mcp"].update(st_ino=999), {"helper_mcp_key", "input_key"})
        self.assert_changes(lambda: self.fx.products["repoprompt-gateway"].update(st_ctime_ns=9),
                            {"helper_gateway_key", "input_key"})

    def test_resource_bundle_membership_mode_and_symlink_changes(self) -> None:
        resources = self.fx.resource_bundle / "Contents" / "Resources"
        extra = resources / "extra.json"
        self.assert_changes(lambda: extra.write_text("x", encoding="utf-8"), {"input_key"})
        self.assert_changes(lambda: extra.unlink(), {"input_key"})
        self.assert_changes(lambda: self.fx.resource.chmod(0o600), {"input_key"})
        link = self.fx.resource_bundle / "Contents" / "link"
        self.assert_changes(lambda: os.symlink("Resources", link), {"input_key"})
        self.assert_changes(lambda: (link.unlink(), os.symlink("Elsewhere", link)), {"input_key"})
        copy = resources / "copy.json"
        copy.write_text("{}\n", encoding="utf-8")
        # A file replaced by a symlink to identical content.
        self.assert_changes(lambda: (self.fx.resource.unlink(), os.symlink("copy.json", self.fx.resource)), {"input_key"})

    def test_new_resource_bundle_and_sparkle_changes(self) -> None:
        self.assert_changes(lambda: (self.fx.build / ".hidden.bundle").mkdir(), set())  # bash glob skips dot names
        self.assert_changes(lambda: (self.fx.build / "Extra.bundle").mkdir(), {"input_key"})
        sparkle_link = self.fx.build / "Sparkle.framework" / "Versions" / "Current"
        self.assert_changes(lambda: (sparkle_link.unlink(), os.symlink("A", sparkle_link)), {"sparkle_key", "input_key"})

    def test_repo_inputs_change_input_key_by_content(self) -> None:
        for rel in dpc.REPO_INPUTS:
            path = self.fx.root / rel
            if path.is_dir():
                path = next(path.iterdir())
            with self.subTest(rel=rel):
                original = path.read_text(encoding="utf-8")
                self.assert_changes(lambda: path.write_text(original + "changed", encoding="utf-8"), {"input_key"})
                path.write_text(original, encoding="utf-8")
                self.assertEqual(self.fx.keys(), self.original)  # content, not stat, keys repo inputs
        self.assert_changes(lambda: (self.fx.root / "AppResources" / "new.txt").write_text("n"), {"input_key"})

    def test_control_scripts_change_signing_and_every_derived_key_but_conductor_does_not(self) -> None:
        self.assert_changes(lambda: (self.fx.scripts / "conductor.py").write_text("conductor-v2\n"), set())
        everything = set(dpc.PLAN_KEYS)
        for name in ("package_app.sh", "parse_release_metadata.py", "smoke_embedded_mcp_helper.sh"):
            with self.subTest(name=name):
                path = self.fx.scripts / name
                self.assert_changes(lambda: path.write_text("edited\n"), everything)
                path.write_text(f"{name}\n")
                self.assertEqual(self.fx.keys(), self.original)

    def test_signing_policy_inputs_change_every_key(self) -> None:
        everything = set(dpc.PLAN_KEYS)
        mutations = {
            "cert renewal under the same name": lambda: setattr(self.fx, "cert", SHA_C),
            "adhoc": lambda: setattr(self.fx, "cert", "adhoc"),
            "macOS build": lambda: setattr(self.fx, "os_build", "25B2"),
            "macOS build unavailable": lambda: setattr(self.fx, "os_build", None),
            "codesign stat": lambda: self.fx.codesign.update(st_ino=10),
            "codesign path": lambda: self.fx.environ.update(PATH="/nonexistent"),
            "signing mode": lambda: self.fx.fields.update(SIGNING_MODE_MARKER="debug-adhoc"),
            "storage marker": lambda: self.fx.fields.update(DEBUG_STORAGE_BACKEND_MARKER="keychain"),
            "adhoc flag": lambda: self.fx.fields.update(USE_ADHOC_SIGNING="1"),
            "CODESIGN_ALLOCATE": lambda: self.fx.environ.update(CODESIGN_ALLOCATE="/usr/bin/codesign_allocate"),
        }
        for label, mutate in mutations.items():
            with self.subTest(label):
                saved = (self.fx.cert, self.fx.os_build, dict(self.fx.codesign), dict(self.fx.fields), dict(self.fx.environ))
                self.assert_changes(mutate, everything)
                self.fx.cert, self.fx.os_build, self.fx.codesign, self.fx.fields, self.fx.environ = saved
                self.assertEqual(self.fx.keys(), self.original)
        self.fx.environ["CODESIGN_ALLOCATE"] = "/usr/bin/codesign_allocate"
        # The stat of the resolved CODESIGN_ALLOCATE tool counts too (fixture shares one stat record).
        self.assert_changes(lambda: self.fx.codesign.update(st_mtime_ns=99), everything)

    def test_bundle_level_inputs_change_only_input_key(self) -> None:
        mutations = {
            "commit": lambda: self.fx.git.__setitem__(1, "b" * 40),
            "dirty": lambda: self.fx.git.__setitem__(2, True),
            "branch": lambda: self.fx.git.__setitem__(0, "other"),
            "git unavailable": lambda: self.fx.git.__init__([None, None, None]),
            "bundle id": lambda: self.fx.fields.update(BUNDLE_ID="other"),
            "Sentry": lambda: self.fx.environ.update(REPOPROMPT_ENABLE_SENTRY="1"),
            "Sentry upload": lambda: self.fx.environ.update(REPOPROMPT_UPLOAD_SENTRY_SYMBOLS="1"),
        }
        for label, mutate in mutations.items():
            with self.subTest(label):
                saved = (list(self.fx.git), dict(self.fx.fields), dict(self.fx.environ))
                self.assert_changes(mutate, {"input_key"})
                self.fx.git, self.fx.fields, self.fx.environ = list(saved[0]), saved[1], saved[2]
                self.assertEqual(self.fx.keys(), self.original)

    def test_worktree_identity_changes_input_key(self) -> None:
        moved = self.fx.base / "other-worktree"
        os.rename(self.fx.root, moved)
        self.fx.root, self.fx.scripts, self.fx.build = moved, moved / "Scripts", moved / ".build" / "debug"
        # Product records are injected and rename keeps tree inodes, so only the root identity differs.
        after = self.fx.keys()
        self.assertEqual({name for name in after if after[name] != self.original[name]}, {"input_key"})

    def test_destination_and_provenance_are_not_inputs(self) -> None:
        import inspect

        for function in (dpc.compute_keys, dpc.plan):
            parameters = inspect.signature(function).parameters
            self.assertFalse({"dest", "destination", "bundle", "app_bundle"} & set(parameters), function)
        package = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        plan_call = package.split('debug_package_cache.py" plan', 1)[1].split(')"', 1)[0]
        self.assertNotIn("APP_BUNDLE", plan_call)
        self.assertNotIn("PACKAGE_DEST", plan_call)
        self.assertNotIn("Provenance", plan_call)

    def test_executables_are_only_stat_read(self) -> None:
        opened: List[str] = []
        real_read = Path.read_bytes

        def tracking(path: Path) -> bytes:
            opened.append(str(path))
            return real_read(path)

        with mock.patch.object(Path, "read_bytes", tracking):
            self.fx.keys()
        self.assertFalse([path for path in opened if Path(path).parent == self.fx.build])
        self.assertFalse([path for path in opened if ".bundle" in path or "Sparkle.framework" in path])


@unittest.skipUnless(shutil.which("git"), "git is required")
class GitStateTests(unittest.TestCase):
    """The real Git reader: the key tests inject this tuple, so pin its parsing here."""

    def test_git_state_reports_branch_commit_and_dirty_like_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            # Hermetic: no inherited GIT_DIR/GIT_INDEX_FILE (e.g. from a hook), no discovery of an
            # enclosing repository (e.g. TMPDIR inside a checkout). git_state inherits os.environ.
            env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
            env["GIT_CEILING_DIRECTORIES"] = f"{root.parent}:{root.resolve().parent}"
            patched = mock.patch.dict(os.environ, env, clear=True)
            patched.start()
            self.addCleanup(patched.stop)
            self.assertEqual(dpc.git_state(root), (None, None, False))
            run = lambda *args: subprocess.run(["git", "-C", tmp, *args], check=True, capture_output=True, env=env)
            run("init", "-q", "-b", "trunk")
            (root / "tracked").write_text("1")
            run("add", "tracked")
            run("-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
                "commit", "-q", "-m", "init")
            branch, commit, dirty = dpc.git_state(root)
            self.assertEqual((branch, dirty), ("trunk", False))
            self.assertRegex(commit or "", r"^[0-9a-f]{40}$")
            (root / "untracked").write_text("x")
            self.assertEqual(dpc.git_state(root), ("trunk", commit, True))


class ClosureTests(unittest.TestCase):
    """Every script, ROOT_DIR path and environment read in the debug closure is classified."""

    SCRIPT_REF = re.compile(r"\$\{?(?:CONTROL_PLANE_SCRIPTS_DIR|script_dir)\}?/(\$?[A-Za-z0-9_.{}-]+)")
    ROOT_REF = re.compile(r"\$\{?ROOT_DIR\}?/([A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*)")
    # Under `set -u` an optional environment read needs a default expansion.
    ENV_DEFAULT = re.compile(r"\$\{([A-Z_][A-Z0-9_]*):?[-=]")
    REPOPROMPT_TOKEN = re.compile(r"\bREPOPROMPT_[A-Z0-9_]+")
    PY_ENV = re.compile(r"os\.environ(?:\.get\(|\[)\s*[\"']([A-Za-z_][A-Za-z0-9_]*)")

    @classmethod
    def setUpClass(cls) -> None:
        cls.scanned: List[str] = []
        cls.scripts: set = set()
        cls.roots: set = set()
        cls.env: set = set()
        cls.dynamic: List[str] = []
        queue = ["package_app.sh"]
        while queue:
            name = queue.pop()
            if name in cls.scanned:
                continue
            cls.scanned.append(name)
            text = (SCRIPT_DIR / name).read_text(encoding="utf-8")
            for ref in cls.SCRIPT_REF.findall(text):
                if ref.startswith("$"):
                    cls.dynamic.append(ref)
                    continue
                cls.scripts.add(ref)
                if ref in dpc.INPUT_SCRIPTS and ref != "debug_package_cache.py":
                    queue.append(ref)
            if name == "debug_package_cache.py":
                continue  # the classifier itself; its own environment reads are tested in KeyTests
            for ref in cls.ROOT_REF.findall(text):
                cls.roots.add(".build" if ref.startswith(".build") else ref)
            cls.env.update(cls.ENV_DEFAULT.findall(text))
            cls.env.update(cls.REPOPROMPT_TOKEN.findall(text))
            if name.endswith(".py"):
                cls.env.update(cls.PY_ENV.findall(text))

    def test_every_referenced_script_is_an_input_or_excluded_and_lists_are_not_stale(self) -> None:
        self.assertEqual(self.dynamic, [], "dynamic script references must be DECLARED_DYNAMIC")
        self.assertEqual(dpc.DECLARED_DYNAMIC, {})
        for name in self.scripts:
            self.assertTrue(name in dpc.INPUT_SCRIPTS or name in dpc.CLOSURE_EXCLUSIONS, name)
        self.assertEqual(set(dpc.INPUT_SCRIPTS) - self.scripts, {"package_app.sh"})
        self.assertEqual(sorted(self.scanned), sorted(set(dpc.INPUT_SCRIPTS) - {"debug_package_cache.py"}))
        self.assertEqual(len(set(dpc.INPUT_SCRIPTS)), len(dpc.INPUT_SCRIPTS))
        for name in dpc.INPUT_SCRIPTS:
            self.assertTrue((SCRIPT_DIR / name).is_file(), name)

    def test_every_root_path_is_a_repo_input_or_excluded(self) -> None:
        for ref in self.roots:
            self.assertTrue(ref in dpc.REPO_INPUTS or ref in dpc.CLOSURE_EXCLUSIONS, ref)
        package = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        loader = (SCRIPT_DIR / "load_release_metadata.sh").read_text(encoding="utf-8")
        # Relative reads (package_app.sh runs from ROOT_DIR) and the transitive metadata source.
        relative = {"AppBundle/Info.plist.template": "Path('AppBundle/Info.plist.template')",
                    "AppResources": "rsync -a AppResources/"}
        for rel, needle in relative.items():
            self.assertIn(needle, package)
        self.assertIn('"$root/version.env"', loader)
        self.assertEqual(set(dpc.REPO_INPUTS), (self.roots & set(dpc.REPO_INPUTS)) | set(relative) | {"version.env"})
        for rel in dpc.REPO_INPUTS:
            self.assertTrue((SCRIPT_DIR.parent / rel).exists(), rel)

    def test_every_environment_read_is_classified_and_classifications_are_live(self) -> None:
        classified = set(dpc.ENV_INPUTS) | set(dpc.ENV_RESOLVED) | set(dpc.CLOSURE_EXCLUSIONS)
        self.assertEqual(sorted(self.env - classified), [])
        overlap = (set(dpc.ENV_INPUTS) & set(dpc.ENV_RESOLVED)) | (set(dpc.ENV_RESOLVED) & set(dpc.CLOSURE_EXCLUSIONS))
        self.assertEqual(overlap, set())
        stale = (set(dpc.ENV_INPUTS) | set(dpc.ENV_RESOLVED)) - self.env
        self.assertEqual(stale, set())
        stale_exclusions = set(dpc.CLOSURE_EXCLUSIONS) - self.env - self.scripts - self.roots
        self.assertEqual(stale_exclusions, set())
        for name, target in dpc.ENV_RESOLVED.items():
            kind, _, field = target.partition(" ")
            self.assertIn(kind, {"field", "cert", "root", "scripts-dir"}, name)
            if kind == "field":
                self.assertIn(field, dpc.PLAN_FIELDS, name)
        for name, reason in dpc.CLOSURE_EXCLUSIONS.items():
            self.assertTrue(reason.strip(), name)

    def test_package_app_passes_every_plan_field_once(self) -> None:
        package = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        plan_call = package.split('debug_package_cache.py" plan', 1)[1].split(')"', 1)[0]
        passed = re.findall(r"--field ([A-Z0-9_]+)=\"\$([A-Z0-9_]+)\"", plan_call)
        self.assertEqual(sorted(name for name, _ in passed), sorted(dpc.PLAN_FIELDS))
        self.assertTrue(all(name == variable for name, variable in passed), passed)


class PlanModeTests(unittest.TestCase):
    def run_plan(self, cache: str, cert: str) -> Tuple[dict, str, List[int]]:
        calls: List[int] = []

        def compute(**kwargs):
            calls.append(1)
            return {name: "k" * 64 for name in dpc.PLAN_KEYS}

        out, err = io.StringIO(), io.StringIO()
        root = Path(tempfile.mkdtemp(prefix="rpce-dpc-plan-"))
        self.addCleanup(shutil.rmtree, root, True)
        before = sorted(p.relative_to(root) for p in root.rglob("*"))
        code = dpc.plan(cache=cache, cert=cert, root=root, scripts_dir=root, build_dir=root, fields={}, environ={},
                        out=out, err=err, compute=compute)
        self.assertEqual(code, 0)
        self.assertEqual(sorted(p.relative_to(root) for p in root.rglob("*")), before)  # plan writes nothing
        lines = out.getvalue().splitlines()
        self.assertEqual(lines[0], "schema=1")
        return dict(line.split("=", 1) for line in lines[1:]), err.getvalue(), calls

    def test_off_and_unresolved_compute_nothing_and_allow_no_receipts(self) -> None:
        for cache, cert in (("off", SHA_A), ("off", "unresolved"), ("on", "unresolved")):
            with self.subTest(cache=cache, cert=cert):
                values, err, calls = self.run_plan(cache, cert)
                self.assertEqual(calls, [])
                self.assertEqual(values["receipts_allowed"], "0")
                self.assertEqual(values["outcome"], "fresh")
                self.assertTrue(all(values[name] == "none" for name in dpc.PLAN_KEYS))
                self.assertEqual("REPOPROMPT_DEBUG_PACKAGE_CACHE=off" in err, cache == "off")

    def test_on_with_resolved_cert_computes_keys(self) -> None:
        for cert in (SHA_A, "adhoc"):
            values, err, calls = self.run_plan("on", cert)
            self.assertEqual(calls, [1])
            self.assertEqual(values["receipts_allowed"], "1")
            self.assertEqual(list(values), ["outcome", "cache", "cert", "receipts_allowed", *dpc.PLAN_KEYS])

    def test_cli_rejects_bad_cache_cert_and_fields(self) -> None:
        base = [sys.executable, "-I", "-S", str(SCRIPT_DIR / "debug_package_cache.py"), "plan", "--root", "/r",
                "--scripts-dir", "/s", "--build-dir", "/b"]
        fields = [arg for name in dpc.PLAN_FIELDS for arg in ("--field", f"{name}=v")]
        for extra in (["--cache", "maybe", "--cert", "adhoc", *fields],
                      ["--cache", "on", "--cert", SHA_A.lower(), *fields],
                      ["--cache", "on", "--cert", "adhoc", *fields[:-2]],
                      ["--cache", "on", "--cert", "adhoc", *fields, "--field", "CONF=again"],
                      ["--cache", "on", "--cert", "adhoc", *fields, "--field", "UNKNOWN=x"]):
            with self.subTest(extra=extra[:4]):
                result = subprocess.run(base + extra, text=True, capture_output=True)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(result.stdout, "")
        off = subprocess.run(base + ["--cache", "off", "--cert", "adhoc", *fields], text=True, capture_output=True)
        self.assertEqual(off.returncode, 0, off.stderr)
        self.assertTrue(off.stdout.startswith("schema=1\noutcome=fresh\ncache=off\n"))


class PackageScriptStep4Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")

    def stub_root(self) -> Tuple[Path, dict, Path]:
        temp = Path(tempfile.mkdtemp(prefix="rpce-dpc-escape-"))
        self.addCleanup(shutil.rmtree, temp, True)
        root = temp / "repo"
        scripts = root / "Scripts"
        scripts.mkdir(parents=True)
        for name in ("load_release_metadata.sh", "parse_release_metadata.py"):
            shutil.copy2(SCRIPT_DIR / name, scripts / name)
        doctor = scripts / "doctor.sh"
        doctor.write_text("#!/usr/bin/env bash\nexit 42\n", encoding="utf-8")
        doctor.chmod(0o755)
        (root / "version.env").write_text(
            'APP_NAME=RepoPrompt\nDISPLAY_NAME="RepoPrompt CE"\nMARKETING_VERSION=1.0.0\nBUILD_NUMBER=1\n'
            "BUNDLE_ID=com.pvncher.repoprompt.ce\nSIGNING_TEAM_ID=648A27MST5\n", encoding="utf-8")
        manifest = root / ".build" / "release" / "RepoPrompt-artifact-manifest.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_text("stale\n", encoding="utf-8")
        env = {key: value for key, value in os.environ.items() if key != "REPOPROMPT_DEBUG_PACKAGE_CACHE"}
        env.update({"REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR": str(scripts), "REPOPROMPT_RELEASE_SOURCE_ROOT": str(root)})
        return root, env, manifest

    def test_invalid_escape_fails_debug_before_any_mutation_and_release_ignores_it(self) -> None:
        for value in ("bogus", "", "OFF", "1"):
            with self.subTest(value=value):
                _root, env, manifest = self.stub_root()
                env["REPOPROMPT_DEBUG_PACKAGE_CACHE"] = value
                debug = subprocess.run([str(SCRIPT_DIR / "package_app.sh"), "debug"], env=env, text=True, capture_output=True)
                self.assertEqual(debug.returncode, 1, debug.stderr)
                self.assertIn("REPOPROMPT_DEBUG_PACKAGE_CACHE must be 'on' or 'off'", debug.stderr)
                self.assertTrue(manifest.exists(), "invalid escape must fail before removing stale manifests")
                self.assertNotIn("Loading release metadata", debug.stdout)
                release = subprocess.run([str(SCRIPT_DIR / "package_app.sh"), "release"], env=env, text=True,
                                         capture_output=True)
                self.assertEqual(release.returncode, 42, release.stderr)  # reached the stub doctor
                self.assertFalse(manifest.exists())
        for value in ("on", "off", None):
            with self.subTest(value=value):
                _root, env, manifest = self.stub_root()
                if value is not None:
                    env["REPOPROMPT_DEBUG_PACKAGE_CACHE"] = value
                debug = subprocess.run([str(SCRIPT_DIR / "package_app.sh"), "debug"], env=env, text=True, capture_output=True)
                self.assertEqual(debug.returncode, 42, debug.stderr)

    def test_escape_check_precedes_every_mutation(self) -> None:
        check = self.script.index('case "${REPOPROMPT_DEBUG_PACKAGE_CACHE-on}" in')
        self.assertLess(check, self.script.index("remove_stale_artifact_manifests\nsource"))
        self.assertIn('if [[ "$CONF" != "release" ]]; then\n    case "${REPOPROMPT_DEBUG_PACKAGE_CACHE-on}" in', self.script)

    def test_fast_is_parsed_then_inert(self) -> None:
        uses = [line.strip() for line in self.script.splitlines() if "FAST_PACKAGE" in line]
        self.assertEqual(uses, [
            'FAST_PACKAGE_MARKER="${2:-}"',
            'case "$FAST_PACKAGE_MARKER" in',
            '"") FAST_PACKAGE_REQUESTED=0 ;;',
            "fast) FAST_PACKAGE_REQUESTED=1 ;;",
            "*) fail \"Unknown package mode '$FAST_PACKAGE_MARKER'. Expected 'fast' or no package mode.\" ;;",
            "if (( FAST_PACKAGE_REQUESTED )); then",
        ])
        self.assertIn("WARNING: Fast packaging is debug-only; ignoring the 'fast' marker for release packaging.", self.script)
        self.assertNotIn("fast_package_fingerprint", self.script)
        self.assertNotIn("fast-package-verified", self.script)
        self.assertFalse((SCRIPT_DIR / "fast_package_fingerprint.py").exists())

    def test_full_verification_is_unconditional_and_no_non_deep_verify_was_added(self) -> None:
        block = ('\nPACKAGE_TIMING_DEEP="ran"\nrun codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"\n'
                 'verify_signed_app_identity\n'
                 'run "$CONTROL_PLANE_SCRIPTS_DIR/validate_app_architectures.sh" "$APP_BUNDLE" "$ARCHITECTURE_POLICY" '
                 '"Post-sign packaged app"\n')
        self.assertEqual(self.script.count(block), 1)
        smoke = ('\nrun "$RUN_WITHOUT_GITHUB_TOKENS" "$CONTROL_PLANE_SCRIPTS_DIR/smoke_embedded_mcp_helper.sh" '
                 '"$APP_BUNDLE" "Packaged app MCP helper"\n')
        self.assertEqual(self.script.count(smoke), 1)
        verifies = re.findall(r"codesign --verify[^\n]*", self.script)
        self.assertEqual(len(verifies), 2)
        self.assertTrue(all("--deep --strict" in line for line in verifies), verifies)
        self.assertEqual(re.findall(r'PACKAGE_TIMING_DEEP="([^"]*)"', self.script), ["skipped:not-reached", "ran"])

    def test_find_identity_is_one_debug_listing_and_release_keeps_its_query(self) -> None:
        self.assertEqual(self.script.count("security find-identity -v"), 2)
        self.assertIn('CODESIGNING_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"', self.script)
        release = ('    if (( IS_RELEASE )); then\n'
                   '    if ! security find-identity -v -p codesigning | grep -F -- "$SIGN_IDENTITY" >/dev/null 2>&1; then\n'
                   "        echo \"WARNING: SIGN_IDENTITY was not found by exact text in 'security find-identity'; "
                   'codesign will still attempt to use it."\n    fi\n    else\n')
        self.assertIn(release, self.script)
        self.assertIn('AUTO_SIGN_IDENTITY="$(awk -F\'"\' \'/"Apple Development: / { print $2; exit }\' <<< "$CODESIGNING_IDENTITIES")"',
                      self.script)
        auto = self.script.split('if [[ -z "$SIGN_IDENTITY" ]] && (( ! IS_RELEASE ))', 1)[1].split("\nfi\n", 1)[0]
        self.assertIn("load_codesigning_identities", auto)

    def test_plan_runs_debug_only_after_bin_path_and_before_bundle_work(self) -> None:
        plan = self.script.index('debug_package_cache.py" plan')
        guard = self.script.rindex("if (( ! IS_RELEASE )); then", 0, plan)
        self.assertNotIn("\nfi\n", self.script[guard:plan])
        self.assertLess(self.script.index('--show-bin-path)"'), plan)
        self.assertLess(plan, self.script.index("\ngenerate_sentry_debug_symbols\n"))
        self.assertLess(self.script.index("resolve-identity --sign-identity"), plan)
        # Key computation is timed as its own phase, not folded into "Resolving build artifact paths".
        keys_phase = self.script.index('phase "Computing debug package keys"', guard)
        self.assertLess(keys_phase, self.script.index("load_codesigning_identities", guard))

    def test_helper_failure_reports_its_exit_status(self) -> None:
        start = self.script.index('    DEBUG_PACKAGE_HELPER_OUTPUT="$(')
        marker = 'resolve-identity exited with status $?."\n'
        capture = self.script[start:self.script.index(marker, start) + len(marker)]
        probe = ('set -euo pipefail\nfail(){ echo "ERROR: $*" >&2; exit 1; }\n'
                 'python3(){ echo "Traceback: boom" >&2; return 3; }\n'
                 'CONTROL_PLANE_SCRIPTS_DIR=/nonexistent SIGN_IDENTITY=x CODESIGNING_IDENTITIES=\n'
                 f'{capture}echo reached\n')
        result = subprocess.run(["bash", "-c", probe], text=True, capture_output=True)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("debug_package_cache.py resolve-identity exited with status 3.", result.stderr)
        self.assertIn('|| fail "debug_package_cache.py plan exited with status $?."', self.script)

    def reader_probe(self, output: str, *keys: str) -> subprocess.CompletedProcess:
        body = self.script.split("\nread_debug_package_output(){\n", 1)[1].split("\n}\n", 1)[0]
        probe = (f"set -euo pipefail\nfail(){{ echo \"ERROR: $*\" >&2; exit 1; }}\n"
                 f"read_debug_package_output(){{\n{body}\n}}\n"
                 f"read_debug_package_output plan {shlex.quote(output)} {' '.join(keys)}\n"
                 'printf "%s|%s|%s\\n" "${DEBUG_PACKAGE_OUTCOME:-}" "${DEBUG_PACKAGE_CERT:-}" "${DEBUG_PACKAGE_INPUT_KEY:-}"\n')
        return subprocess.run(["bash", "-c", probe], text=True, capture_output=True)

    def test_shell_reader_accepts_known_keys_and_rejects_everything_else(self) -> None:
        good = self.reader_probe("schema=1\noutcome=fresh\ncert=adhoc\ninput_key=a=b", "outcome", "cert", "input_key")
        self.assertEqual((good.returncode, good.stdout), (0, "fresh|adhoc|a=b\n"), good.stderr)
        bad = {
            "outcome=fresh\nschema=1": "expected schema=1 first",
            "schema=2\noutcome=fresh": "expected schema=1 first",
            "schema=1\noutcome=fresh\nsurprise=1": "unknown key 'surprise'",
            "schema=1\noutcome=fresh\noutcome=noop": "printed 'outcome' twice",
            "schema=1": "did not print 'outcome'",
            "schema=1\noutcome=": "empty 'outcome'",
            "": "expected schema=1 first",
        }
        for output, message in bad.items():
            with self.subTest(output=output):
                result = self.reader_probe(output, "outcome")
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(message, result.stderr)


if __name__ == "__main__":
    unittest.main()
