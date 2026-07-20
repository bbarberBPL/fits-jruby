# bin/smoke-test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a committed `bin/smoke-test` that boots the standalone JRuby FITS server on a temp socket, verifies three core behaviors (examine → FITS XML, STATS → JSON, bad path → ERROR), tears it down, and reports pass/fail via exit code — plus a `rake smoke` task and a README mention.

**Architecture:** A single executable Ruby script using only stdlib. It reuses the proven spawn/poll/teardown and UNIXSocket request patterns from `spec/integration/end_to_end_spec.rb`. It skips cleanly (exit 0) when FITS is not installed, so it is safe to run anywhere including CI.

**Tech Stack:** Ruby stdlib (`socket`, `json`, `tmpdir`), `bin/fits-server` (existing), JRuby 9.4.15.0, FITS 1.6.0.

## Global Constraints

- JRuby only, jruby-9.4.15.0; target Ruby 3.1 syntax in RuboCop; `frozen_string_literal: true` after the shebang.
- The script uses ONLY Ruby stdlib (no gems).
- FITS location: `ENV['FITS_HOME']` else default `~/tools/fits-1.6.0`. Validity check is exactly `Dir.exist?(File.join(fits_home, 'lib'))` (matches `Config#validate_fits_home!`).
- If FITS is not valid: print `SKIP: FITS not found (set FITS_HOME)` and **exit 0** (mirrors the integration suite's skip; NOT a failure).
- Boot the server with `JRUBY_OPTS=-J-Xmx512m` and a temp socket under `Dir.mktmpdir`; poll for the socket up to ~30s (JVM + FITS cold-start).
- Three checks (per-check `✓`/`✗`, expected-vs-actual on failure): examine `spec/fixtures/sample.tif` → response starts with `<?xml` and contains `image/tiff`; `STATS` → parses as JSON with keys `requests_total`, `heap_used_bytes`, `queue_depth`; a relative path (`not/absolute.tif`) → response starts with `ERROR:` and NOT `<?xml`.
- Teardown ALWAYS runs (ensure): SIGTERM the server, `Process.wait`, rescue `Errno::ESRCH`/`ECHILD` — no orphan JVM.
- Final line: `SMOKE TEST PASSED` (exit 0) or `SMOKE TEST FAILED` (exit 1 on any check failure or boot failure).
- No Docker mode; no RSpec unit tests for the script (running it IS the verification); no JSON output.
- Only the current developer pushes/sets remotes; this plan makes local commits only.

## Reference Patterns (verified, from `spec/integration/end_to_end_spec.rb`)

- Spawn: `spawn({ 'FITS_HOME' => fits_home, 'FITS_SOCKET_PATH' => socket, 'JRUBY_OPTS' => '-J-Xmx512m' }, 'bin/fits-server')`.
- Poll: `120.times { break if File.socket?(socket); sleep 0.25 }` (~30s).
- Request: `UNIXSocket.open(socket) { |s| s.write("#{line}\n"); s.read }`.
- Teardown: `Process.kill('TERM', pid)` rescue `Errno::ESRCH`; `Process.wait(pid)` rescue `Errno::ECHILD`, `Errno::ESRCH`.
- Existing rake tasks in `Rakefile`: `spec`, `integration`, `lint`, `audit`, `fixtures`, `default: %i[spec lint]`.

## File Structure

- `bin/smoke-test` — NEW. The whole smoke check (locate FITS, boot, 3 checks, teardown, report). One clear responsibility.
- `Rakefile` — MODIFIED. Add a `smoke` task shelling out to `bin/smoke-test`.
- `README.md` — MODIFIED. One dev-workflow mention.

---

## Task 1: bin/smoke-test script

**Files:**
- Create: `bin/smoke-test`

**Interfaces:**
- Consumes: `bin/fits-server` (existing executable), `spec/fixtures/sample.tif` (committed fixture).
- Produces: an executable `bin/smoke-test`. Exit 0 = passed or skipped; exit 1 = failed. No importable API (it is a script).

Design notes for the implementer:
- Structure the script with small helpers: `fits_home`, `valid_fits?(path)`, `wait_for_socket(path, tries)`, `request(socket, line)`, and a `check(description) { ... }` helper that runs a block returning `[ok, expected, actual]`, prints `✓`/`✗` (+ expected/actual on fail), and records failure in a module-level counter/flag.
- Boot inside a `Dir.mktmpdir` block so the temp socket dir is always cleaned. Use an `ensure` for server teardown so it runs even if a check raises.
- The FIRST examine may hit JVM + FITS cold-start; the socket poll already waits for boot, but allow a single retry on the first examine if the response comes back empty (cold-start race), matching behavior observed during dockerization. Keep it simple: one retry.
- Do not add a `require 'fits_jruby'` — the script talks to the server over the socket like any external client; it must not load the app in-process.

- [ ] **Step 1: Write the script**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

# End-to-end smoke test for the standalone FITS socket server.
# Boots bin/fits-server on a temp socket, verifies examine/STATS/error
# behavior, tears down, and exits non-zero on any failure. Skips (exit 0)
# when FITS is not installed. Talks to the server only over the socket.
require 'socket'
require 'json'
require 'tmpdir'

FIXTURE = File.expand_path('../spec/fixtures/sample.tif', __dir__)
SOCKET_TRIES = 120 # x 0.25s ~= 30s for JVM + FITS cold-start

@failed = false

def fits_home
  ENV['FITS_HOME'] && !ENV['FITS_HOME'].empty? ? ENV['FITS_HOME'] : File.expand_path('~/tools/fits-1.6.0')
end

def valid_fits?(path)
  Dir.exist?(File.join(path, 'lib'))
end

def wait_for_socket(path, tries)
  tries.times do
    return true if File.socket?(path)

    sleep 0.25
  end
  false
end

def request(socket, line)
  UNIXSocket.open(socket) do |sock|
    sock.write("#{line}\n")
    sock.read
  end
end

# Runs a check block that returns [ok, expected, actual]. Prints ✓/✗ and
# records failure. Rescues so one failing check cannot abort the run.
def check(description)
  ok, expected, actual = yield
  if ok
    puts "✓ #{description}"
  else
    @failed = true
    puts "✗ #{description}"
    puts "    expected: #{expected}"
    puts "    actual:   #{actual}"
  end
rescue StandardError => e
  @failed = true
  puts "✗ #{description}"
  puts "    error: #{e.class}: #{e.message}"
end

home = fits_home
unless valid_fits?(home)
  puts 'SKIP: FITS not found (set FITS_HOME)'
  exit 0
end

Dir.mktmpdir('fits-smoke') do |dir|
  socket = File.join(dir, 'smoke.sock')
  pid = spawn(
    { 'FITS_HOME' => home, 'FITS_SOCKET_PATH' => socket, 'JRUBY_OPTS' => '-J-Xmx512m' },
    'bin/fits-server'
  )

  begin
    unless wait_for_socket(socket, SOCKET_TRIES)
      @failed = true
      puts "✗ server did not start within #{(SOCKET_TRIES * 0.25).round}s"
      raise 'boot failed'
    end

    check('examine returns FITS XML (image/tiff)') do
      xml = request(socket, FIXTURE)
      xml = request(socket, FIXTURE) if xml.to_s.empty? # one retry for cold-start race
      ok = xml.start_with?('<?xml') && xml.include?('image/tiff')
      [ok, 'starts with <?xml and includes image/tiff', xml.to_s[0, 80]]
    end

    check('STATS returns JSON with expected keys') do
      body = request(socket, 'STATS')
      snap = JSON.parse(body)
      keys = %w[requests_total heap_used_bytes queue_depth]
      [keys.all? { |k| snap.key?(k) }, "JSON with keys #{keys.join(', ')}", body[0, 120]]
    end

    check('bad path is rejected with ERROR (not XML)') do
      resp = request(socket, 'not/absolute.tif')
      ok = resp.start_with?('ERROR:') && !resp.start_with?('<?xml')
      [ok, 'starts with ERROR:', resp.to_s[0, 80]]
    end
  rescue RuntimeError
    # boot failure already recorded; fall through to teardown + report
  ensure
    begin
      Process.kill('TERM', pid)
    rescue Errno::ESRCH
      nil
    end
    begin
      Process.wait(pid)
    rescue Errno::ECHILD, Errno::ESRCH
      nil
    end
  end
end

if @failed
  puts 'SMOKE TEST FAILED'
  exit 1
else
  puts 'SMOKE TEST PASSED'
  exit 0
end
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x bin/smoke-test`
Expected: `ls -l bin/smoke-test` shows the `x` bit.

- [ ] **Step 3: Run it against the real local FITS (the primary verification)**

Run: `./bin/smoke-test`
Expected: three `✓` lines (examine, STATS, bad-path) then `SMOKE TEST PASSED`; exit 0. The first examine boots the real FITS toolbelt (~10-20s). Confirm the exit code with `echo $?` → `0`. Paste the output into the report.

- [ ] **Step 4: Verify the skip path**

Run: `FITS_HOME=/nonexistent ./bin/smoke-test; echo "exit=$?"`
Expected: prints `SKIP: FITS not found (set FITS_HOME)` and `exit=0`.

- [ ] **Step 5: Rubocop**

Run: `bundle exec rubocop bin/smoke-test`
Expected: clean. If `Metrics/MethodLength`/`AbcSize`/`BlockLength` trips on the main flow, extract small helpers rather than disabling cops; a targeted, commented disable is acceptable if a helper split would hurt readability — note it in the report. (Note: the repo-wide `bundle exec rubocop` may not include `bin/smoke-test` by default; run it explicitly here.)

- [ ] **Step 6: Commit**

```bash
git add bin/smoke-test
git commit -m "feat: add bin/smoke-test standalone end-to-end smoke check"
```

---

## Task 2: rake smoke task + README mention

**Files:**
- Modify: `Rakefile`
- Modify: `README.md`

**Interfaces:**
- Consumes: `bin/smoke-test` (Task 1).
- Produces: a `rake smoke` task; a README dev-workflow mention.

- [ ] **Step 1: Add the smoke task to the Rakefile**

Add this task (after the existing `audit` task, before the `default` line):

```ruby
desc 'End-to-end smoke test against the standalone server (skips if FITS absent)'
task :smoke do
  sh './bin/smoke-test'
end
```

Do NOT add `smoke` to the `default` task — it boots a JVM and needs a real FITS install; it stays opt-in.

- [ ] **Step 2: Verify the rake task runs the script**

Run: `bundle exec rake smoke`
Expected: same output as `./bin/smoke-test` — three `✓` lines + `SMOKE TEST PASSED` (or `SKIP:` if FITS absent). `rake` propagates the script's exit code via `sh`.

- [ ] **Step 3: Confirm the default task is unchanged**

Run: `bundle exec rake -T | grep -E "smoke|default"` and `grep "task default" Rakefile`
Expected: `rake smoke` is listed; `default` still `%i[spec lint]` (smoke NOT added).

- [ ] **Step 4: Add a README dev-workflow mention**

In `README.md`, in or near the existing development/testing section, add a short note (match the file's existing style):

```markdown
### Smoke test

Quick end-to-end confidence check against the standalone server — boots it,
examines a fixture, checks `STATS`, and verifies a bad request is rejected:

```bash
rake smoke          # or: ./bin/smoke-test
```

It skips cleanly (exit 0) when FITS is not installed. Set `FITS_HOME` if your
FITS install is not at `~/tools/fits-1.6.0`.
```

- [ ] **Step 5: Confirm docs-only + rake change didn't break the suite**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: fast specs pass (unchanged count); rubocop clean. (The Rakefile is inspected by the repo-wide rubocop; ensure the new task is clean.)

- [ ] **Step 6: Commit**

```bash
git add Rakefile README.md
git commit -m "feat: add rake smoke task and document the smoke test"
```

---

## Task 3: Optional local `.claude` wrapper (gitignored — not committed)

**Files:**
- Create (gitignored, local-only): `.claude/commands/smoke.md`

**Interfaces:** none (personal convenience; `.claude/` is gitignored so this is never committed or shared).

Note: this task is OPTIONAL. It produces no tracked change (verify with `git status` that `.claude/` stays untracked). Skip if not wanted; the durable tooling is `bin/smoke-test` + `rake smoke`.

- [ ] **Step 1: Create the wrapper command**

```markdown
---
description: Run the standalone FITS server smoke test (bin/smoke-test)
---

Run `./bin/smoke-test` and report the result: the per-check ✓/✗ lines and the
final PASSED/FAILED/SKIP line. If it fails, show the expected-vs-actual for the
failing check.
```

- [ ] **Step 2: Confirm it is NOT tracked by git**

Run: `git status --short .claude/ ; git check-ignore .claude/commands/smoke.md`
Expected: `git status` shows nothing for `.claude/` (ignored); `git check-ignore` prints the path (confirming it is ignored). Nothing to commit.

---

## Self-Review Notes

- **Spec coverage:** locate-FITS-or-skip (T1 Step 1 code + Step 4 verify); boot on temp socket with -Xmx512m + poll (T1); three checks with ✓/✗ + expected/actual (T1); always-teardown via ensure (T1); PASSED/FAILED + exit code (T1); `rake smoke` not in default (T2); README mention (T2); optional gitignored `.claude` wrapper (T3); no Docker / no unit tests / no JSON (honored — not present). All spec sections map to a task.
- **Placeholder scan:** no TBDs; every code step is complete runnable code; commands have expected output. The cold-start "one retry" is concrete in the code, not a vague instruction.
- **Type/name consistency:** helper names (`fits_home`, `valid_fits?`, `wait_for_socket`, `request`, `check`) are used consistently within the script; the socket/request/teardown patterns match the verified reference from `end_to_end_spec.rb`; `rake smoke` shells the exact script path `./bin/smoke-test` used in T1.
