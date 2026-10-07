#!/usr/bin/env python3
"""Cached-import entry point for the RepoPrompt CE conductor.

Running ``Scripts/conductor.py`` directly executes it as ``__main__``, which
CPython compiles from source on every start. This entry instead imports
``conductor.py`` as the module ``rpce_conductor``, so its bytecode is cached,
and then runs the same command line. Direct execution of ``conductor.py`` keeps
working.

Stale-code safety: a timestamp ``.pyc`` is validated only by the source's
whole-second mtime and size, so a same-size edit within the same mtime second
would run old code. Before importing, the entry therefore makes sure that the
conductor and the local modules it imports have *checked-hash* bytecode, which
every import validates against a hash of the current source. Any cache that is
missing, malformed (a bad header, or a body that does not unmarshal to a code
object), written by another interpreter, or timestamp or unchecked based is
recompiled once in checked-hash mode. This check runs before any conductor code
executes, so a corrupt cache never fails the import. If a cache cannot be written, or
bytecode writes are disabled while a cache is not checked-hash, the process
imports through a fresh, empty, private ``sys.pycache_prefix`` with bytecode
writes disabled (never an old cache) and removes that prefix at exit.
"""

import importlib.util
import marshal
import os
import sys

MODULE_NAME = "rpce_conductor"
# conductor.py and the local modules it imports.
CACHED_SOURCES = ("conductor.py", "debug_app_process.py", "swift_pipeline_metrics.py", "conductor_output.py")
# PEP 552 flags: hash-based (bit 0) with check_source (bit 1).
CHECKED_HASH_FLAGS = 0b11


def has_checked_hash_bytecode(cfile: str) -> bool:
    """Whether ``cfile`` is checked-hash bytecode this interpreter can load.

    The header must carry this interpreter's magic and the checked-hash flags,
    and the body must unmarshal to a code object; otherwise import itself
    would fail on it. Source staleness is left to import's hash validation.
    """
    try:
        with open(cfile, "rb") as handle:
            data = handle.read()
    except OSError:
        return False
    if not (
        len(data) > 16
        and data[:4] == importlib.util.MAGIC_NUMBER
        and int.from_bytes(data[4:8], "little") == CHECKED_HASH_FLAGS
    ):
        return False
    try:
        code = marshal.loads(memoryview(data)[16:])
    except (EOFError, ValueError, TypeError):
        return False
    return isinstance(code, type(has_checked_hash_bytecode.__code__))


def use_private_empty_cache() -> str:
    """Import through a fresh empty cache prefix, write nothing, remove it at exit."""
    import atexit
    import shutil
    import tempfile

    prefix = tempfile.mkdtemp(prefix="rpce-conductor-pycache-")
    sys.pycache_prefix = prefix
    sys.dont_write_bytecode = True
    atexit.register(shutil.rmtree, prefix, True)
    return prefix


def ensure_checked_hash_bytecode(scripts_dir: str) -> bool:
    """Bootstrap checked-hash bytecode for the conductor sources in ``scripts_dir``.

    Returns ``True`` when every present source has checked-hash bytecode, and
    ``False`` after falling back to a private empty cache prefix.
    """
    pending = []
    for name in CACHED_SOURCES:
        source = os.path.join(scripts_dir, name)
        if not os.path.isfile(source):
            continue
        cfile = importlib.util.cache_from_source(source)
        if not has_checked_hash_bytecode(cfile):
            pending.append((source, cfile))
    if not pending:
        return True
    if not sys.dont_write_bytecode:
        import py_compile

        try:
            for source, cfile in pending:
                # Written atomically, so concurrent first imports each install a complete file.
                py_compile.compile(
                    source,
                    cfile=cfile,
                    doraise=True,
                    invalidation_mode=py_compile.PycInvalidationMode.CHECKED_HASH,
                )
            return True
        except (OSError, py_compile.PyCompileError):
            # Unwritable cache, or a source that does not compile; the import
            # below then reports any real error from source.
            pass
    use_private_empty_cache()
    return False


def load_conductor(scripts_dir: str) -> object:
    """Import ``<scripts_dir>/conductor.py`` as ``rpce_conductor``.

    ``scripts_dir`` must be on ``sys.path`` (it is, when this file runs as a
    script), because the conductor imports ``debug_app_process`` by name.
    """
    from importlib.machinery import SourceFileLoader

    ensure_checked_hash_bytecode(scripts_dir)
    path = os.path.join(scripts_dir, "conductor.py")
    spec = importlib.util.spec_from_file_location(MODULE_NAME, path, loader=SourceFileLoader(MODULE_NAME, path))
    module = importlib.util.module_from_spec(spec)
    sys.modules[MODULE_NAME] = module  # dataclasses resolve their defining module here
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(MODULE_NAME, None)
        raise
    return module


def main() -> int:
    scripts_dir = os.path.dirname(os.path.realpath(__file__))
    conductor = load_conductor(scripts_dir)
    # Usage text names conductor.py, as when it runs directly.
    sys.argv[0] = conductor.__file__
    return conductor.cli_main(sys.argv[1:])


if __name__ == "__main__":
    raise SystemExit(main())
