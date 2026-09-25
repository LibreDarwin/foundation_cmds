#!/usr/bin/env python3
"""Generate the tools/conformance/plutil/ probe corpus.

Every probe runs our build/release/plutil against /usr/bin/plutil with identical
stdin/argv/working-dir; the runner compares exit status, stdout bytes and
stderr bytes. Only DETERMINISTIC probes are included:

  * XML output, `-p` output, `-r` (pretty) JSON output, and swift/objc/raw
    literals are key-sorted or order-preserving, so bytes match.
  * Multi-key compact JSON and multi-key binary1 OUTPUT bytes depend on the
    implementation's dictionary iteration order (the oracle itself is flaky),
    so those are excluded. Mutations of multi-key dicts are done in-place and
    verified via a follow-up `-p` (sorted), which is stable.
  * stdin probes read a dedicated `stdin` file (the runner feeds each side its
    own copy), avoiding the shared-fd artifacts seen in shell twin testers.

Run: python3 gen_corpus.py   (regenerates tools/conformance/plutil/*)
"""
import os
import shutil
import subprocess

ROOT = os.path.dirname(os.path.abspath(__file__))
FIX = "/tmp/plref/fixtures"


def w(name, text, suffix):
    p = os.path.join(ROOT, name, suffix)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as fh:
        fh.write(text)


def wargs(name, tokens):
    w(name, b"\0".join(t.encode() for t in tokens) + b"\0", "args")


def wcmds(name, lines):
    w(name, b"\n".join(l.encode() for l in lines) + b"\n", "cmds")


def wstdin(name, data):
    if data:
        w(name, data, "stdin")


def wfix(name, *paths):
    for p in paths:
        shutil.copy2(os.path.join(FIX, p), os.path.join(ROOT, name, p))


def wruns(name, cmds, stdin=b"", *fixes):
    wcmds(name, cmds)
    wstdin(name, stdin)
    for f in fixes:
        wfix(name, f)


REF = "/usr/bin/plutil"


def mkbinary():
    """bplist fixture derived from fw.xml, produced by the oracle so the bytes
    are whatever /usr/bin/plutil actually emits (byte content is irrelevant;
    only the data it decodes matters)."""
    d = os.path.join(ROOT, "_bin")
    os.makedirs(d, exist_ok=True)
    subprocess.run([REF, "-convert", "binary1", "-o",
                    os.path.join(d, "fw.bin"),
                    os.path.join(FIX, "fw.xml")], check=True)


def main():
    for entry in os.listdir(ROOT):
        p = os.path.join(ROOT, entry)
        if os.path.isdir(p) and entry != "_bin":
            shutil.rmtree(p)
    mkbinary()
    B = os.path.join(ROOT, "_bin", "fw.bin")

    # ---- print ----
    wargs("print-json", ["-p", "fw.json"]); wfix("print-json", "fw.json")
    wargs("print-xml", ["-p", "fw.xml"]); wfix("print-xml", "fw.xml")
    wargs("print-binary", ["-p", "fw.bin"]); shutil.copy2(B, os.path.join(ROOT, "print-binary", "fw.bin"))
    wargs("print-deep", ["-p", "deep.xml"]); wfix("print-deep", "deep.xml")
    wargs("print-empty", ["-p", "empty.json"]); wfix("print-empty", "empty.json")
    wargs("print-multi", ["-p", "fw.json", "fw.xml"]); wfix("print-multi", "fw.json", "fw.xml")
    wargs("print-silent-warning", ["-p", "-s", "fw.json"]); wfix("print-silent-warning", "fw.json")
    wargs("print-double-dash", ["-p", "--", "fw.json"]); wfix("print-double-dash", "fw.json")
    wargs("print-missing-file", ["-p", "nope.json"])

    # ---- type ----
    wargs("type-json", ["-type", "fw.json"]); wfix("type-json", "fw.json")
    wargs("type-binary", ["-type", "fw.bin"]); shutil.copy2(B, os.path.join(ROOT, "type-binary", "fw.bin"))
    wargs("type-deep", ["-type", "deep.xml"]); wfix("type-deep", "deep.xml")
    wargs("type-multi", ["-type", "fw.json", "fw.xml"]); wfix("type-multi", "fw.json", "fw.xml")
    wargs("type-missing-file", ["-type", "nope.json"])
    wargs("type-opt-positional", ["-type", "-s", "fw.json"]); wfix("type-opt-positional", "fw.json")
    wargs("type-bare", ["-type"])

    # ---- extract ----
    wargs("extract-int-raw", ["-extract", "a", "raw", "fw.json"]); wfix("extract-int-raw", "fw.json")
    wargs("extract-int-raw-n", ["-extract", "a", "raw", "-n", "fw.json"]); wfix("extract-int-raw-n", "fw.json")
    wargs("extract-string-raw", ["-extract", "s", "raw", "fw.json"]); wfix("extract-string-raw", "fw.json")
    wargs("extract-bool-raw", ["-extract", "n.t", "raw", "fw.json"]); wfix("extract-bool-raw", "fw.json")
    wargs("extract-real-raw", ["-extract", "n.q", "raw", "fw.json"]); wfix("extract-real-raw", "fw.json")
    wargs("extract-array-el-raw", ["-extract", "ar.1", "raw", "fw.json"]); wfix("extract-array-el-raw", "fw.json")
    wargs("extract-deep-raw", ["-extract", "l1.l2.l3.0.deep", "raw", "deep.xml"]); wfix("extract-deep-raw", "deep.xml")
    wcmds("extract-dict-raw-to-file",
          ["-extract n raw -o out.txt fw.json", "-type out.txt"]); wfix("extract-dict-raw-to-file", "fw.json")
    wargs("extract-json-stdout", ["-extract", "ar", "json", "-o", "-", "fw.json"]); wfix("extract-json-stdout", "fw.json")
    wargs("extract-xml-stdout", ["-extract", "a", "xml1", "-o", "-", "fw.json"]); wfix("extract-xml-stdout", "fw.json")
    wargs("extract-json-scalar-invalid", ["-extract", "a", "json", "-o", "-", "fw.json"]); wfix("extract-json-scalar-invalid", "fw.json")
    wargs("extract-emptydict-binary-stdout", ["-extract", "e", "binary1", "-o", "-", "fw.json"]); wfix("extract-emptydict-binary-stdout", "fw.json")
    wargs("extract-int-swift", ["-extract", "a", "swift", "-o", "-", "fw.json"]); wfix("extract-int-swift", "fw.json")
    wargs("extract-int-objc", ["-extract", "a", "objc", "-o", "-", "fw.json"]); wfix("extract-int-objc", "fw.json")
    wargs("extract-swift-header-err", ["-extract", "a", "swift", "-header", "-o", "-", "fw.json"]); wfix("extract-swift-header-err", "fw.json")
    wcmds("extract-inplace-json", ["-extract ar json fw.json", "-p fw.json"]); wfix("extract-inplace-json", "fw.json")
    wargs("extract-missing-path", ["-extract", "nope", "raw", "fw.json"]); wfix("extract-missing-path", "fw.json")
    wargs("extract-no-fmt", ["-extract", "a", "fw.json"]); wfix("extract-no-fmt", "fw.json")
    wargs("extract-bad-fmt", ["-extract", "a", "bogus", "fw.json"]); wfix("extract-bad-fmt", "fw.json")
    wargs("extract-no-file", ["-extract", "a", "raw"])
    wargs("extract-expect-ok", ["-extract", "a", "raw", "-expect", "integer", "fw.json"]); wfix("extract-expect-ok", "fw.json")
    wargs("extract-expect-mismatch", ["-extract", "a", "raw", "-expect", "string", "fw.json"]); wfix("extract-expect-mismatch", "fw.json")
    wargs("extract-expect-invalid", ["-extract", "a", "raw", "-expect", "bogus", "fw.json"]); wfix("extract-expect-invalid", "fw.json")
    wargs("extract-expect-noarg", ["-extract", "a", "raw", "-expect"]); wfix("extract-expect-noarg", "fw.json")

    # ---- convert ----
    wargs("convert-json-xml", ["-convert", "xml1", "-o", "-", "fw.json"]); wfix("convert-json-xml", "fw.json")
    wargs("convert-json-jsonr", ["-convert", "json", "-r", "-o", "-", "fw.json"]); wfix("convert-json-jsonr", "fw.json")
    wargs("convert-xml-jsonr", ["-convert", "json", "-r", "-o", "-", "fw.xml"]); wfix("convert-xml-jsonr", "fw.xml")
    wargs("convert-bin-xml", ["-convert", "xml1", "-o", "-", "fw.bin"]); shutil.copy2(B, os.path.join(ROOT, "convert-bin-xml", "fw.bin"))
    wargs("convert-bin-jsonr", ["-convert", "json", "-r", "-o", "-", "fw.bin"]); shutil.copy2(B, os.path.join(ROOT, "convert-bin-jsonr", "fw.bin"))
    wargs("convert-xml-swift", ["-convert", "swift", "-o", "-", "fw.xml"]); wfix("convert-xml-swift", "fw.xml")
    wargs("convert-xml-objc", ["-convert", "objc", "-o", "-", "fw.xml"]); wfix("convert-xml-objc", "fw.xml")
    wargs("convert-json-swift", ["-convert", "swift", "-o", "-", "fw.json"]); wfix("convert-json-swift", "fw.json")
    wargs("convert-json-objc", ["-convert", "objc", "-o", "-", "fw.json"]); wfix("convert-json-objc", "fw.json")
    wargs("convert-objc-header-stdout", ["-convert", "objc", "-header", "-o", "-", "fw.json"]); wfix("convert-objc-header-stdout", "fw.json")
    wargs("convert-swift-header-err", ["-convert", "swift", "-header", "-o", "-", "fw.json"]); wfix("convert-swift-header-err", "fw.json")
    wargs("convert-multi", ["-convert", "xml1", "-o", "-", "fw.json", "fw.xml"]); wfix("convert-multi", "fw.json", "fw.xml")
    wargs("convert-badfmt", ["-convert", "bogus", "fw.json"]); wfix("convert-badfmt", "fw.json")
    wargs("convert-nofmt", ["-convert", "fw.json"]); wfix("convert-nofmt", "fw.json")
    wargs("convert-missing-o", ["-convert", "xml1", "-o"])
    wcmds("convert-inplace-xml", ["-convert xml1 fw.json", "-p fw.plist"]); wfix("convert-inplace-xml", "fw.json")
    wcmds("convert-inplace-json", ["-convert json fw.xml", "-p fw.json"]); wfix("convert-inplace-json", "fw.xml")
    wargs("convert-empty-binary", ["-convert", "binary1", "-o", "-", "empty.json"]); wfix("convert-empty-binary", "empty.json")
    wargs("convert-empty-jsonr", ["-convert", "json", "-r", "-o", "-", "empty.json"]); wfix("convert-empty-jsonr", "empty.json")
    wargs("convert-dev-null", ["-convert", "xml1", "-o", "/dev/null", "fw.json"]); wfix("convert-dev-null", "fw.json")

    # ---- mutation (in-place then -p to verify, sorted & deterministic) ----
    wcmds("insert-int", ["-insert k -integer 9 fw.json", "-p fw.json"]); wfix("insert-int", "fw.json")
    wcmds("insert-string", ["-insert k -string v fw.json", "-p fw.json"]); wfix("insert-string", "fw.json")
    wcmds("insert-bool", ["-insert k -bool TRUE fw.json", "-p fw.json"]); wfix("insert-bool", "fw.json")
    wcmds("insert-float", ["-insert k -float 2.5 fw.json", "-p fw.json"]); wfix("insert-float", "fw.json")
    wcmds("insert-real", ["-insert k -real 2.5 fw.json", "-p fw.json"]); wfix("insert-real", "fw.json")
    wcmds("insert-array", ["-insert k -array small.json", "-p small.json"]); wfix("insert-array", "small.json")
    wcmds("insert-dict", ["-insert k -dictionary small.json", "-p small.json"]); wfix("insert-dict", "small.json")
    wcmds("insert-data-json-fail", ["-insert d -data aGVsbG8= fw.json", "-p fw.json"]); wfix("insert-data-json-fail", "fw.json")
    wcmds("insert-array-idx", ["-insert a.1 -integer 9 small.json", "-p small.json"]); wfix("insert-array-idx", "small.json")
    wcmds("insert-array-end", ["-insert a.2 -integer 9 small.json", "-p small.json"]); wfix("insert-array-end", "small.json")
    wcmds("insert-array-oob", ["-insert a.3 -integer 9 small.json", "-p small.json"]); wfix("insert-array-oob", "small.json")
    wcmds("insert-dup-key", ["-insert a -integer 1 fw.json", "-p fw.json"]); wfix("insert-dup-key", "fw.json")
    wcmds("insert-bad-path", ["-insert nope.x -integer 1 fw.json", "-p fw.json"]); wfix("insert-bad-path", "fw.json")
    wargs("insert-unknown-type", ["-insert", "k", "-bogus", "fw.json"]); wfix("insert-unknown-type", "fw.json")
    wargs("insert-bare", ["-insert"])
    wargs("insert-no-value", ["-insert", "k"])
    wargs("insert-value2", ["-insert", "k", "-string", "-o", "-", "fw.json"]); wfix("insert-value2", "fw.json")
    wargs("insert-value2-bare", ["-insert", "k", "-string"]); wfix("insert-value2-bare", "fw.json")
    wcmds("append-array", ["-insert a -integer 9 -append small.json", "-p small.json"]); wfix("append-array", "small.json")
    wargs("append-nonarray", ["-insert", "s", "-string", "yy", "-append", "fw.json"]); wfix("append-nonarray", "fw.json")
    wcmds("replace-int", ["-replace m -integer 9 small.json", "-p small.json"]); wfix("replace-int", "small.json")
    wcmds("replace-string", ["-replace s -string hello fw.json", "-p fw.json"]); wfix("replace-string", "fw.json")
    wcmds("replace-array-idx", ["-replace a.1 -integer 9 small.json", "-p small.json"]); wfix("replace-array-idx", "small.json")
    wcmds("replace-array-oob", ["-replace a.9 -integer 9 small.json", "-p small.json"]); wfix("replace-array-oob", "small.json")
    wcmds("replace-missing", ["-replace nope -string x small.json", "-p small.json"]); wfix("replace-missing", "small.json")
    wcmds("remove-key", ["-remove s fw.json", "-p fw.json"]); wfix("remove-key", "fw.json")
    wcmds("remove-array-el", ["-remove a.0 small.json", "-p small.json"]); wfix("remove-array-el", "small.json")
    wargs("remove-missing-path", ["-remove", "nope", "fw.json"]); wfix("remove-missing-path", "fw.json")
    wargs("remove-array-oob", ["-remove", "a.9", "small.json"]); wfix("remove-array-oob", "small.json")
    wargs("mutate-no-file", ["-insert", "k", "-integer", "9"])

    # ---- lint ----
    wargs("lint-xml-ok", ["-lint", "fw.xml"]); wfix("lint-xml-ok", "fw.xml")
    wargs("lint-bin-ok", ["-lint", "fw.bin"]); shutil.copy2(B, os.path.join(ROOT, "lint-bin-ok", "fw.bin"))
    wargs("lint-json-fails", ["-lint", "fw.json"]); wfix("lint-json-fails", "fw.json")
    wargs("lint-garbage", ["-lint", "garbage.txt"]); wfix("lint-garbage", "garbage.txt")
    wargs("lint-missing", ["-lint", "nope.plist"])
    wargs("lint-silent", ["-lint", "-s", "fw.xml"]); wfix("lint-silent", "fw.xml")
    wargs("lint-multi", ["-lint", "fw.xml", "fw.bin", "garbage.txt"]); wfix("lint-multi", "fw.xml", "garbage.txt"); shutil.copy2(B, os.path.join(ROOT, "lint-multi", "fw.bin"))
    wargs("lint-o-used", ["-lint", "-o", "x", "fw.xml"]); wfix("lint-o-used", "fw.xml")
    wargs("lint-e-used", ["-lint", "-e", "x", "fw.xml"]); wfix("lint-e-used", "fw.xml")

    # ---- stdin ----
    with open(os.path.join(FIX, "fw.xml"), "rb") as fh:
        xml = fh.read()
    with open(os.path.join(FIX, "fw.json"), "rb") as fh:
        js = fh.read()
    with open(os.path.join(FIX, "garbage.txt"), "rb") as fh:
        garbage = fh.read()
    with open(B, "rb") as fh:
        binb = fh.read()
    wargs("stdin-print", ["-p", "-"]); wstdin("stdin-print", xml)
    wargs("stdin-convert-jsonr", ["-convert", "json", "-r", "-o", "-", "-"]); wstdin("stdin-convert-jsonr", js)
    wargs("stdin-convert-xml", ["-convert", "xml1", "-o", "-", "-"]); wstdin("stdin-convert-xml", js)
    wargs("stdin-convert-binary", ["-convert", "xml1", "-o", "-", "-"]); wstdin("stdin-convert-binary", binb)
    wargs("stdin-lint-ok", ["-lint", "-"]); wstdin("stdin-lint-ok", xml)
    wargs("stdin-lint-json", ["-lint", "-"]); wstdin("stdin-lint-json", js)
    wargs("stdin-lint-garbage", ["-lint", "-"]); wstdin("stdin-lint-garbage", garbage)
    wargs("stdin-print-empty", ["-p", "-"]); wstdin("stdin-print-empty", b"")
    wargs("stdin-print-dashdash", ["-p", "--", "-"]); wstdin("stdin-print-dashdash", xml)

    # ---- create ----
    wcmds("create-xml-default", ["-create xml1", "-p fw.plist"])
    wcmds("create-xml-o", ["-create xml1 -o new.plist", "-p new.plist"])
    wargs("create-json-stdout", ["-create", "json", "-o", "-"])
    wcmds("create-binary-type", ["-create binary1 -o new.bin", "-type new.bin"])
    wargs("create-swift", ["-create", "swift", "-o", "-"])
    wargs("create-objc", ["-create", "objc", "-o", "-"])
    wargs("create-badfmt", ["-create", "bogus"])
    wargs("create-nofmt", ["-create"])
    wargs("create-to-dir", ["-create", "xml1", "-o", "dout"])

    # ---- options / errors ----
    wargs("help-short", ["-h"])
    wargs("help-long", ["--help"])
    wargs("no-args", [])
    wargs("unrecognized-opt", ["-zz"])
    wargs("print-o-used", ["-p", "-o", "x", "fw.json"]); wfix("print-o-used", "fw.json")
    wargs("print-e-used", ["-p", "-e", "x", "fw.json"]); wfix("print-e-used", "fw.json")
    wargs("print-token-dash", ["-p", "-", "fw.json"]); wstdin("print-token-dash", xml); wfix("print-token-dash", "fw.json")

    shutil.rmtree(os.path.join(ROOT, "_bin"))


if __name__ == "__main__":
    main()