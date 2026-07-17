# Dockerize + `bin/setup` — Design

**Date:** 2026-07-16
**Status:** Approved

## Overview

Add a portable FITS installer (`bin/setup`) and a multi-stage Docker build so the
fits-jruby socket server can run as a container for local development that
faithfully simulates the production systemd deployment (dev/prod parity). The
container acquires FITS at build time via `bin/setup`, bakes only the required
files into the runtime image, exposes host files read-only for analysis, and
serves over a bind-mounted Unix socket owned by a configurable unprivileged
UID/GID.

The existing **systemd/standalone** deployment path is preserved unchanged.

The image is **not** published to Docker Hub — it is built and run locally only.

## Guiding Principle: Dev/Prod Parity

The container is a faithful local stand-in for the systemd service: same
unprivileged user model, same `0660` group-restricted socket, same env-var
configuration, same `/run/fits/fits.sock` socket path convention, same JVM/GC
flags, and the same memory ceiling. Permission/ownership/resource issues that
would appear in production surface locally first.

## Scope & Phasing

**Phase A — Dockerization + `bin/setup` (primary, this spec):**
- `bin/setup` — portable, idempotent FITS installer.
- Multi-stage `Dockerfile` — builder installs FITS + builds `file` from source;
  runtime is a lean JRE+JRuby image with only the required files copied in.
- `bin/docker-entrypoint` — idempotent FITS check, then `exec bin/fits-server`.
- `docker-compose.yml` + `.env.example` — the primary local-dev driver.
- `.dockerignore`.
- Docs — README (all Docker content), INSTALL (FITS acquisition + OS deps),
  DEPLOYMENT (systemd only, preserved).
- Tests — fast unit tests for `bin/setup` (mocked IO/network); container
  verified via a documented manual smoke test.

**Phase B — deferred follow-ons (separate work after Phase A lands):**
- **G1** — reusable smoke-test skill (also serves as the container's repeatable
  verification).
- **R1+R2** — extract a `ConnectionReader`/line-protocol object from
  `socket_server.rb` (removes the two `AbcSize` disables + the `ClassLength`
  bump; makes the read protocol unit-testable).

## `bin/setup` — the FITS installer

A standalone Ruby script invocable identically three ways: manually by a host
operator, in the Docker builder stage, and by the container entrypoint. It uses
only Ruby stdlib (no FITS/JVM dependencies), so it runs fine under JRuby (the
project's Ruby) or any Ruby available at build time. In the builder stage it is
run with the JRuby installed there; the plan will confirm the exact invocation
(`ruby bin/setup` vs. a shebang) so no non-project Ruby is assumed.

**Interface:** reads `FITS_HOME` (install target) with optional overrides for
FITS version/URL. Exit 0 on success (installed or already present); non-zero
with a clear message on failure.

**Idempotent validate-or-fetch logic:**
1. **Check** — is `FITS_HOME` a valid FITS install? (directory exists and
   contains `lib/` — the same validity check `Config#validate!` uses). If yes,
   log "FITS already present, skipping" and exit 0 (the no-op path for a
   baked-in image or an already-set-up host).
2. **Fetch** — otherwise download the pinned FITS 1.6.0 release zip from its
   GitHub release URL to a temp file.
3. **Verify** — check the download against a **pinned SHA-256** (a hard-coded
   constant, determined at implementation time against the real download)
   before extracting. Fail loudly on mismatch (supply-chain safety).
4. **Extract** — `unzip` into `FITS_HOME` atomically: extract to a temp dir,
   then move into place, so an interrupted run never leaves a half-populated
   `FITS_HOME` that the validity check would later mistake for "present".
5. **Clean up** — remove the temp zip.

**Dependencies:** Ruby stdlib available on JRuby (`net/http`/`open-uri` for
download, `digest` for SHA-256) plus a shell-out to `unzip` (a documented
prerequisite).

**Config constants (top of script):** pinned `FITS_VERSION` (1.6.0), the release
URL template, and the expected SHA-256 — so bumping FITS is a one-line change.

## Multi-stage Dockerfile

**Builder stage** (a build base with JDK + build tooling):
1. Install `curl`, `unzip`, `make`, `gcc`, and `file`'s build dependencies.
2. Run `bin/setup` → download + SHA-256 verify + unzip FITS 1.6.0 into a
   staging `FITS_HOME` (e.g. `/opt/fits`). **Note:** a JDK-only builder base has
   no Ruby, so the plan must ensure a Ruby is available to run `bin/setup` in the
   builder — either install JRuby in the builder too (consistent with runtime),
   or apt-install a system Ruby, or use a builder base that already has one. The
   plan picks the simplest reproducible option; `bin/setup` itself is
   Ruby-agnostic (stdlib only).
3. Build **`file` 5.43 from source** (Harvard's recipe: curl the tarball,
   SHA-256 verify, `./configure && make && make install`), landing its binary +
   libs in a known location.

**Runtime stage** (`eclipse-temurin:17-jre-jammy`):
1. Install FITS's runtime apt dependencies (no compilers):
   `python3`/`python-is-python3` (jpylyzer), the ExifTool Perl libraries,
   MediaInfo's `libmms0`/`libcurl3-gnutls`, and `unzip` (for the entrypoint's
   idempotent `bin/setup` in a future volume-based scenario).
2. Install **JRuby 9.4.15.0** via tarball to `/opt/jruby` (on `PATH`), with the
   tarball **SHA-256 verified** against a pinned checksum. Then `bundle install`
   the app's production gems.
3. `COPY --from=builder` the FITS tree (`/opt/fits` → `FITS_HOME`) and the built
   `file` binary/libs.
4. Copy the app code (`bin/`, `lib/`, `config/`, Gemfile/Gemfile.lock).
5. Create the unprivileged `fits` user/group (default UID/GID, overridable at
   run — see compose section).
6. Set env vars with prod-parity defaults (`FITS_HOME`,
   `FITS_SOCKET_PATH=/run/fits/fits.sock`, etc.) and `ENTRYPOINT` →
   `bin/docker-entrypoint`.

**Why this base:** `eclipse-temurin:17-jre-jammy` is the OS (Ubuntu Jammy) FITS's
bundled native libs (MediaInfo) were built for, and matches the Ubuntu 22.04
systemd guidance — one dependency story across both deploy modes. JRE (not JDK)
is sufficient to run JRuby at runtime.

**Multi-stage win:** build tooling (gcc/make/JDK/curl) never reaches the runtime
image; only extracted FITS files, the built `file` binary/libs, the app, and the
JRuby runtime do.

**`.dockerignore`:** exclude `.git`, `.github`, `.claude/`, `.superpowers/`,
`docs/`, local `tmp/`. **Keep `spec/`** in the build context (to allow running
specs in a container later).

## Entrypoint & startup flow

**`bin/docker-entrypoint`** (the image `ENTRYPOINT`):
1. **Idempotent FITS check** — run `bin/setup`. In the normal baked-in image
   this finds a valid `FITS_HOME` and is a near-instant no-op. If FITS is ever
   missing (future volume-based use) it fetches; if it cannot (no network), it
   fails loudly and the container does not start — the correct, visible failure.
2. **Ensure the socket directory exists** with correct ownership before the
   server binds (the dir normally comes from the bind mount; the server already
   unlinks a stale socket file).
3. **`exec bin/fits-server`** — replace the shell so the JRuby process receives
   `SIGTERM`/`SIGINT` directly. This is required for the server's existing
   graceful drain + socket-unlink shutdown to fire on `docker stop`.

Config validation is not duplicated here — `bin/fits-server` already fails fast
via `Config#validate!`.

**PID 1 / zombie reaping:** for a single long-lived JRuby process with no
child-process fan-out, a dedicated init is likely unnecessary. Confirm during
implementation; if warranted, document the compose `init: true` option.

## docker-compose, host exposure & security parity

**`docker-compose.yml`** — the primary local-dev driver:
- **Build:** `build: .` (local only; no `image:` push target, not on Docker Hub).
- **User:** `user: "${FITS_UID}:${FITS_GID}"` driven by a committed
  `.env.example`. The container always runs as an unprivileged non-root user;
  only the numeric IDs are parameterized. **No host `fits` account is assumed.**
- **Media mounts (read-only, path-parity):** bind-mount host media dirs at the
  *same* absolute path, `:ro`, so a client-sent absolute path resolves
  identically inside the container (no path translation). The compose file shows
  one representative mount with a comment to add one per host dir.
- **Socket dir:** bind-mount a host directory to the container's socket dir so
  host-side clients (e.g. Sidekiq) reach the socket. `FITS_SOCKET_PATH` points
  inside it; the socket lands `0660`, owned by the configured UID/GID →
  group-reachable, not world.
- **Env:** prod-parity defaults — `FITS_SOCKET_PATH=/run/fits/fits.sock`,
  `FITS_QUEUE_CAPACITY`, `FITS_LOG_LEVEL`, `FITS_READ_TIMEOUT`,
  `FITS_WRITE_TIMEOUT`, and `JAVA_OPTS` matching the systemd unit
  (`-Xms256m -Xmx1g -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+ExitOnOutOfMemoryError`).
- **Resource limits:** memory ceiling mirroring the systemd `MemoryMax=1500M`.
- **Hardening (parity):** `read_only` root fs + `tmpfs` where feasible,
  `cap_drop`, and `init: true` if warranted — mirroring the systemd hardening
  (`ProtectSystem=strict`, `NoNewPrivileges`) as closely as compose allows. No
  published ports (Unix socket only; no network exposure).

**UID/GID recipes (documented, no host `fits` account required):**
- **Dev (default):** set `FITS_UID`/`FITS_GID` to your own `id -u`/`id -g`; the
  socket is owned by you and your host processes reach it with no extra setup.
- **Prod-rehearsal:** create a `fits` group, add your client user to it, set
  `FITS_GID` to it — to exercise the production posture locally.
- The host socket directory must be writable by the chosen GID (a one-line
  `chown`/`chgrp`, or simply a dir you own in dev).

**`docker run` equivalent:** the full invocation (all `-v`/`--user`/`-e`/memory
flags) documented in the README for the non-compose case.

**Security posture:** identical intent to systemd — unprivileged user, `0660`
group-restricted socket, read-only media, no network exposure, least-privilege
capabilities.

## Documentation

Clean split — each guide has one job, no duplication:
- **README.md** — owns the **entire Docker story** in a "Run with Docker (local
  dev)" section: `bin/setup`, `docker compose up`, `.env` UID/GID setup (dev vs.
  prod-rehearsal recipes), media/socket mounts, resource limits/hardening flags,
  the `docker run` equivalent, and a socket smoke request. Existing quick-start
  and protocol docs stay.
- **INSTALL.md** — owns **FITS acquisition + all OS-dependency prerequisites**:
  adds `bin/setup` as the FITS-install step, and documents FITS's tool OS
  dependencies (python3, ExifTool Perl libs, MediaInfo libs, the `file` note) as
  manual prerequisites for the host/systemd path.
- **DEPLOYMENT.md** — **systemd/standalone only**, kept intact. No Docker
  content. Remains the production-on-a-host guide.

## Testing

Per the layered strategy (fast unit default; heavyweight paths verified
manually):
- **`bin/setup` fast unit tests** — the piece with real logic. Cover: skips when
  a valid `FITS_HOME` is present (idempotent no-op); fetches when missing;
  SHA-256 mismatch → fails loudly with no extraction; atomic extract (an
  interrupted run leaves no half-valid `FITS_HOME`). Download and filesystem are
  **mocked/stubbed** — no real network, fast. Joins the default `rspec` suite.
- **Dockerfile / compose** — verified by a **documented manual smoke test**
  (`docker compose up` → send a fixture path + `STATS` over the socket → assert
  XML + JSON → `docker compose down`). This becomes the reusable **G1
  smoke-test skill** in Phase B.
- **CI unchanged** — no Docker build in CI (network/DinD-heavy, cuts against the
  self-skipping-integration posture). The new `bin/setup` unit specs run in the
  existing gate (rubocop → bundle-audit → unit rspec).

## New / Modified Files

```
fits-jruby/
├── bin/
│   ├── setup                  # NEW: idempotent FITS installer
│   └── docker-entrypoint      # NEW: idempotent check + exec fits-server
├── Dockerfile                 # NEW: multi-stage build
├── docker-compose.yml         # NEW: local-dev driver
├── .env.example               # NEW: FITS_UID/FITS_GID (+ other tunables)
├── .dockerignore              # NEW
├── spec/
│   └── setup_spec.rb          # NEW: fast unit tests for bin/setup logic
├── README.md                  # MODIFIED: add Docker section
├── INSTALL.md                 # MODIFIED: bin/setup + FITS OS deps
└── DEPLOYMENT.md              # UNCHANGED (systemd only, preserved)
```

## Open Questions

None. The pinned SHA-256 values (FITS zip, JRuby tarball, `file` tarball) are
determined at implementation time against the real downloads. Phase B items
(smoke-test skill, ConnectionReader refactor) are explicitly deferred to
separate work after Phase A lands.
