# fits-jruby Socket Wrapper — Design

**Date:** 2026-07-10
**Status:** Approved

## Overview

A long-running JRuby process that keeps a single warm FITS instance in memory
and serves file-examination requests over a Unix domain socket. Callers send an
absolute file path; the server runs FITS against that file and streams back the
native FITS XML.

The core insight: **FITS is a pure Java program** (`edu.harvard.hul.ois.fits.Fits`),
and JRuby runs on the JVM. So JRuby *is* the persistent JVM — we construct one
`Fits` instance at startup (the expensive step that loads all the tool jars),
then reuse it for every request. No Nailgun, no per-request JVM boot.

Nailgun was explicitly rejected: it is unmaintained and deprecated.

## Goals

- Avoid paying JVM + FITS toolbelt startup cost on every file.
- Accept an absolute file path as input, return raw native FITS XML.
- Run lightweight with minimal JVM heap.
- Be callable from a Sidekiq job in a separate application.
- Test-driven with RSpec; a fast unit loop plus a slower integration suite.

## Non-Goals (YAGNI for v1)

- Streaming raw file *bytes* over the socket (path-only for now).
- Persistent multi-request connections (one request per connection).
- Parallel processing of multiple files (serial; see Concurrency).
- The standardized/combined XML output format (native FITS XML only).
- Downloading/installing FITS (a bootstrap script may come later).

## Environment

- JRuby 9.4.15.0 (via rbenv), Ruby 3.1 compatibility level.
- OpenJDK 17 (Java >= 17 required).
- FITS 1.6.0 installed at `~/tools/fits-1.6.0` (jars under `lib/`).

## Architecture & Components

Each component has one clear responsibility and a well-defined interface.

- **`Config`** — reads environment variables with defaults; validates at boot
  (fails fast if `FITS_HOME` is missing or invalid). Exposes typed accessors
  for FITS home, socket path, and backlog size.

- **`FitsExaminer`** — the only component that touches Java/FITS. Constructs
  `new Fits(FITS_HOME)` once and exposes `#examine(path) -> xml_string`
  (calls `fits.examine(java.io.File)`, writes `FitsOutput.output(stream)` into
  a byte stream, returns the XML string). This is the mockable seam that keeps
  the fast unit tests free of JVM/FITS cost.

- **`RequestHandler`** — pure protocol logic; no sockets, no FITS. Given a raw
  request string, it validates the path and delegates to an examiner, returning
  either XML bytes (success) or a plain error string (failure). Fully
  unit-testable with a mock examiner.

- **`SocketServer`** — owns the `UNIXServer` lifecycle: bind (with a generous
  backlog), serial `accept` loop, read request -> `RequestHandler` -> write
  response -> close connection. Handles `SIGINT`/`SIGTERM` for clean shutdown
  and socket-file cleanup. The accept loop is bulletproof: any per-request
  error is caught, logged, and returned to that client; the server never dies
  from a single bad request.

- **`bin/fits-server`** — thin executable: load `Config` -> build
  `FitsExaminer` -> start `SocketServer`.

The Unix socket uses JRuby's stdlib `UNIXServer`/`UNIXSocket` (`require 'socket'`).

## Configuration (Environment Variables)

| Variable           | Default                      | Purpose                                   |
|--------------------|------------------------------|-------------------------------------------|
| `FITS_HOME`        | *(required)*                 | Path to the FITS install (must contain `lib/`). |
| `FITS_SOCKET_PATH` | `/tmp/fits.sock` *(tunable)* | Filesystem path for the Unix socket.      |
| `FITS_SOCKET_BACKLOG` | `64`                      | Kernel listen backlog (queued connections). |

Boot validation: if `FITS_HOME` is missing or does not contain `lib/`, log a
clear message and exit non-zero — do not start.

## Protocol & Data Flow

### Startup
1. `bin/fits-server` loads `Config` from env vars and validates `FITS_HOME`.
2. Adds the FITS jars to the JRuby classpath and sets `Fits.FITS_HOME`.
3. Builds `FitsExaminer` -> constructs the one warm `Fits` instance (slow, once).
4. `SocketServer` unlinks any stale socket file, binds `UNIXServer` at
   `FITS_SOCKET_PATH` with the configured backlog, logs "ready".

### Per request (serial accept loop)
1. `accept` a connection. Other connections wait in the kernel backlog — this
   is how concurrent Sidekiq jobs queue safely (see Concurrency).
2. Read the request: a single **absolute file path terminated by a newline
   (`\n`)**. The path is stripped of surrounding whitespace.
3. `RequestHandler` validates: non-empty, absolute, exists, is a regular file,
   is readable. On any failure it returns plain error text.
4. On valid input, delegate to `examiner.examine(path)`.
5. On success, write the native FITS XML bytes. On any FITS exception, write
   plain error text (e.g. `ERROR: examination failed: <message>`).
6. Close the connection (one request per connection).
7. Loop back to `accept`.

### Client contract
Connect -> write `"/abs/path/to/file\n"` -> read until EOF.
- **Success:** well-formed XML beginning with `<?xml`.
- **Failure:** a plain-text line that does not begin with `<?xml`.

Because success always starts with `<?xml` and errors never do, the client
distinguishes the two with a simple prefix check — no need to parse XML just to
detect failure.

### Shutdown
On `SIGINT`/`SIGTERM`: stop accepting, close the socket, unlink the socket
file, exit.

## Concurrency & Queuing

The server processes requests **serially** — one warm `Fits` instance, one
connection at a time — to honor the minimal-heap constraint and to sidestep
FITS thread-safety questions.

Concurrency safety comes for free from the OS. A Unix domain socket has a
kernel-level **listen backlog**. While one connection is being processed,
additional connections (e.g. from multiple Sidekiq workers) are **not**
refused — the kernel holds them in the backlog queue and `accept` hands them
to us one at a time, FIFO. With a backlog of 64, up to 64 concurrent Sidekiq
jobs can be waiting without connection errors; each simply waits its turn.
Latency under burst is roughly the sum of the jobs ahead of you in the queue.

**This queuing behavior must be documented prominently** so callers understand
that concurrent jobs queue rather than fail, and that per-request latency grows
with queue depth.

Future scaling (out of scope for v1): if serial throughput is insufficient,
introduce a small pool of N `Fits` instances on worker threads for genuine
parallelism, at roughly N× the heap. The design keeps this open by isolating
FITS behind `FitsExaminer`.

## Error Handling

| Situation                                   | Behavior                                                       |
|---------------------------------------------|----------------------------------------------------------------|
| `FITS_HOME` missing/invalid at boot         | Log clear message, exit non-zero (fail fast, do not start).    |
| Stale socket file exists at boot            | Unlink and rebind (log a warning).                             |
| Empty/blank request line                    | `ERROR: empty request`, close.                                 |
| Relative path                               | `ERROR: path must be absolute: <path>`, close.                 |
| File not found / not a regular file / unreadable | `ERROR: <reason>: <path>`, close.                         |
| FITS throws mid-examination                 | Catch, `ERROR: examination failed: <message>`, close; server stays up. |
| Client disconnects mid-write                | Log, drop that connection, continue accept loop.               |
| Unexpected exception in handler             | Caught at accept-loop level; log full backtrace, close that connection; server stays up. |

**Key principle:** the accept loop is bulletproof. Only boot-time config
failure exits the process. Logging goes to stdout/stderr so systemd/journald or
Docker captures it — no separate log file to manage.

## Testing (RSpec, TDD, Layered)

### Fast unit suite (default `rspec` run — no JVM/FITS cost)
- **`RequestHandler`** — path validation (empty, relative, missing, not-a-file,
  unreadable); success delegates to the examiner; a FITS exception becomes error
  text. Uses a **mock examiner**.
- **`Config`** — env var parsing, defaults, fail-fast on bad `FITS_HOME`.
- **`SocketServer`** — connection lifecycle against a real `UNIXServer` but with
  a **fake examiner**: connect -> send path -> assert response bytes ->
  connection closed; malformed-request handling; server survives a handler that
  raises.

### Slow integration suite (tagged `:integration`, excluded by default)
- Constructs the **real `Fits`** once and examines 1–2 small real sample files
  in `spec/fixtures/`, asserting output is well-formed XML starting with `<?xml`
  and containing expected FITS elements.
- End-to-end: boot the real server on a temp socket, connect as a client, send a
  fixture path, assert real FITS XML comes back.

`.rspec`/`spec_helper` tags integration out of the default run; run it with
`rspec --tag integration` (or a rake task) in CI / pre-commit.

## Linting & Dependency Auditing

- **RuboCop** — checked-in `.rubocop.yml` targeting Ruby 3.1 syntax (matching
  JRuby 9.4.15.0's compatibility level); run via `bundle exec rubocop`. Pure
  Ruby, runs fine on JRuby.
- **bundler-audit** — `bundle exec bundle-audit check --update` scans
  `Gemfile.lock` for known CVEs. Pure Ruby, runs fine on JRuby.
- Both wired into rake tasks (`rake lint`, `rake audit`).
- CI gate order: `rubocop` -> `bundle-audit` -> fast specs -> integration specs.

## Documentation (junior-dev readable)

- **README.md** — what it is; quick start; the socket protocol with concrete
  request examples (newline-terminated path via `nc`, `socat`, and a Ruby
  client snippet in Sidekiq style); env var reference; success-vs-error output
  contract; the backlog/queuing behavior for concurrent callers.
- **INSTALL.md** — step-by-step for a junior dev: install JRuby 9.4.15.0
  (rbenv) + JDK 17; obtain and unzip FITS; set env vars; run the server; verify
  with a sample request.
- **DEPLOYMENT.md** — production guide:
  - **Security:** run as an unprivileged user; socket file permissions/ownership
    so only the app user can connect; scope filesystem access; no network
    exposure (Unix socket only); resource limits.
  - **Performance:** the warm-instance rationale; backlog/queuing behavior under
    concurrent Sidekiq load; JVM heap tuning (`-Xmx`) for minimal heap; when to
    consider a FITS-instance pool later.
  - A sample systemd unit.

## Repository Layout (initial)

```
fits-jruby/
├── bin/
│   └── fits-server            # executable entrypoint
├── lib/
│   └── fits_jruby/
│       ├── config.rb
│       ├── fits_examiner.rb
│       ├── request_handler.rb
│       └── socket_server.rb
├── spec/
│   ├── spec_helper.rb
│   ├── fixtures/              # small sample files for integration tests
│   ├── config_spec.rb
│   ├── request_handler_spec.rb
│   ├── socket_server_spec.rb
│   └── integration/
├── docs/
│   └── superpowers/specs/
├── README.md
├── INSTALL.md
├── DEPLOYMENT.md
├── Gemfile
├── .rubocop.yml
├── .rspec
├── .ruby-version
├── .gitignore
└── CLAUDE.md
```

## Open Questions

None. Bootstrap script for downloading FITS and a possible instance-pool for
parallelism are explicitly deferred beyond v1.
