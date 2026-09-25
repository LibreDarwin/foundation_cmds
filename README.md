# foundation_cmds

Clean-room reimplementation of Apple's `foundation_cmds`: `pl`, `plutil`,
`defaults`.  Byte-identical in behavior to Apple's binaries, BSD-3 licensed.

## Tools

- `pl`      - convert property list files between XML and old-style
              ASCII representations
- `plutil`  - manipulate property list files (lint, convert, extract,
              insert, replace, remove, print)
- `defaults` - read, write and delete the user's defaults (per-user
              preferences database)

## Building

`make` builds all tools into `build/release/`; `make CONFIG=debug` builds
debug variants into `build/debug/`.  Both GNU make and BSD make (bmake) are
supported.

## Layout

- `src/<tool>/<tool>.m` - single-file Objective-C sources, one per tool
- `man/` - man pages
- `tools/conformance/` - black-box conformance corpus comparing against
  Apple's `/usr/bin/<tool>` (stderr timestamps and process ids normalized
  before comparison)