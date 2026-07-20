# `bin/smoke-test` — Design

**Date:** 2026-07-16
**Status:** Approved

## Overview

A fast, committed end-to-end confidence check that the wired-together standalone
JRuby FITS socket server actually works: it boots `bin/fits-server` on a
temporary socket, exercises the three core behaviors (a real examination
succeeds, `STATS` reports metrics, a bad request is rejected), and tears the
server down. It is the everyday "did I break the server?" check to run after a
code change — complementary to, not a replacement for, the RSpec suites.

Reusable by the **project** (a committed script + a `rake smoke` task,
version-controlled, CI-capable), with a thin local `.claude/` wrapper for
in-session ergonomics. This is the deferred "G1 smoke-test skill" from the
dockerize audit, reframed: because `.claude/` is gitignored in this repo, the
durable logic lives in a committed script rather than a gitignored skill file.

## Goals

- Prove the standalone server boots, serves an examination, answers `STATS`, and
  rejects bad input — quickly, with a clear pass/fail signal.
- Be runnable by a human, a rake task, the `.claude/` wrapper, and (safely) CI.
- Distinguish "server is broken" (fail) from "FITS isn't installed here" (skip).

## Non-Goals

- No Docker mode (standalone JRuby server only).
- No exhaustive format coverage (tif/jp2/mp4/mov breadth is the tagged
  integration suite's job).
- No JSON/structured output.
- No RSpec unit tests for the script (running it against the real server IS its
  verification; unit-testing a smoke test with a fake server would defeat its
  purpose).

## Components

### `bin/smoke-test` (committed, executable Ruby)

Pure Ruby using only stdlib (`socket`, `json`, `tmpdir`, `open3`/`Process`).
Flow:

1. **Locate FITS.** `FITS_HOME` from the environment, else default
   `~/tools/fits-1.6.0`. Validity check mirrors `Config#validate_fits_home!`:
   `Dir.exist?(File.join(fits_home, 'lib'))`. If not valid, print
   `SKIP: FITS not found (set FITS_HOME)` and **exit 0** — mirrors the
   integration suite's `skip 'FITS_HOME not set'` so the script is safe to run
   anywhere (including CI) without false failures.

2. **Boot the server.** Spawn `bin/fits-server` with `FITS_HOME` set, a
   temporary socket path under `Dir.mktmpdir`, and `JRUBY_OPTS=-J-Xmx512m` to
   keep the JVM light. Poll for the socket file to appear, up to a generous
   timeout (~30s) to absorb JVM + FITS toolbelt cold-start.

3. **Run three checks** using a small `UNIXSocket` client that writes
   `"<line>\n"` and reads to EOF. Each check prints a `✓`/`✗` line; on failure
   it prints expected-vs-actual. The first examine absorbs cold-start (generous
   first-read handling / one retry):
   - **examine returns FITS XML** — send `spec/fixtures/sample.tif`; assert the
     response starts with `<?xml` and contains `image/tiff`.
   - **STATS returns JSON** — send `STATS`; assert it parses as JSON and
     contains the expected keys (`requests_total`, `heap_used_bytes`,
     `queue_depth`).
   - **bad path rejected** — send a relative path (e.g. `not/absolute.tif`);
     assert the response starts with `ERROR:` and does not start with `<?xml`.

4. **Teardown (always, via `ensure`).** SIGTERM the server, wait for it to exit,
   confirm the socket file is removed. Runs even if a check fails — no orphaned
   JVM. The `Dir.mktmpdir` block cleans the temp dir.

5. **Report + exit.** Final `SMOKE TEST PASSED` (exit 0) or `SMOKE TEST FAILED`
   (exit non-zero if any check failed or the server failed to boot).

### `Rakefile` — `rake smoke`

A thin task that shells out to `bin/smoke-test`, for parity with the existing
`lint` / `audit` / `fixtures` tasks. Not added to the `default` task (it needs a
real FITS install and boots a JVM; it stays opt-in).

### `.claude/commands/smoke.md` (gitignored, local-only) — optional

A thin wrapper command that runs `bin/smoke-test`, for in-session `/smoke`
ergonomics. Because `.claude/` is gitignored, this is a personal convenience,
not shared tooling — the durable logic is the committed script. The plan treats
this as optional.

## Reporting Contract

- Per check: `✓ <description>` on pass, `✗ <description>` on fail followed by
  `    expected: <...>` / `    actual: <...>`.
- Boot failure (socket never appears): `✗ server did not start within <n>s`,
  print any captured server output, then `SMOKE TEST FAILED`, exit non-zero.
- Skip: `SKIP: FITS not found (set FITS_HOME)`, exit 0.
- Final line: `SMOKE TEST PASSED` (exit 0) or `SMOKE TEST FAILED` (exit 1).

## Documentation

A short addition to README's dev workflow: `rake smoke` (or `bin/smoke-test`) as
a quick post-change confidence check against the standalone server, noting it
skips cleanly when FITS is not installed. Existing docs unchanged.

## Testing

The script is verified by running it against the real local FITS during
implementation (expected: three ✓ checks + `SMOKE TEST PASSED`), and by
confirming the skip path (unset/invalid `FITS_HOME` → `SKIP` + exit 0). No new
RSpec specs; existing suites unchanged.

## New / Modified Files

```
fits-jruby/
├── bin/
│   └── smoke-test             # NEW: committed end-to-end smoke check
├── Rakefile                   # MODIFIED: add `smoke` task
├── README.md                  # MODIFIED: mention rake smoke in dev workflow
└── .claude/commands/smoke.md  # NEW but gitignored (optional local wrapper)
```

## Open Questions

None. The `.claude/` wrapper is explicitly optional (local-only, not committed).
