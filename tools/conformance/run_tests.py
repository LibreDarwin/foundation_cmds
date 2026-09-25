#!/usr/bin/env python3
"""Conformance testing for the pl tool.

Black-box compare of our build/release/pl against Apple's /usr/bin/pl.
For every probe in tools/conformance/pl/ we run both binaries with identical
stdin/argv/working-dir and compare exit status, stdout bytes and stderr bytes
(after normalizing the variable NSLog timestamp/pid prefix).

Usage: run_tests.py pl --build-dir <build-dir>
"""
import os
import re
import subprocess
import sys

ORACLE = "/usr/bin/pl"
PROBES = "tools/conformance"

_NSLOG_RE = re.compile(rb"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} "
                       rb"\w+\[\d+:\d+\] ")


def normalize_stderr(data: bytes) -> bytes:
    return _NSLOG_RE.sub(b"<ts> ", data)


def run_cmd(argv, stdin_bytes, cwd):
    proc = subprocess.run(argv, input=stdin_bytes, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, cwd=cwd)
    return proc.returncode & 0xff, proc.stdout, proc.stderr


def read_file(path):
    with open(path, "rb") as fh:
        return fh.read()


def main():
    argv = sys.argv[1:]
    build_dir = None
    tool = None
    for i, a in enumerate(argv):
        if a == "--build-dir" and i + 1 < len(argv):
            build_dir = argv[i + 1]
        elif a in ("pl", "plutil", "defaults"):
            tool = a
    if tool is None or build_dir is None:
        print("usage: run_tests.py <pl|plutil|defaults> --build-dir DIR")
        sys.exit(2)

    subject = os.path.join(os.path.abspath(build_dir), tool)
    probe_dir = os.path.join(os.path.abspath(PROBES), tool)
    failures = 0
    total = 0

    for name in sorted(os.listdir(probe_dir)):
        case_dir = os.path.join(probe_dir, name)
        if not os.path.isdir(case_dir):
            continue
        total += 1
        args = read_file(os.path.join(case_dir, "args")).split(b"\0")
        args = [a.decode("utf-8") for a in args if a != b""]
        stdin_data = read_file(os.path.join(case_dir, "stdin"))
        cwd = case_dir

        exp_code, exp_out, exp_err = run_cmd([ORACLE] + args, stdin_data, cwd)
        got_code, got_out, got_err = run_cmd([subject] + args, stdin_data, cwd)
        exp_err = normalize_stderr(exp_err)
        got_err = normalize_stderr(got_err)

        ok = (exp_code == got_code and exp_out == got_out
              and exp_err == got_err)
        if not ok:
            failures += 1
            print("FAIL %s" % name)
            if exp_code != got_code:
                print("  exit: oracle=%d subject=%d" % (exp_code, got_code))
            if exp_out != got_out:
                print("  stdout differs:")
                print("    oracle:  %r" % exp_out[:300])
                print("    subject: %r" % got_out[:300])
            if exp_err != got_err:
                print("  stderr differs:")
                print("    oracle:  %r" % exp_err[:300])
                print("    subject: %r" % got_err[:300])

    print("%d probes, %d failures" % (total, failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())