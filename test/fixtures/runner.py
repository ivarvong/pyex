"""
Fixture runner for Pyex conformance tests.

Executes a Python fixture script in a sandboxed environment that captures
stdout and filesystem writes, then emits a JSON manifest to stdout.

Usage:
    python3 test/fixtures/runner.py test/fixtures/programs/my_fixture

The fixture directory must contain a `main.py`. It may optionally contain
a `fs/` subdirectory whose contents are pre-loaded as the virtual filesystem.

Output (JSON on stdout):
    {
        "stdout": "captured print output",
        "files": {"path": "contents", ...},
        "error": null | "traceback string"
    }

Design notes:
    - builtins.open is monkey-patched to intercept all file I/O against an
      in-memory dict.  Only text mode is supported (matching Pyex's scope).
    - The virtual filesystem is seeded from fs/ before execution and any
      writes (including to new paths) are captured.
    - stdin is replaced with an empty StringIO so scripts can't block.
    - We capture stdout via StringIO; stderr is left alone for debugging.
"""

import builtins
import hashlib
import io
import json
import os
import sys
import traceback


class VirtualFile:
    """A minimal file-like object backed by an in-memory string buffer."""

    def __init__(self, path, mode, fs):
        self._path = path
        self._mode = mode
        self._fs = fs

        if "r" in mode:
            if path not in fs:
                raise FileNotFoundError(
                    f"[Errno 2] No such file or directory: '{path}'"
                )
            self._buf = io.StringIO(fs[path])
        elif "w" in mode:
            self._buf = io.StringIO()
            fs[path] = ""
        elif "a" in mode:
            self._buf = io.StringIO(fs.get(path, ""))
            self._buf.seek(0, 2)
        else:
            raise ValueError(f"unsupported mode: '{mode}'")

    def read(self, size=-1):
        return self._buf.read(size)

    def readline(self):
        return self._buf.readline()

    def readlines(self):
        return self._buf.readlines()

    def write(self, data):
        result = self._buf.write(data)
        if "w" in self._mode or "a" in self._mode:
            self._flush_to_fs()
        return result

    def writelines(self, lines):
        for line in lines:
            self.write(line)

    def _flush_to_fs(self):
        pos = self._buf.tell()
        self._buf.seek(0)
        self._fs[self._path] = self._buf.read()
        self._buf.seek(pos)

    def close(self):
        if "w" in self._mode or "a" in self._mode:
            self._flush_to_fs()
        self._buf.close()

    def flush(self):
        if "w" in self._mode or "a" in self._mode:
            self._flush_to_fs()

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        self.close()
        return False

    def __iter__(self):
        return self

    def __next__(self):
        line = self._buf.readline()
        if line:
            return line
        raise StopIteration


def load_input_fs(fs_dir):
    """Recursively read fs/ directory into a flat {path: contents} dict."""
    fs = {}
    if not os.path.isdir(fs_dir):
        return fs
    for root, _dirs, files in os.walk(fs_dir):
        for name in files:
            abs_path = os.path.join(root, name)
            rel_path = os.path.relpath(abs_path, fs_dir)
            with builtins.open(abs_path, "r", encoding="utf-8") as f:
                fs[rel_path] = f.read()
    return fs


def make_open(fs):
    """Return a patched open() that routes all I/O through the virtual fs."""
    real_open = builtins.open

    def virtual_open(file, mode="r", *args, **kwargs):
        # Allow encoding kwarg but ignore it (we're always text/utf-8)
        kwargs.pop("encoding", None)
        kwargs.pop("newline", None)
        kwargs.pop("errors", None)
        if isinstance(file, int):
            return real_open(file, mode, *args, **kwargs)
        return VirtualFile(str(file), mode, fs)

    return virtual_open


def run_fixture(fixture_dir):
    """Execute a fixture and return the result dict."""
    main_py = os.path.join(fixture_dir, "main.py")
    fs_dir = os.path.join(fixture_dir, "fs")

    if not os.path.isfile(main_py):
        return {
            "stdout": "",
            "files": {},
            "error": f"main.py not found in {fixture_dir}",
        }

    with builtins.open(main_py, "r", encoding="utf-8") as f:
        source = f.read()

    # Seed virtual filesystem from fs/ directory
    input_fs = load_input_fs(fs_dir)
    fs = dict(input_fs)

    # Capture stdout
    captured_stdout = io.StringIO()
    old_stdout = sys.stdout
    old_stdin = sys.stdin
    old_open = builtins.open

    try:
        sys.stdout = captured_stdout
        sys.stdin = io.StringIO("")
        builtins.open = make_open(fs)

        exec(
            compile(source, main_py, "exec"),
            {"__name__": "__main__", "__file__": main_py},
        )

        # Determine output files: anything in fs that wasn't in input_fs
        # or has different content than input_fs
        output_files = {}
        for path, content in fs.items():
            if path not in input_fs or input_fs[path] != content:
                output_files[path] = content

        return {
            "stdout": captured_stdout.getvalue(),
            "files": output_files,
            "error": None,
        }
    except Exception:
        return {
            "stdout": captured_stdout.getvalue(),
            "files": {
                path: content
                for path, content in fs.items()
                if path not in input_fs or input_fs[path] != content
            },
            "error": traceback.format_exc(),
        }
    finally:
        sys.stdout = old_stdout
        sys.stdin = old_stdin
        builtins.open = old_open


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <fixture_dir>", file=sys.stderr)
        sys.exit(1)

    fixture_dir = sys.argv[1]
    result = run_fixture(fixture_dir)
    json.dump(result, sys.stdout, ensure_ascii=False, sort_keys=True)


if __name__ == "__main__":
    main()
