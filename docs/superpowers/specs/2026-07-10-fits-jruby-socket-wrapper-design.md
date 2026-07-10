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
- Observable: structured per-request logging and a queryable metrics command.

## Non-Goals (YAGNI for v1)

- Streaming raw file *bytes* over the socket (path-only for now).
- Persistent multi-request connections (one request per connection).
- Parallel *examination* of multiple files (a single serial worker; see
  Concurrency). Note: an acceptor thread runs alongside the worker for queuing,
  but only one FITS examination happens at a time.
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
  request string, it classifies the request as either an examination (an
  absolute path) or the `STATS` command. For an examination it validates the
  path and delegates to an examiner, returning XML bytes or a plain error
  string. For `STATS` it delegates to `Metrics` and returns a JSON blob. Fully
  unit-testable with a mock examiner and a mock metrics source.

- **`Metrics`** — an in-process, thread-safe counters/gauges object. Tracks
  totals (requests, successes, errors), current queue depth, whether a request
  is currently processing, process uptime, and JVM heap (used/max via
  `java.lang.management.ManagementFactory.getMemoryMXBean`). Exposes
  `#snapshot -> Hash` which the `STATS` command renders to JSON. No sockets,
  no FITS — unit-testable in isolation.

- **`SocketServer`** — owns the `UNIXServer` lifecycle and the app-level queue.
  An **acceptor thread** calls `accept` continuously and pushes each accepted
  connection onto a bounded in-process queue (updating the `Metrics` queue-depth
  gauge). A **single worker thread** drains the queue serially: read request ->
  `RequestHandler` -> write response -> close connection -> update `Metrics`.
  Only one FITS examination runs at a time (serial guarantee preserved).
  Handles `SIGINT`/`SIGTERM` for clean shutdown and socket-file cleanup. The
  worker loop is bulletproof: any per-request error is caught, logged, and
  returned to that client; the server never dies from a single bad request.

- **`bin/fits-server`** — thin executable: load `Config` -> build `Metrics` ->
  build `FitsExaminer` -> start `SocketServer`.

The Unix socket uses JRuby's stdlib `UNIXServer`/`UNIXSocket` (`require 'socket'`).

## Configuration (Environment Variables)

| Variable           | Default                      | Purpose                                   |
|--------------------|------------------------------|-------------------------------------------|
| `FITS_HOME`        | *(required)*                 | Path to the FITS install (must contain `lib/`). |
| `FITS_SOCKET_PATH` | `/tmp/fits.sock`             | Filesystem path for the Unix socket.      |
| `FITS_SOCKET_BACKLOG` | `64`                      | Kernel listen backlog for the `UNIXServer` (pre-accept cushion). |
| `FITS_QUEUE_CAPACITY` | `64`                      | Max app-level queue depth; `accept`ed connections beyond this wait on the kernel backlog. |
| `FITS_LOG_LEVEL`   | `info`                       | Logging verbosity (`debug`/`info`/`warn`/`error`). |

Boot validation: if `FITS_HOME` is missing or does not contain `lib/`, log a
clear message and exit non-zero — do not start.

The `/tmp/fits.sock` default is for local development. In production the socket
lives at `/run/fits/fits.sock` (see DEPLOYMENT.md), set via `FITS_SOCKET_PATH`.

## Protocol & Data Flow

### Startup
1. `bin/fits-server` loads `Config` from env vars and validates `FITS_HOME`.
2. Adds the FITS jars to the JRuby classpath and sets `Fits.FITS_HOME`.
3. Builds `Metrics`, then `FitsExaminer` -> constructs the one warm `Fits`
   instance (slow, once), recording process start time for uptime.
4. `SocketServer` unlinks any stale socket file, binds `UNIXServer` at
   `FITS_SOCKET_PATH` with the configured backlog, starts the acceptor and
   worker threads, logs "ready".

### Per request (acceptor thread + single serial worker)
1. The **acceptor thread** `accept`s a connection and enqueues it (incrementing
   the queue-depth gauge). If the app queue is full, further connections wait on
   the kernel backlog — this is how concurrent Sidekiq jobs queue safely (see
   Concurrency).
2. The **worker thread** dequeues a connection (decrementing the gauge, marking
   "processing"), then reads the request: a single line terminated by a newline
   (`\n`), stripped of surrounding whitespace.
3. `RequestHandler` classifies the line:
   - If it equals `STATS` -> return the metrics JSON snapshot (see below).
   - Otherwise treat it as a file path and validate: non-empty, absolute,
     exists, is a regular file, is readable. On any failure return plain error
     text.
4. For a valid path, delegate to `examiner.examine(path)`.
5. On success write the native FITS XML bytes and increment the success counter.
   On any FITS exception write plain error text
   (e.g. `ERROR: examination failed: <message>`) and increment the error counter.
6. Close the connection (one request per connection), clear "processing".
7. Loop back to dequeue.

### Client contract (examination)
Connect -> write `"/abs/path/to/file\n"` -> read until EOF.
- **Success:** well-formed XML beginning with `<?xml`.
- **Failure:** a plain-text line that does not begin with `<?xml`.

Because success always starts with `<?xml` and errors never do, the client
distinguishes the two with a simple prefix check — no need to parse XML just to
detect failure.

### Client contract (metrics)
Connect -> write `"STATS\n"` -> read until EOF. The response is a single JSON
object, for example:

```json
{
  "uptime_seconds": 3820,
  "requests_total": 1502,
  "requests_success": 1487,
  "requests_error": 15,
  "queue_depth": 3,
  "processing": true,
  "heap_used_bytes": 268435456,
  "heap_max_bytes": 1073741824
}
```

`STATS` never runs FITS and does not count toward the examination
success/error counters (it is a control command, not a data request).

### Shutdown
On `SIGINT`/`SIGTERM`: stop accepting, close the socket, unlink the socket
file, exit.

## Concurrency & Queuing

The server processes examinations **serially** — one warm `Fits` instance, one
file at a time — to honor the minimal-heap constraint and to sidestep FITS
thread-safety questions. Serial processing is preserved even though there are
two threads: only the single worker thread ever calls `examine`.

Queuing is handled at the **application level** (rather than relying solely on
the kernel backlog) so that queue depth is exactly observable via `STATS`:

- An **acceptor thread** `accept`s connections as fast as they arrive and pushes
  each onto a bounded in-process queue (`FITS_QUEUE_CAPACITY`, default 64),
  incrementing the queue-depth gauge.
- A **single worker thread** drains the queue FIFO, processing one request at a
  time and decrementing the gauge.

Concurrent Sidekiq jobs therefore queue rather than fail: they connect, the
acceptor enqueues them immediately, and the worker serves them one at a time in
order. If the app queue reaches capacity, additional connections wait in the
kernel listen backlog (a second cushion) instead of being refused. Latency under
burst is roughly the sum of the jobs ahead of you in the queue.

**This queuing behavior must be documented prominently** so callers understand
that concurrent jobs queue rather than fail, that per-request latency grows with
queue depth, and that `queue_depth` from `STATS` is the metric to watch.

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
| Client disconnects mid-write                | Log, drop that connection, continue the worker loop.           |
| Unexpected exception in worker              | Caught at worker-loop level; log full backtrace, close that connection; server stays up. |
| Exception in acceptor thread                | Caught and logged; acceptor keeps accepting; a fatal socket error triggers clean shutdown. |

**Key principle:** the worker loop is bulletproof. Only boot-time config
failure exits the process. Per-request errors still increment the error counter
(except `STATS`, which is a control command).

## Logging

Structured, line-oriented logs to **stdout/stderr** so systemd/journald or
Docker captures them — no separate log file to manage. Level is set via
`FITS_LOG_LEVEL` (default `info`).

- **Startup/shutdown** (`info`): config summary (FITS home, socket path, queue
  capacity), "ready", signal received, clean-shutdown steps.
- **Per examination** (`info`): one line on completion with path, outcome
  (`success`/`error`), and `duration_ms`; the error message on failure.
- **Enqueue/dequeue** (`debug`): queue depth transitions, useful when tuning.
- **Unexpected exceptions** (`error`): full backtrace.

Each log line includes a timestamp and level. `STATS` requests are logged at
`debug` only, to avoid polluting examination logs when a monitor polls
frequently.

## Testing (RSpec, TDD, Layered)

### Fast unit suite (default `rspec` run — no JVM/FITS cost)
- **`RequestHandler`** — path validation (empty, relative, missing, not-a-file,
  unreadable); success delegates to the examiner; a FITS exception becomes error
  text; `STATS` returns the metrics JSON and does not touch the examiner. Uses a
  **mock examiner** and a **mock metrics source**.
- **`Metrics`** — counter/gauge increments and decrements; `#snapshot` shape and
  keys; success/error tallies; uptime and heap fields present. (Heap values come
  from the real JVM MXBean, so assert presence/type rather than exact numbers.)
- **`Config`** — env var parsing, defaults, fail-fast on bad `FITS_HOME`;
  queue-capacity and log-level parsing.
- **`SocketServer`** — connection lifecycle against a real `UNIXServer` but with
  a **fake examiner**: connect -> send path -> assert response bytes ->
  connection closed; a `STATS` request returns JSON; malformed-request handling;
  server survives a handler that raises; metrics counters move as expected.

### Slow integration suite (tagged `:integration`, excluded by default)
- Constructs the **real `Fits`** once and examines the small sample files in
  `spec/fixtures/`, asserting output is well-formed XML starting with `<?xml`
  and containing expected FITS elements (correct MIME type per format).
- End-to-end: boot the real server on a temp socket, connect as a client, send a
  fixture path, assert real FITS XML comes back; also send `STATS` and assert the
  JSON snapshot.

`.rspec`/`spec_helper` tags integration out of the default run; run it with
`rspec --tag integration` (or a rake task) in CI / pre-commit.

**Resource-mindful integration testing.** FITS spawns multiple analysis tools
per file and, unconstrained, will claim a large heap (its own launcher defaults
to `-Xmx6G`). To avoid exhausting system CPU/RAM during tests:
- The integration suite runs the FITS instance with a **constrained heap**
  (e.g. `-Xmx512m`, which is empirically sufficient for the small fixtures) and
  **strictly serially** — one examination at a time, matching production.
- Fixtures are deliberately **tiny** (see below) so each examination is fast and
  cheap; the suite never processes large media.
- The suite is **opt-in** (tagged, off by default) so the fast unit loop stays
  free of JVM cost and no one accidentally runs heavy examinations in a tight
  loop.

### Test fixtures (`spec/fixtures/`)
Small synthetic files representative of the formats normally processed, kept
intentionally tiny (a few KB each) to keep the repo lean and integration tests
cheap:
- `sample.tif` — 32×32 uncompressed baseline TIFF (~6 KB).
- `sample.jp2` — 32×32 JPEG 2000 (~0.5 KB).
- `sample.mp4` — 1-second 64×64 H.264 / MP4 (~3 KB).
- `sample.mov` — 1-second 64×64 QuickTime MOV (~3 KB).

These were generated with ImageMagick, OpenJPEG, and ffmpeg; a rake task
(`rake fixtures`) can regenerate them so they are reproducible rather than
opaque binaries. Larger real-world files can be dropped in locally for ad-hoc
testing but are not committed.

## Linting & Dependency Auditing

- **RuboCop** — checked-in `.rubocop.yml` targeting Ruby 3.1 syntax (matching
  JRuby 9.4.15.0's compatibility level); run via `bundle exec rubocop`. Pure
  Ruby, runs fine on JRuby.
- **bundler-audit** — `bundle exec bundle-audit check --update` scans
  `Gemfile.lock` for known CVEs. Pure Ruby, runs fine on JRuby.
- Both wired into rake tasks (`rake lint`, `rake audit`).
- CI gate order: `rubocop` -> `bundle-audit` -> fast specs -> integration specs.

## JVM & Garbage Collection Tuning (production)

The server is a single long-lived JVM doing serial, short-lived examinations, so
the goals are: small, predictable heap; low pause times; and prompt return of
memory to the OS. Recommended production `JAVA_OPTS` (documented in
DEPLOYMENT.md, overridable via env):

- **Heap:** `-Xms256m -Xmx1g`. FITS runs comfortably under a modest heap for
  ordinary files (a 512 MB heap examined the sample TIFF successfully); 1 GB max
  gives headroom for larger media while staying far below the stock `-Xmx6G`.
  Setting `-Xms` equal-ish avoids growth churn. Tune `-Xmx` up only if `STATS`
  shows `heap_used_bytes` pushing `heap_max_bytes`.
- **Collector:** **G1GC** (`-XX:+UseG1GC`, default on JDK 17) with
  `-XX:MaxGCPauseMillis=200`. G1 suits a small-to-moderate heap with low-pause
  goals and is the safe, well-understood default. (ZGC is unnecessary here — it
  targets very large heaps and adds overhead we do not need.)
- **Return memory to the OS:** `-XX:+UseG1GC` plus
  `-XX:G1PeriodicGCInterval=...` / `-XX:+ExplicitGCInvokesConcurrent` are
  optional; the pragmatic lever is `-XX:MinHeapFreeRatio`/`-XX:MaxHeapFreeRatio`
  to let the heap shrink between bursts. Documented as optional tuning.
- **Container awareness:** if deployed in a container, rely on JDK 17's
  automatic cgroup detection (or set `-XX:MaxRAMPercentage=50`) instead of a
  fixed `-Xmx`.
- **Fail-fast on OOM:** `-XX:+ExitOnOutOfMemoryError` so systemd restarts a
  wedged process rather than leaving it thrashing.

These are starting points; DEPLOYMENT.md explains how to observe `STATS` heap
figures and adjust.

## Documentation (junior-dev readable)

- **README.md** — what it is; quick start; the socket protocol with concrete
  request examples (newline-terminated path via `nc`, `socat`, and a Ruby
  client snippet in Sidekiq style); env var reference; success-vs-error output
  contract; the queuing behavior for concurrent callers; the `STATS` command
  with an example JSON response and a Ruby snippet to query it.
- **INSTALL.md** — step-by-step for a junior dev: install JRuby 9.4.15.0
  (rbenv) + JDK 17; obtain and unzip FITS; set env vars; run the server; verify
  with a sample request.
- **DEPLOYMENT.md** — production guide, targeted at **Ubuntu 22.04 + systemd**:
  - **Service user & socket location:** create a dedicated unprivileged system
    user/group (e.g. `fits`). Place the socket under `/run` (the modern path;
    `/var/run` is a symlink to `/run` on Ubuntu 22.04) in a service-owned
    subdirectory managed by systemd `RuntimeDirectory=fits`, which creates
    `/run/fits` on start and removes it on stop. Socket path:
    `/run/fits/fits.sock` (set `FITS_SOCKET_PATH` accordingly).
  - **Secure permissions:** `RuntimeDirectoryMode=0750` and a socket `umask`
    yielding `0660`, both owned by `fits:fits`. Grant only the calling app's
    account access by adding it to the `fits` group (or via
    `SupplementaryGroups`), so the socket is reachable by the app and no one
    else. No world access; no network exposure (Unix socket only).
  - **Hardened systemd unit** — a complete sample `fits.service` with:
    `User=fits`, `Group=fits`, `RuntimeDirectory=fits`,
    `RuntimeDirectoryMode=0750`, `UMask=0117`; the `JAVA_OPTS` GC/heap settings
    from the JVM section; `Environment=` for `FITS_HOME`, `FITS_SOCKET_PATH`,
    `FITS_QUEUE_CAPACITY`, `FITS_LOG_LEVEL`; hardening directives
    (`NoNewPrivileges=yes`, `ProtectSystem=strict`, `ProtectHome=yes`,
    `PrivateTmp=yes`, `ReadOnlyPaths=` for `FITS_HOME`, `ReadWritePaths=` only
    where needed, `RestrictAddressFamilies=AF_UNIX`, `MemoryMax=` as a hard
    ceiling matching `-Xmx` headroom); `Restart=on-failure`; and journald
    logging (`StandardOutput=journal`).
  - **Filesystem access scoping:** the files FITS examines must be readable by
    the `fits` user; document granting read access to the relevant media
    directories via `ReadOnlyPaths=`/group membership, keeping everything else
    inaccessible.
  - **Performance:** the warm-instance rationale; app-level queue + kernel
    backlog behavior under concurrent Sidekiq load; the JVM/GC tuning above; when
    to consider a FITS-instance pool later.
  - **Monitoring:** how to poll `STATS` (e.g. via `socat`/a small script), what
    each field means, and which signals (rising `queue_depth`, growing
    `heap_used_bytes`, error rate) to alert on.

## Repository Layout (initial)

```
fits-jruby/
├── bin/
│   └── fits-server            # executable entrypoint
├── lib/
│   └── fits_jruby/
│       ├── config.rb
│       ├── fits_examiner.rb
│       ├── metrics.rb
│       ├── request_handler.rb
│       └── socket_server.rb
├── spec/
│   ├── spec_helper.rb
│   ├── fixtures/              # tiny sample files (tif, jp2, mp4, mov)
│   ├── config_spec.rb
│   ├── metrics_spec.rb
│   ├── request_handler_spec.rb
│   ├── socket_server_spec.rb
│   └── integration/
├── docs/
│   └── superpowers/specs/
├── README.md
├── INSTALL.md
├── DEPLOYMENT.md
├── Gemfile
├── Rakefile                   # lint, audit, fixtures, integration tasks
├── .rubocop.yml
├── .rspec
├── .ruby-version
├── .gitignore
└── CLAUDE.md
```

## Open Questions

None. Bootstrap script for downloading FITS and a possible instance-pool for
parallelism are explicitly deferred beyond v1.
