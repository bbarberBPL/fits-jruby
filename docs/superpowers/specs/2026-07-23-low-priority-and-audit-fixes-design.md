# Low-Priority & Audit Fixes — Design Spec

**Date:** 2026-07-23
**Branch:** `feature/low-priority-and-audit` (off `main` @ 14ca4c6)
**Predecessor:** the High/Medium audit-fix branch (merged as #8). This is the
follow-up pass the H/M PR's "Non-goals" section deferred ("Lows L2–L11 are
logged in the audit for a later pass").

## Goal

Close the remaining Low-priority audit findings plus the new bugs surfaced by a
fresh security/performance/correctness sweep of the changed surface, and bring
the user-facing documentation back into agreement with the code. No wire-protocol
change, no change to the serial-worker model, no allowlist-semantics change.

## Scope origin

Two parallel opus discovery agents (code audit + doc audit) ran against the
post-merge `main`. Their findings were consolidated (12 code + 3 doc) and triaged
with the user. The user approved the **full** code scope (all four tiers) and
**all three** doc fixes, with two design decisions recorded below. Every finding
in this spec was independently reproduced or line-verified against the current
tree; the exact file:line anchors appear per finding.

## Design decisions (settled with the user)

- **L4** → add a new `client_disconnects` counter to `Metrics` and its snapshot,
  and short-circuit `serve` when the client closes before sending a line, so a
  bare connect/close is no longer miscounted as a request error.
- **L3 + NEW-2** → **document trade-offs only, no code/config change.** The
  bounded-5s shutdown kill (L3) and the serial-worker + per-connection
  read-timeout head-of-line behavior (NEW-2) are deliberate designs; they get a
  short "Operational trade-offs" note in the docs, not a code change.
- **L9** (installer redirect recursion, build-time style) → **document as a known
  limitation, no code change.** It is bounded (`MAX_REDIRECTS = 5`), build-time
  only, and integrity is protected by the SHA-256 pin.

---

## Global Constraints

- **JRuby only** (jruby-9.4.15.0, Ruby 3.1.7 compat, OpenJDK 17). Run lightweight;
  no new runtime dependencies.
- **TDD with RSpec is mandatory.** Fast unit specs are the default; integration
  specs are `:integration`-tagged. Every behavioral change lands with a test that
  is proven RED on the old code and GREEN on the new.
- **No wire-protocol / semantics drift.** Responses remain: FITS XML on success
  (`<?xml…`), `ERROR: …` lines for every failure. `record_outcome` classifies by
  those two prefixes — any new error string MUST begin with `ERROR:` so it is
  counted as an error, not a success.
- **`rake lint` (RuboCop) and `rake audit` (bundler-audit) stay clean.**
- Commit trailer EXACTLY: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Only the current developer pushes/creates remotes; Claude creates local commits
  and branches only.
- Reviewers are **opus**; implementers are chosen by task complexity with
  **sonnet as the floor**; final whole-branch review is opus.

---

## Findings & fixes

Each finding lists: current anchor, the defect, the fix, and the test that proves it.

### CODE — Tier 1 (correctness / security)

#### NEW-1 — `ArgumentError` on a NUL-byte path escapes the fail-closed rescue
- **Anchor:** [lib/fits_jruby/request_handler.rb:57](lib/fits_jruby/request_handler.rb#L57) (`stat_check` → `File.exist?(path)`), rescue at [:50](lib/fits_jruby/request_handler.rb#L50).
- **Defect:** With an allowlist configured, a request path containing a NUL byte
  (`"/allowed/x\0/etc/passwd"`) reaches `File.exist?`, which raises
  `ArgumentError: string contains null byte`. `ArgumentError` is **not** a
  `SystemCallError`, so it escapes the `rescue SystemCallError` fail-closed guard,
  propagates to `serve`'s generic `rescue StandardError`, and the client gets no
  structured response (connection closed, request logged as a worker error). The
  path is never adjudicated against the allowlist. Reproduced.
- **Fix:** Reject a NUL byte (and any embedded control that `File.*` would choke
  on) as a normal, fail-closed validation error **before** any filesystem call.
  Add to `stat_check`, as the first check after the absolute-path check, a
  guard that rejects a path containing a NUL byte — `path.include?("\x00")`
  (the NUL is written as the escape `"\x00"`, not a raw byte) →
  `return "ERROR: path not allowed: #{path}"`.
  Belt-and-suspenders: widen the `resolve_target` rescue to also catch
  `ArgumentError` so any other `File.*` argument rejection still fails closed
  rather than crashing the worker. The returned string uses the existing
  `path not allowed` wording so the wire contract is unchanged.
- **Test:** `spec/request_handler_spec.rb` — with an allowlist set, a NUL-byte
  path returns `ERROR: path not allowed:` (proven RED: old code raises
  `ArgumentError` out of `handle`). Add a second test asserting `handle` never
  raises for a NUL path regardless of allowlist state.

#### L10 — Request byte-cap is off-by-one and chunk-timing dependent
- **Anchor:** [lib/fits_jruby/connection_reader.rb:37](lib/fits_jruby/connection_reader.rb#L37) (`read_nonblock(@max_bytes - buf.length + 1, …)`), size check at [:46](lib/fits_jruby/connection_reader.rb#L46), after the newline check at [:43-44](lib/fits_jruby/connection_reader.rb#L43-L44).
- **Defect:** The `+ 1` on the read size lets the buffer accumulate up to
  `@max_bytes + 1` bytes, and the size cap (`buf.length >= @max_bytes`) is checked
  **after** the newline scan. So whether an identical over-length input is
  accepted or rejected depends on how the bytes were chunked by the kernel — the
  effective cap oscillates between `max_bytes` and `max_bytes + 1`. Empirically
  verified as non-deterministic across chunk boundaries.
- **Fix:** Make the contract precise and chunk-independent: **a request line,
  including its trailing newline, may be at most `@max_bytes` bytes; a buffer that
  reaches `@max_bytes` with no newline raises `RequestTooLong`.** Drop the `+ 1`
  (read `@max_bytes - buf.length`, so `buf` never exceeds `@max_bytes`). Keep the
  newline check before the size check so a line of exactly `@max_bytes` bytes
  ending in `\n` is accepted, and `RequestTooLong` fires only when `@max_bytes`
  bytes arrive with no newline. This is deterministic regardless of chunking.
  (When `buf.length == @max_bytes` the loop always raises before it would call
  `read_nonblock(0)`, so no zero-length spin.) Update the class doc comment to
  state the exact contract.
- **Test:** `spec/connection_reader_spec.rb` via `UNIXSocket.pair` — (a) a line of
  exactly `max_bytes` bytes incl. newline is returned intact; (b) `max_bytes`
  bytes with no newline raises `RequestTooLong`; (c) **the same over-length input
  delivered in two different chunk splittings yields the same `RequestTooLong`
  result** (this is the regression that proves the timing-dependence is gone —
  RED on old code for at least one split). Use a small injected `max_bytes` so the
  tests are fast and readable.

### CODE — Tier 2 (robustness)

#### NEW-3 — Full-response copy on the first write when `offset == 0`
- **Anchor:** [lib/fits_jruby/socket_server.rb:253](lib/fits_jruby/socket_server.rb#L253).
- **Defect:** `response.byteslice(offset, total - offset)` allocates a full copy of
  the (potentially large FITS-XML) response on the first loop iteration, when
  `offset == 0` and the slice equals the whole string. On the common path (whole
  response fits the send buffer, one write) that doubles peak memory for the
  response for no reason — counter to the lightweight-heap constraint.
- **Fix:** Write the original string directly when `offset == 0`; only allocate a
  slice for the tail on later iterations:
  `chunk = offset.zero? ? response : response.byteslice(offset, total - offset)`.
  Behavior is otherwise identical (`write_nonblock` on the full binary string).
- **Test:** `spec/socket_server_spec.rb` — existing `write_response` behavior tests
  (full-write success, partial-write loop, timeout → false, EPIPE → false) must
  stay green. Add an assertion that the first `write_nonblock` call receives the
  original response object (`equal?`/same object id) when it fits in one write, so
  a regression that reintroduces the copy is caught. Verify the partial-write path
  still reassembles the exact bytes.

#### NEW-4 — Request logged verbatim (log-forging surface)
- **Anchor:** [lib/fits_jruby/socket_server.rb:286](lib/fits_jruby/socket_server.rb#L286) (`"examine path=#{request} …"`).
- **Defect:** The request string is interpolated raw into the log line. The line
  protocol strips the trailing newline, but embedded control characters (and the
  general risk of interpolating untrusted input into a structured log line) let a
  client forge/pollute log fields. Low severity (local socket), but trivially
  hardened.
- **Fix:** Log `request.inspect` (quotes + escapes control chars) instead of the
  bare value: `@logger.info("examine path=#{request.inspect} outcome=#{outcome} duration_ms=#{duration_ms}")`.
- **Test:** `spec/socket_server_spec.rb` — a request containing a newline/control
  char is logged with the escaped (`inspect`) form; assert the raw control char
  does not appear in the captured log output. Use an injected logger writing to a
  `StringIO`.

#### L5 — `write_read_error` uses a blocking write
- **Anchor:** [lib/fits_jruby/socket_server.rb:231](lib/fits_jruby/socket_server.rb#L231) (`connection.write(message)`).
- **Defect:** The early-exit error responses (read timeout, request too long) are
  sent with a blocking `connection.write`. A client that triggers the error and
  then never reads can wedge the single worker thread on that write once the send
  buffer fills — the exact head-of-line hazard that `write_response` was built to
  avoid on the success path. The success path is bounded; the error path is not.
- **Fix:** Route `write_read_error` through the same bounded non-blocking writer.
  Reuse `write_response(connection, message)` (it already records the error metric
  on timeout/peer-close and returns a boolean). Concretely: `write_read_error`
  calls `write_response`; on a `false` return the error metric is already recorded
  by `write_response`, and on `true` it records the error metric itself.
  Reconcile the metric bookkeeping so a read-error is counted exactly once
  (`write_response` records on the failure branch; the caller records on success —
  never both, never zero). Keep the method's "best-effort, client may be gone"
  contract.
- **Test:** `spec/socket_server_spec.rb` — (a) a read-timeout/too-long response is
  delivered to a reading client and `record_error` is incremented exactly once;
  (b) a non-reading client that fills the buffer does **not** block the worker past
  `write_timeout` (bounded — proven RED on the blocking `write`, using a short
  injected `write_timeout` and a peer that never reads); the worker stays
  responsive to the next queued connection.

#### L6 — `examine` leaks the internal exception message to the client
- **Anchor:** [lib/fits_jruby/request_handler.rb:72-73](lib/fits_jruby/request_handler.rb#L72-L73).
- **Defect:** `rescue StandardError => e … "ERROR: examination failed: #{e.message}"`
  returns the raw internal error message (potentially a stack detail, absolute
  path, or FITS/Java internals) over the wire, and does **not** log it
  server-side — so operators lose the detail while the client gains it. Backwards.
- **Fix:** Return a generic, stable client message (`"ERROR: examination failed"`)
  and log the full `e.class`/`e.message`/backtrace server-side. `RequestHandler`
  currently has no logger; add an optional `logger:` constructor keyword
  defaulting to a null sink (`Logger.new(File::NULL)` or a tiny null-logger
  object) so existing callers and specs are unaffected, and wire the real server
  logger in from `Runner`/wherever `RequestHandler` is constructed. Keep the
  `ERROR:` prefix so `record_outcome` still counts it as an error.
- **Test:** `spec/request_handler_spec.rb` — an examiner that raises
  `RuntimeError.new("secret /internal/path detail")` yields exactly
  `ERROR: examination failed` on the wire (no `secret`/path substring), and the
  injected logger receives a line containing the class and original message.
  Update any existing spec asserting the old `examination failed: <msg>` string.

### CODE — Tier 3 (observability / contract)

#### L4 — Bare connect/close miscounted; add `client_disconnects` counter
- **Anchors:** [lib/fits_jruby/socket_server.rb:212-213](lib/fits_jruby/socket_server.rb#L212-L213) (`raw = read_line…; @handler.handle(raw.to_s)`); [lib/fits_jruby/metrics.rb:25-65](lib/fits_jruby/metrics.rb#L25-L65).
- **Defect:** `read_line` returns `nil` on EOF (client connected then closed
  without sending a line). `raw.to_s` turns that into `""`, `handle("")` returns
  `ERROR: empty request`, and `record_outcome` counts it as a **request error** —
  polluting the error rate with benign disconnects and with health-check probes
  that open/close.
- **Fix (per the settled decision):**
  1. `Metrics`: add a monotonic `client_disconnects` counter — a
     `record_client_disconnect` method (mutex-protected, mirrors `record_error`)
     and a `client_disconnects: @client_disconnects` entry in `snapshot`
     (initialized to `0` in `initialize`).
  2. `SocketServer#serve`: after `raw = @reader.read_line(...)`, short-circuit on
     EOF — `if raw.nil?` → `@metrics.record_client_disconnect`, log at debug, and
     return (the `ensure` still closes the connection). Do **not** call `handle`,
     `write_response`, or `record_outcome` for a disconnect.
- **Non-goal:** an actual empty line (`"\n"`) is a real (malformed) request and
  still returns `ERROR: empty request` counted as an error — only true EOF
  (`nil`) is a disconnect.
- **Tests:**
  - `spec/metrics_spec.rb` — `record_client_disconnect` increments; `snapshot`
    includes `client_disconnects` with the correct count; other counters
    unaffected.
  - `spec/socket_server_spec.rb` — a client that connects and closes without
    sending increments `client_disconnects` and does **not** increment
    `requests_error` (proven RED: old code increments `requests_error`); a normal
    empty-line request still counts as an error.

#### L7 — `STATS` has no defined behavior when the snapshot fails
- **Anchor:** [lib/fits_jruby/request_handler.rb:21](lib/fits_jruby/request_handler.rb#L21) (`@metrics.snapshot.to_json`); snapshot's heap read at [lib/fits_jruby/metrics.rb:52](lib/fits_jruby/metrics.rb#L52).
- **Defect:** If `snapshot` raises (e.g. the JVM heap-bean read throws), the
  `STATS` command propagates the exception to `serve`'s generic rescue: the client
  gets no response and the failure is logged as a generic worker error. There is
  no defined `STATS`-unavailable contract.
- **Fix:** In `handle`, guard the `STATS` branch: rescue a snapshot/serialization
  failure and return a stable `ERROR: stats unavailable` line (counted as an error
  by `record_outcome`). Log the underlying cause via the same injected logger
  added for L6.
- **Test:** `spec/request_handler_spec.rb` — a metrics double whose `snapshot`
  raises makes `handle("STATS")` return `ERROR: stats unavailable` (not raise);
  the logger receives the cause. Normal `STATS` still returns the JSON snapshot.

### CODE — Tier 4 (installer)

#### L11 — Initial installer URL scheme not asserted https
- **Anchor:** [lib/fits_jruby/fits_installer.rb:37](lib/fits_jruby/fits_installer.rb#L37) (`use_ssl: uri.scheme == 'https'`).
- **Defect:** Redirects are forced to https ([:50](lib/fits_jruby/fits_installer.rb#L50)),
  but the **initial** URL's scheme is only reflected into `use_ssl`, never
  asserted. A caller/config passing an `http://` URL would fetch over plaintext.
  The default URL is https and the SHA-256 pin protects integrity, so this is
  defense-in-depth, not an active hole.
- **Fix:** In `fetch_to_file`, fail closed on a non-https initial URL, mirroring
  the redirect guard's wording:
  `raise Error, "refusing insecure URL #{url} (expected https)" unless uri.scheme == 'https'`.
- **Test:** `spec/fits_installer_spec.rb` — `fetch_to_file` (or an injected
  downloader path) raises `FitsInstaller::Error` for an `http://` URL before any
  network call; an `https://` URL proceeds (using the existing stubbed
  HTTP/downloader seam). Reuse the existing installer test harness.

### CODE — Document-only (no code change)

- **L3 (bounded-5s shutdown kill)** — [socket_server.rb:95-98](lib/fits_jruby/socket_server.rb#L95-L98). `drain_worker` joins the
  worker for 5s then `kill`s it. A single in-flight examination longer than 5s is
  force-killed on shutdown. This is deliberate (bounded, supervisor-visible
  shutdown). Document as an operational trade-off. **No code change.**
- **NEW-2 (serial-worker head-of-line latency)** — one worker drains the queue
  serially with a per-connection read timeout; a slow/idle client occupies the
  worker only until its `read_timeout`, but a large valid examination blocks the
  queue for its duration. Deliberate (the whole point of the serial model).
  Document as an operational trade-off. **No code change.**
- **L9 (installer redirect recursion)** — [fits_installer.rb:35-52](lib/fits_jruby/fits_installer.rb#L35-L52). Redirects recurse inside
  the open `Net::HTTP.start` block; bounded at `MAX_REDIRECTS = 5`, build-time
  only, integrity SHA-pinned. Document as a known limitation. **No code change.**

### DOCS

#### Doc-M — `DEPLOYMENT.md` "install under service user's home" contradicts the hardened unit
- **Anchor:** [DEPLOYMENT.md:13-14](DEPLOYMENT.md#L13-L14) — a two-part prerequisite
  ("JRuby … via rbenv under the service user's home, **or** installed to a shared
  prefix such as `/usr/local`"). The **first** alternative contradicts the rest of
  the doc: `--no-create-home` ([:35](DEPLOYMENT.md#L35)) gives the service user no
  home, `ProtectHome=yes` ([:123](DEPLOYMENT.md#L123)) makes any home unreadable to
  the unit, and the ExecStart is hardcoded to `/usr/local/bin/jruby`
  ([:103](DEPLOYMENT.md#L103)) — the second (shared-prefix) alternative.
- **Fix:** Drop the "rbenv under the service user's home" alternative and keep only
  the shared-prefix install at `/usr/local/bin/jruby` that the unit file already
  requires. (Rbenv-under-home is fine for a dev checkout, but not for the hardened
  systemd unit this doc describes.) Verify no other line still implies a
  per-user-home JRuby for the service.

#### Doc-L — STATS counters described as "examinations" (README + DEPLOYMENT)
- **Anchors:** [README.md:222-224](README.md#L222-L224); [DEPLOYMENT.md:267-269](DEPLOYMENT.md#L267-L269).
- **Defect (precise):** Both tables gloss `requests_success`/`requests_error` as
  "Examinations that returned FITS XML / an error." But `requests_error` also
  counts protocol/validation errors that never reached the examiner (empty
  request, non-absolute path, no such file, path not allowed, read timeout,
  request too long) — so the "examination" framing understates what
  `requests_error` covers. (DEPLOYMENT.md already correctly notes `requests_total`
  "Does not count `STATS` calls"; README does not.)
- **Fix:** Ground the wording in `record_outcome`, which increments
  `requests_success` only for an `<?xml`-prefixed response and `requests_error`
  only for an `ERROR:`-prefixed response; a `STATS` JSON reply is neither, so it
  is not counted by either. State precisely: `requests_error` counts **all** error
  responses — protocol/validation errors and examination failures alike — not only
  failed examinations; `requests_total = requests_success + requests_error` and
  excludes `STATS`. Carry the "does not count `STATS`" note into README's table
  too. Add `client_disconnects` (new, from L4) to the documented STATS fields in
  **both** docs, described as benign connect-without-request events (health checks,
  aborted clients) that are counted separately and are **not** errors.

#### Doc-L — `INSTALL.md` hardcodes `/tmp/fits-$(id -u)` instead of honoring `$TMPDIR`
- **Anchor:** [INSTALL.md:218](INSTALL.md#L218) — current line:
  `FITS_SOCKET="${FITS_SOCKET_PATH:-${XDG_RUNTIME_DIR:-/tmp/fits-$(id -u)}/fits.sock}"`.
- **Defect (precise):** The line already honors `FITS_SOCKET_PATH` and
  `XDG_RUNTIME_DIR` (matching `Config#default_socket_path`). The **only** mismatch
  is the innermost fallback: it hardcodes `/tmp`, whereas the code uses
  `Dir.tmpdir`, which honors `$TMPDIR` (falling back to `/tmp` only when `$TMPDIR`
  is unset). A host with a non-default `$TMPDIR` would compute a different socket
  path than the doc shows.
- **Fix:** Change only the innermost fallback from `/tmp` to `${TMPDIR:-/tmp}`, so
  the line reads
  `FITS_SOCKET="${FITS_SOCKET_PATH:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}/fits-$(id -u)}/fits.sock}"`.
  Leave the `FITS_SOCKET_PATH`/`XDG_RUNTIME_DIR` precedence untouched (already
  correct).

#### Doc — Operational trade-offs note (L3 / NEW-2 / L9)
- **Location:** a short "Operational trade-offs" subsection in `DEPLOYMENT.md`
  (and/or README as fits the existing structure).
- **Content:** (1) shutdown force-kills an examination still running after a 5s
  grace; (2) the single serial worker processes one examination at a time —
  throughput is one-at-a-time by design, and a large file blocks the queue for its
  duration while idle clients are bounded by `FITS_READ_TIMEOUT`; (3) the
  build-time installer follows up to 5 https redirects, integrity-checked by the
  pinned SHA-256. No code/config knobs are implied by this note.

#### CLAUDE.md / code comments
- Review `CLAUDE.md` and touched code comments for any statement contradicted by
  the above changes (e.g. the L10 contract, the L6 error wording, the new
  `client_disconnects` metric). Update in the same task that changes the code, so
  comments never drift from behavior. No CLAUDE.md change is anticipated beyond
  verification, but confirm.

---

## Proposed task decomposition (phased single branch)

Each task ends with an independently testable, committable deliverable; a reviewer
can accept or reject one without the others. Ordered so correctness/security land
first and docs land last (docs reference the final metric/contract names).

1. **Task 1 — NEW-1 + L10** (request_handler NUL/rescue; connection_reader byte-cap
   contract). Two small, self-contained correctness fixes with deterministic tests.
   *Implementer: sonnet.*
2. **Task 2 — L6 + L7** (request_handler: generic examine error + logger injection;
   STATS-unavailable contract). Grouped because both add/consume the new injected
   logger in the same file. *Implementer: sonnet.*
3. **Task 3 — NEW-3 + NEW-4 + L5** (socket_server write path: no-copy first write,
   `inspect` log, bounded read-error write). All in `write_response`/`serve`
   /`log_request`; the metric-once reconciliation for L5 needs care.
   *Implementer: sonnet, escalate to opus if the L5 metric bookkeeping proves
   subtle under test.*
4. **Task 4 — L4** (metrics `client_disconnects` counter + serve EOF short-circuit).
   Touches `metrics.rb` and `socket_server.rb`. *Implementer: sonnet.*
5. **Task 5 — L11** (installer initial-URL https assertion). Single-file, single
   guard. *Implementer: sonnet (cheapest tier — near-transcription).*
6. **Task 6 — Docs** (DEPLOYMENT install path, README/DEPLOYMENT STATS wording +
   `client_disconnects`, INSTALL tmpdir, operational-trade-offs note for
   L3/NEW-2/L9, CLAUDE.md/comment verification). Docs-only; lands last so the STATS
   field names match the shipped code. *Implementer: sonnet.*

Each task: opus review after the implementer. Final opus whole-branch review before
finishing the branch. Full verification gate: fast suite + `:integration` +
`rake lint` + `rake audit`, all clean.

## Explicit non-goals

- No change to the wire protocol, the response prefixes, the serial-worker model,
  the queue/backpressure design, or allowlist semantics.
- No new configuration knobs or environment variables.
- No new runtime dependencies.
- No code change for L3, NEW-2, or L9 (documentation only, per the settled
  decisions).

## Risks & mitigations

- **L5 metric double/zero-count.** Routing read-errors through `write_response`
  (which already records on failure) risks counting an error twice or not at all.
  *Mitigation:* the L5 test asserts `record_error` fires **exactly once** on both
  the success and the timeout branch.
- **L6 logger wiring.** Adding a constructor keyword can break existing
  construction sites/specs. *Mitigation:* default to a null sink so all existing
  callers are unaffected; wire the real logger only where the server builds the
  handler; run the full request_handler spec.
- **L10 contract change is observable.** The precise cap is a (tiny) behavior
  change at the boundary. *Mitigation:* the chunk-split determinism test plus an
  exact-boundary accept/reject pair pin the new contract; the class doc states it.
- **Doc/code drift.** *Mitigation:* docs task lands last and each STATS field is
  cross-checked against `Metrics#snapshot` as shipped.
