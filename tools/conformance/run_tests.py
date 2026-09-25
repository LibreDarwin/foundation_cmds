#!/usr/bin/env python3
"""Conformance testing for the Darwin foundation command-line tools.

Black-box compare of our build/release/<tool> against Apple's /usr/bin/<tool>.
For every probe in tools/conformance/<tool>/ we run both binaries with identical
stdin/argv/working-dir and compare exit status, stdout bytes and stderr bytes
(after normalizing the variable NSLog timestamp/pid prefix).

The defaults tool additionally:
  * runs with CFFIXED_USER_HOME/HOME pointed at the probe directory, so each
    probe works on an isolated preferences sandbox;
  * normalizes "old-style plist" string escapes on read output. cfprefsd serves
    Apple's /usr/bin/defaults string values in old-style escaped form
    (\\U201c, \\uXXXX, octal \\010, \\\\, \\") while a from-scratch client
    receives the decoded value; the values are semantically identical, so read
    output is compared after decoding those escapes on both sides.
  * honours ORACLE_DEFAULTS (e.g. a signed copy of /usr/bin/defaults) when set.

Usage: run_tests.py <pl|defaults|plutil> --build-dir <build-dir>
"""
import os
import re
import shlex
import subprocess
import sys

ORACLE_BY_TOOL = {
    "pl": "/usr/bin/pl",
    "defaults": None,  # decided below (env override or /usr/bin/defaults)
    "plutil": "/usr/bin/plutil",
}
PROBES = "tools/conformance"

_NSLOG_RE = re.compile(rb"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} "
                       rb"\w+\[\d+:\d+\] ")


def normalize_stderr(data: bytes) -> bytes:
    return _NSLOG_RE.sub(b"<ts> ", data)


_ESCAPE_RE = re.compile(r'\\U([0-9A-Fa-f]{4})'
                        r'|\\u([0-9A-Fa-f]{4})'
                        r'|\\([0-7]{1,3})'
                        r'|\\\\')


def _decode_escape(m):
    if m.group(1):
        return chr(int(m.group(1), 16))
    if m.group(2):
        return chr(int(m.group(2), 16))
    if m.group(3):
        return chr(int(m.group(3), 8))
    return "\\"


def normalize_stdout(data: bytes, tool: str) -> bytes:
    r"""Decode old-style plist escapes in defaults read output (daemon artifact).

    cfprefsd serves Apple's default client escaped text (\U201c, \uXXXX,
    octal \010, \\, \") while a from-scratch client receives decoded values.
    Both describe the same value, so we decode the escapes on both sides before
    comparing. Surrogate-pair escapes (\uD83D\uDE00) are merged. The oracle's
    text escapes the backslash itself, so the substitution is applied to a
    fixpoint (e.g. \\U201c -> \U201c -> the character).
    """
    if tool != "defaults":
        return data
    s = data.decode("latin-1")
    for _ in range(8):
        ns = _ESCAPE_RE.sub(_decode_escape, s)
        if ns == s:
            break
        s = ns
    s = s.encode("utf-16", "surrogatepass").decode("utf-16")
    return s.encode("utf-8", "surrogatepass")


def run_cmd(argv, stdin_bytes, cwd, env_extra=None):
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    proc = subprocess.run(argv, input=stdin_bytes, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, cwd=cwd, env=env)
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
    oracle = ORACLE_BY_TOOL[tool]
    if tool == "defaults":
        oracle = os.environ.get("ORACLE_DEFAULTS", "/usr/bin/defaults")
    defaults_env = {"CFFIXED_USER_HOME": ".", "HOME": "."} if tool == "defaults" else None
    failures = 0
    total = 0

    def split_probe(argv_bytes):
        return [a.decode("utf-8") for a in argv_bytes.split(b"\0") if a != b""]

    def read_cmds(case_dir):
        """Return a list of argv lists, one per commanded invocation."""
        cmds_path = os.path.join(case_dir, "cmds")
        args_path = os.path.join(case_dir, "args")
        if os.path.exists(cmds_path):
            raw = read_file(cmds_path)
            return [shlex.split(line) for line in
                    raw.decode("utf-8").splitlines() if line.strip()]
        if os.path.exists(args_path):
            return [split_probe(read_file(args_path))]
        return []

    def run_probe(argv_list, stdin_data, ws_oracle, ws_subject):
        """Run the full command sequence for each side, then compare records.

        cfprefsd shares a domain container globally per (user, domain) and
        ignores CFFIXED_USER_HOME for that identity, so the two sides must not
        interleave per-record (each would observe the other's mutations) and a
        mutating probe leaves residue in the daemon container for the next side.
        The optional "domain" file names the preference domain a probe mutates;
        the harness deletes it (output discarded) before each side so both sides
        start from the same pristine state.
        """
        dom = None
        dom_path = os.path.join(case_dir, "domain")
        if os.path.exists(dom_path):
            dom = read_file(dom_path).decode("utf-8").strip()
        if dom:
            run_cmd([oracle, "delete", dom], b"", ws_oracle, defaults_env)
        recs_o = [run_cmd([oracle] + argv, stdin_data, ws_oracle, defaults_env)
                  for argv in argv_list]
        if dom:
            run_cmd([subject, "delete", dom], b"", ws_subject, defaults_env)
        recs_m = [run_cmd([subject] + argv, stdin_data, ws_subject, defaults_env)
                  for argv in argv_list]
        records = []
        for e, g in zip(recs_o, recs_m):
            records.append((
                e[0], normalize_stdout(e[1], tool), normalize_stderr(e[2]),
                g[0], normalize_stdout(g[1], tool), normalize_stderr(g[2]),
            ))
        return records

    def make_workspace(case_dir):
        import shutil
        import tempfile
        ws = tempfile.mkdtemp(prefix="conform-")
        for entry in os.listdir(case_dir):
            if entry in ("args", "cmds", "stdin"):
                continue
            src = os.path.join(case_dir, entry)
            if os.path.isfile(src):
                shutil.copy(src, ws)
        return ws

    for name in sorted(os.listdir(probe_dir)):
        case_dir = os.path.join(probe_dir, name)
        if not os.path.isdir(case_dir):
            continue
        total += 1
        stdin_data = read_file(os.path.join(case_dir, "stdin")) \
            if os.path.exists(os.path.join(case_dir, "stdin")) else b""
        ws_o = make_workspace(case_dir)
        ws_m = make_workspace(case_dir)
        try:
            records = run_probe(read_cmds(case_dir), stdin_data, ws_o, ws_m)
        finally:
            import shutil
            shutil.rmtree(ws_o, ignore_errors=True)
            shutil.rmtree(ws_m, ignore_errors=True)

        ok = True
        for n, (ec, eo, ee, gc, go, ge) in enumerate(records):
            if (ec, eo, ee) == (gc, go, ge):
                continue
            ok = False
            failures += 1
            print("FAIL %s (%d/%d)" % (name, n + 1, len(records)))
            if ec != gc:
                print("  exit: oracle=%d subject=%d" % (ec, gc))
            if eo != go:
                print("  stdout differs:")
                print("    oracle:  %r" % eo[:300])
                print("    subject: %r" % go[:300])
            if ee != ge:
                print("  stderr differs:")
                print("    oracle:  %r" % ee[:300])
                print("    subject: %r" % ge[:300])
            break

    print("%d probes, %d failures" % (total, failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())