# Deferred audit items, convenience API, and doc polish — design

Date: 2026-07-22

## Purpose

Close out the audit-hardening follow-ups: the four deferred "Low" findings, a
convenience API so the server can be started with one call instead of the
30-line assembly in `bin/fits-server`, targeted documentation edits, and a Ruby
version directive in the Gemfile.

## Scope

### 1. Convenience API in `lib/fits_jruby.rb` (build + run! pair)

Currently `bin/fits-server` (lines 8–32) does the whole assembly by hand:
validate config → build metrics/examiner/handler/server → install INT/TERM
signal traps → start → sleep. Move that into the top-level module.

- `FitsJruby.build_server(config: Config.new)` — assembles the object graph
  (`Metrics` → `FitsExaminer` → `RequestHandler` with `allowed_roots:` →
  `SocketServer`) and returns the `SocketServer`. No validation, no signal
  traps, no `sleep` — pure assembly, so it is unit-testable with no side
  effects.
- `FitsJruby.run!(config: Config.new)` — the entrypoint behavior:
  `config.validate!` (converting `Config::Error` into a `warn` + `exit 1`, as
  `bin/fits-server` does today), `build_server`, install INT/TERM traps that
  call `server.stop` then `exit 0`, `server.start`, then `sleep`. Never
  returns under normal operation.
- Keep the existing `require_relative`s in `lib/fits_jruby.rb`.
- `bin/fits-server` collapses to essentially `require 'fits_jruby'` +
  `FitsJruby.run!`, preserving the `$LOAD_PATH` shim.

### 2. Deferred audit Lows (all four)

- **`/tmp` default socket → per-user runtime dir.** `DEFAULT_SOCKET_PATH`
  becomes dynamic:
  - `"#{ENV['XDG_RUNTIME_DIR']}/fits.sock"` when `XDG_RUNTIME_DIR` is set and
    non-empty, otherwise
  - `"#{Dir.tmpdir}/fits-#{Process.uid}/fits.sock"`.

  An explicit `FITS_SOCKET_PATH` still overrides and is used verbatim.
  `SocketServer#start` ensures the socket's **parent directory** exists
  (`FileUtils.mkdir_p` with mode `0700`) before `UNIXServer.new` — a no-op when
  the directory already exists (the XDG runtime dir, or systemd's pre-created
  `/run/fits`). This removes the shared predictable `/tmp/fits.sock` path while
  keeping a plain `bundle exec ruby bin/fits-server` working out of the box.

- **https-only redirects.** In `FitsInstaller.handle_response`, when following a
  redirect, reject any `location` whose scheme is not `https` (fail closed) so
  the pinned download cannot be silently downgraded to plaintext http. The
  SHA-256 pin already protects integrity; this closes the transport gap.

- **start/stop interleaving guard.** `SocketServer#start` raises if the server
  is already running (`@running.get` is true), turning a double-start into a
  clear error instead of a leaked listener/threads. Single-entrypoint use is
  unaffected.

- **perf micro-hygiene.** Only clearly-safe, no-behavior-change hygiene in hot
  paths (e.g. avoid a redundant re-strip / freeze a constant reply). Skip
  anything speculative; the serial worker is not allocation-bound.

### 3. Documentation

- **DEPLOYMENT.md**: rename the OS service-account username examples
  `sidekiq`/`rails` → `avi`/`deployer` (Step 2 and any related mentions).
  Leave framework references such as "Sidekiq workers"/"Sidekiq threads"
  untouched — those name the calling client, not an OS account. Add
  `/usr/local/tools/fits-1.6.0` as an alternative `FITS_HOME` alongside the
  existing `/opt/fits-1.6.0` examples (including `ReadOnlyPaths=` if relevant).
- **INSTALL.md**: add `/usr/local/tools/fits-1.6.0` as an alternative
  `FITS_HOME` alongside the existing `~/tools/fits-1.6.0`. (INSTALL.md has no
  service-account username examples, so no rename there.)
- **README.md**: update the `FITS_SOCKET_PATH` default description and the
  `/tmp/fits.sock` command examples to reflect the new dynamic default
  (per-user runtime dir).

### 4. Gemfile

Add the JRuby version directive:

```ruby
ruby '3.1.7', engine: 'jruby', engine_version: '9.4.15.0'
```

(Ruby compat 3.1.7 as reported by the installed jruby-9.4.15.0.)

## Testing (TDD, fast/unit)

- `build_server` returns a `SocketServer` with the handler wired to
  `config.allowed_roots` (object-graph assembly).
- Config default socket path: `XDG_RUNTIME_DIR` set → `<xdg>/fits.sock`;
  unset/empty → `<tmpdir>/fits-<uid>/fits.sock`; explicit `FITS_SOCKET_PATH`
  overrides both.
- `SocketServer#start` creates the parent dir (mode `0700`) when missing, and
  raises on a second `start` while running.
- `FitsInstaller` refuses an http `location` on redirect (raises `Error`).

Existing suite must stay green (86 fast + 4 integration) and RuboCop clean.

## Non-goals

- No change to the wire protocol, the serial-worker model, or the allowlist
  semantics.
- No renaming of client-framework references (Sidekiq) in prose.
- No new runtime dependencies.
