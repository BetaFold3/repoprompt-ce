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
        self.assertNotIn("import subprocess", helper, "helper must not shell out")


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


if __name__ == "__main__":
    unittest.main()
