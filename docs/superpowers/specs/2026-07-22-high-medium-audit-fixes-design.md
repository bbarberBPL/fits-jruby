# High/Medium audit fixes — design

Date: 2026-07-22

## Purpose

Close the High and Medium findings from the 2026-07-22 three-lens opus audit
(security, concurrency, correctness) of the fits-jruby core. All findings were
verified against the code. None is a default-config remote hole (the server is
a local Unix socket, mode 0660, serial worker); these are latent
correctness/robustness issues worth fixing before they bite in production.

Scope is exactly the High/Medium set: **H1, H2, M1, M2, M3**. The H2 fix
(`SizedQueue#close`) naturally also resolves two Lows on the same code path
(L1 push-blocked acceptor, L12 queue-depth drift); those ride along because
they are the same change. No other Lows (L2–L11) are in scope.

## Findings and fixes

### H1 — Allowlist validates the realpath but examines the raw path

**File:** `lib/fits_jruby/request_handler.rb`

`within_allowed_roots?` computes `real = File.realpath(path)`, checks *that*
against the configured roots, then discards it. `handle` passes the **raw**
request string to `examine`, and `FitsExaminer` re-resolves it at open time —
so the validated path is not the opened path. A static symlink is still caught
(realpath rejects it up front), so exploiting the gap requires a symlink swap
race, and only when `FITS_ALLOWED_ROOTS` is set (off by default). The fix is
correct-by-construction regardless of exploitability: examine the exact path
that was validated.

**Fix:** When an allowlist is configured, thread the canonicalized realpath
through so the path that passed the boundary check is the path handed to
`examine`. When no allowlist is configured (the default, empty list), behavior
is unchanged — the raw absolute path is examined as today (FITS itself
resolves it; there is nothing to confine it to).

Design:
- `within_allowed_roots?` stays a boolean predicate (validation), but the
  canonicalization result is made available to `handle` so it can pass the
  realpath to `examine`. Concretely: `validate_path` continues to return an
  error string or `nil`; on success, `handle` recomputes the examine target as
  the canonical path **only when `@allowed_roots` is non-empty**.
- Introduce a small private helper `examine_target(path)` that returns
  `File.realpath(path)` when `@allowed_roots` is non-empty, else `path`. Both
  the boundary check and the examine call resolve the path the same way, so
  they cannot diverge. `examine_target` is only reached after `validate_path`
  has confirmed the file exists and is within a root, so its `realpath` will
  not raise under normal flow; a `SystemCallError` there is still mapped to
  `ERROR: path not allowed` (fail closed), matching the existing
  `within_allowed_roots?` rescue.

**Tests (fast, no JVM — fake examiner records the path it was handed):**
- Allowlist set, request is a symlink under an allowed root → the fake
  examiner receives the resolved realpath, not the symlink path.
- Allowlist set, request is a plain file under an allowed root → examiner
  receives the realpath (equal to the input when there is no symlink).
- Allowlist **empty** (default) → examiner receives the raw request path
  unchanged (no realpath resolution). This pins the no-confinement contract.
- Allowlist set, path outside roots → `ERROR: path not allowed`, examiner
  never called (unchanged).

### H2 + M1 — Shutdown deadlock and respawn thread-leak

**File:** `lib/fits_jruby/socket_server.rb`

**H2:** `drain_worker` signals shutdown with `@queue.push(SHUTDOWN)`, a blocking
call on a bounded `SizedQueue`. Normal shutdown is safe (a live worker keeps
popping and frees a slot). But if the worker died unexpectedly and is in its
respawn backoff `sleep`, `stop` sets `@running=false`, the worker wakes and
returns without respawning, and the push blocks forever with no consumer —
`stop` never returns, so SIGTERM never completes and systemd falls back to
SIGKILL.

**M1:** The respawn guard (`return unless @running.get`) and the worker
reassignment (`@worker = Thread.new { worker_loop }`) are not atomic w.r.t.
`stop`. A respawning worker can pass the guard, be preempted, have `stop` push
one sentinel and join the *old* worker reference, then spawn W2 — which blocks
forever on an empty queue with no sentinel left. Thread leak.

**Fix (chosen approach — `SizedQueue#close`):** Signal shutdown by closing the
queue instead of pushing a sentinel.
- Remove the `SHUTDOWN` sentinel constant.
- `worker_loop`: `connection = @queue.pop`; `break if connection.nil?`
  (`SizedQueue#pop` returns `nil` once the queue is closed and drained). Every
  worker — including a raced respawn (M1) — exits on `nil`, because `close` is
  a permanent state visible to all poppers.
- `drain_worker`: call `@queue.close` (never blocks) instead of pushing the
  sentinel, then `@worker.join(5)` and `kill` on timeout as today.
- `acceptor_loop`: rescue `ClosedQueueError` from `@queue.push` and
  `safe_close` the in-hand connection before breaking (this is the L1 fix — an
  acceptor blocked in `push` when the queue closes now releases its accepted
  fd instead of leaking it on `kill`).
- `drain_pending_connections`: `SizedQueue#pop(true)` on a closed, empty queue
  raises `ThreadError` (`closed queue`/empty) — the existing rescue already
  covers it. Connections still buffered when the queue closes are drained and
  closed here as today. `pop(true)` returning `nil` (closed + empty) is also
  handled: the loop closes non-nil connections and stops on `nil`/`ThreadError`.
  Verify the exact JRuby 9.4.15.0 behavior in the failing-test step and adapt
  the loop guard accordingly (the test pins whichever it is).

`close` also removes the queue-depth drift (L12) concern's blocking path,
though the gauge itself is cosmetic at shutdown and not otherwise changed here.

**Tests (fast):**
- `stop` returns promptly when the queue is full and the worker is not
  consuming (simulate a full queue + a worker parked so no pop happens; assert
  `stop` completes within a short timeout rather than hanging). This is the
  H2 regression test — it must hang on the old code and pass on the new.
- After `stop`, no live worker thread remains (assert `@worker` is dead) — M1
  regression: exercise a respawn racing `stop` and assert no leaked thread is
  left blocked on `pop`.
- Acceptor with a full queue: when the queue closes, the in-hand connection is
  closed (not leaked) — L1 coverage.
- Normal serve path still works end-to-end (a queued connection is served
  before shutdown) — guards against regressing the happy path.

Note: some of these are timing/thread tests. Use bounded joins/`Timeout` in the
tests so a regression fails fast instead of hanging the suite.

### M2 — Predictable tmpdir socket dir not permission-checked when pre-existing

**Files:** `lib/fits_jruby/socket_server.rb` (`ensure_socket_dir`),
interacts with `lib/fits_jruby/config.rb#default_socket_path`.

`FileUtils.mkdir_p(dir, mode: 0o700)` applies the mode only when *creating* the
directory; on a pre-existing directory it is a silent no-op. In the tmpdir
fallback (`/tmp/fits-<uid>/…`, used only when `XDG_RUNTIME_DIR` is unset), an
attacker who pre-creates `/tmp/fits-<uid>` world-writable and/or owned by
another user is silently trusted.

**Fix (hard failure — confirmed):** After ensuring the parent dir exists,
`lstat` it and **raise at `start`** unless it is a real directory (not a
symlink), owned by the process uid, with mode `0700`. We run unprivileged and
cannot safely repair a dir owned by someone else, so refusing to boot is the
only safe action — loud and supervisor-visible rather than silently insecure.

Design:
- New private method `verify_socket_dir!(dir)` called from `ensure_socket_dir`
  after `mkdir_p`. Uses `File.lstat(dir)`:
  - not a directory, or a symlink (`lstat` so a symlinked dir is rejected) →
    raise.
  - `stat.uid != Process.uid` → raise.
  - `stat.mode & 0o777 != 0o700` → raise.
- Raise a clear error. `start` is not wrapped by `run!`'s `Config::Error`
  rescue, so this surfaces as an unhandled exception that exits non-zero — the
  intended loud failure. Message names the dir and the reason.
- **Scope guard:** apply the check to the tmpdir-fallback case. The XDG /
  systemd runtime dir (`$XDG_RUNTIME_DIR`, `/run/fits`) is created and owned by
  the platform and is not necessarily mode 0700 (XDG_RUNTIME_DIR *is* 0700 per
  spec, but `/run/fits` under systemd is typically 0755 root-or-service-owned),
  so applying a strict 0700+uid check there would break legitimate deployments.
  The check must run **only when the socket path came from the tmpdir
  fallback** — i.e. gate it on the same condition Config uses. Introduce a way
  to know the path is the tmpdir default (e.g. Config exposes
  `default_tmpdir_socket?` / the server checks `ENV['XDG_RUNTIME_DIR']` and
  whether `FITS_SOCKET_PATH` was set). Explicit `FITS_SOCKET_PATH` and the XDG
  case are exempt (operator's responsibility / platform-owned).

**Tests (fast):**
- tmpdir-fallback path, parent dir freshly created 0700 owned by us → `start`
  proceeds (no raise from the check). (Can assert `verify_socket_dir!` passes
  on a `Dir.mktmpdir`-created dir chmod 0700.)
- tmpdir-fallback path, parent dir pre-exists mode 0777 → raise with a clear
  message.
- tmpdir-fallback path, parent dir pre-exists owned by another uid (simulate
  via stubbed `File.lstat` returning a stat with a foreign uid) → raise.
- parent dir is a symlink → raise.
- explicit `FITS_SOCKET_PATH` set → check is skipped (no raise even if the dir
  is 0777), because the operator chose the path.
- `XDG_RUNTIME_DIR` set → check is skipped.

The permission checks are unit-tested at the `verify_socket_dir!` level with a
stubbed `File.lstat` so we don't need to actually create foreign-owned dirs.

### M3 — Integer env vars parsed with implicit radix

**File:** `lib/fits_jruby/config.rb` (`integer_env`)

`Integer(@env.fetch(key, default))` uses implicit radix: `Integer("010")`
returns 8, `Integer("030")` returns 24, and `FITS_READ_TIMEOUT=08` raises
`ArgumentError` → surfaced as `Config::Error "invalid read timeout"`. Operators
reasonably expect base-10 env values.

**Fix:** Force base 10 for string inputs while preserving the Integer default
(`Integer(64, 10)` raises "base specified for non string value", so the default
path must not pass a base):

```ruby
def integer_env(key, default, label)
  raw = @env.fetch(key, default)
  raw.is_a?(Integer) ? raw : Integer(raw, 10)
rescue ArgumentError, TypeError
  raise Error, "invalid #{label}: #{@env[key]}"
end
```

**Tests (fast):**
- `FITS_QUEUE_CAPACITY=010` → 10 (not 8).
- `FITS_READ_TIMEOUT=030` → 30 (not 24).
- `FITS_WRITE_TIMEOUT=08` → 8 (does not raise).
- `0x40` (hex) → rejected as `Config::Error` (base-10 only).
- unset → the Integer default still works (e.g. queue capacity 64).
- genuinely invalid (`abc`) → `Config::Error` as today.

## Non-goals

- No change to the wire protocol, the serial-worker model, or allowlist
  semantics (H1 makes the existing semantics correct, not different).
- No fixes for L2–L11 (non-atomic lifecycle field visibility, mid-exam kill,
  EOF-vs-empty metrics, blocking early-error write, exception-message leak,
  STATS error contract, build_server docstring, installer nesting, reader
  off-by-one, http initial URL). They are logged in the audit for a later pass.
- No new runtime dependencies.

## Testing & process

- TDD (fast/unit default; `:integration` untouched). Each fix is a failing
  test first, then the minimal change.
- Existing suite (86 fast + 4 integration) must stay green; RuboCop clean;
  `rake audit` clean.
- Execution: subagent-driven development, with an **opus reviewer after every
  implementer task** and a final opus whole-branch review before finishing.
