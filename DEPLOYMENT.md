# Deployment Guide

This guide covers running fits-jruby as a hardened systemd service on
**Ubuntu 22.04 LTS**. The result is a socket at `/run/fits/fits.sock` owned by
an unprivileged `fits` user, reachable by any application whose OS user belongs
to the `fits` group.

---

## Prerequisites

- OpenJDK 17 installed system-wide (see [INSTALL.md](INSTALL.md) Step 1).
- JRuby 9.4.15.0 installed via rbenv under the service user's home, **or**
  installed to a shared prefix such as `/usr/local`.
- FITS 1.6.0 unzipped to a stable location, e.g. `/opt/fits-1.6.0` (or `/usr/local/tools/fits-1.6.0`).
- **FITS tool OS dependencies installed** — the OS packages FITS's bundled tools
  need (python3, the ExifTool Perl libraries, MediaInfo libs, the `file`
  command). The Docker image installs these automatically, but a host/systemd
  install must install them manually; see
  [INSTALL.md](INSTALL.md) → "FITS tool OS dependencies". Without them the
  server boots but examinations fail or degrade.
- The `fits-jruby` repository checked out to a stable location, e.g.
  `/opt/fits-jruby`.
- Dependencies installed: `cd /opt/fits-jruby && bundle config set --local without 'development test' && bundle install`.

---

## Step 1 — Create the service user

Create a dedicated system account with no login shell and no home directory.
This limits blast radius if the process is ever compromised.

```bash
sudo groupadd --system fits
sudo useradd --system --no-create-home --shell /usr/sbin/nologin \
             --gid fits fits
```

---

## Step 2 — Grant the calling application access to the socket

The socket will be owned `fits:fits` with permissions `0660`. Any OS user that
belongs to the `fits` group can connect to it.

Add the application's service user (e.g. `avi` or `deployer`) to the `fits`
group:

```bash
sudo usermod -aG fits deployer
```

The new group membership takes effect on the next login or service restart for
that user.

---

## Step 3 — Grant the fits user read access to media directories

FITS examines files by path. The `fits` user must be able to read whatever
directories your application stores media in. The safest approach is to add the
`fits` user to the group that owns those directories, or to use ACLs:

```bash
# Example: add fits to the group that owns /srv/media
sudo usermod -aG media fits

# Alternative: grant read-only ACL access
sudo setfacl -R -m u:fits:rX /srv/media
```

Do **not** make media directories world-readable just for FITS.

---

## Step 4 — Create the systemd service unit

Create `/etc/systemd/system/fits.service` with the following contents. Replace
the bracketed placeholders with your actual paths:

```ini
[Unit]
Description=fits-jruby Unix socket server
Documentation=https://github.com/bbarberBPL/fits-jruby
After=network.target
# Restart if it crashes; systemd will back off automatically on rapid failures.

[Service]
Type=simple
User=fits
Group=fits

# systemd creates /run/fits on start and removes it on stop.
RuntimeDirectory=fits
RuntimeDirectoryMode=0750

# UMask=0117 means new files get 0660 (rw-rw----), so the socket is
# accessible by the fits group but not world-readable.
UMask=0117

WorkingDirectory=/opt/fits-jruby

ExecStart=/usr/local/bin/jruby bin/fits-server

# -- Environment ------------------------------------------------------------
Environment=FITS_HOME=/opt/fits-1.6.0
Environment=FITS_SOCKET_PATH=/run/fits/fits.sock
Environment=FITS_QUEUE_CAPACITY=64
Environment=FITS_LOG_LEVEL=info
# Stalled-client protection: disconnect clients that never send a request
# line within FITS_READ_TIMEOUT seconds, or never drain the response within
# FITS_WRITE_TIMEOUT seconds.
Environment=FITS_READ_TIMEOUT=5
Environment=FITS_WRITE_TIMEOUT=30

# JVM heap and GC tuning. Tune -Xmx up only if STATS shows heap_used_bytes
# approaching heap_max_bytes. See "Monitoring" below.
Environment="JAVA_OPTS=-Xms256m -Xmx1g -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+ExitOnOutOfMemoryError"

# -- Hardening --------------------------------------------------------------
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

# Allow reads from FITS jars and from media paths examined by FITS.
# Add additional ReadOnlyPaths= entries for each media directory the fits
# user needs to read.
ReadOnlyPaths=/opt/fits-1.6.0 /opt/fits-jruby

# The server uses only Unix-domain sockets; block all others.
RestrictAddressFamilies=AF_UNIX

# Hard ceiling: slightly above -Xmx to allow JVM overhead.
MemoryMax=1500M

# -- Reliability ------------------------------------------------------------
Restart=on-failure
RestartSec=5s

# -- Logging ----------------------------------------------------------------
# Logs go to journald; retrieve with: journalctl -u fits.service
StandardOutput=journal
StandardError=journal
SyslogIdentifier=fits-jruby

[Install]
WantedBy=multi-user.target
```

> **Note on `/run` vs `/var/run`:** On Ubuntu 22.04, `/var/run` is a symlink to
> `/run`. Use `/run/fits/fits.sock` (the canonical path). The `RuntimeDirectory=fits`
> directive instructs systemd to create `/run/fits` before starting the service
> and to remove it when the service stops, so no manual `mkdir` is needed.

> **Note on FITS log4j logging:** FITS bundles log4j-core and would normally
> write a `fits.log` in the working directory. The project ships
> `config/log4j2.xml`, which replaces the bundled config with a console-only
> appender targeting stderr. This means no stray `fits.log` is ever created,
> and all FITS internal log output is captured by journald together with the
> Ruby logger output (both appear under `journalctl -u fits.service`). No
> additional configuration is required.

---

## Step 5 — Enable and start the service

```bash
sudo systemctl daemon-reload
sudo systemctl enable fits.service
sudo systemctl start fits.service
```

Check that it started cleanly:

```bash
sudo systemctl status fits.service
```

Look for `Active: active (running)` in the output.

View logs:

```bash
journalctl -u fits.service -f
```

The server logs `ready: listening on /run/fits/fits.sock (queue capacity 64)`
when it is accepting connections.

---

## Step 6 — Verify

From any account in the `fits` group:

```bash
printf '/etc/hostname\n' | socat - UNIX-CONNECT:/run/fits/fits.sock
```

A successful response starts with `<?xml`. If you see `ERROR:` check the logs
with `journalctl -u fits.service`.

---

## Operational behavior

A few runtime behaviors are worth knowing when reasoning about the service or
configuring alerts:

- **Socket permissions.** The Unix socket is created with mode `0660` in code on
  bind (group-restricted), not left to the ambient umask. Who can connect is
  therefore determined by the process's group plus this mode — a permissive
  umask cannot make the socket world-connectable. Group ownership comes from the
  process's gid (`Group=fits` in the unit); the server does not `chown`.
- **Worker self-healing.** The single worker thread self-heals on unexpected
  crashes: if it dies while the server is running it is respawned automatically
  (with a short increasing backoff). This is transparent and needs no action.
- **Repeated-crash give-up.** If the worker crashes repeatedly (sustained OOM,
  persistent fatal error), the server stops thrashing after
  `MAX_CONSECUTIVE_RESPAWNS` (5) rapid respawns, logs a single fatal line of the
  form `worker repeatedly crashed (N times); giving up respawning`, and then
  **exits the process non-zero** so systemd's `Restart=on-failure` starts a
  clean one. **Alert on that fatal log line** — it means every request was
  hanging until the restart, and a recurring pattern points at a systemic
  problem (bad config, chronic OOM) that a restart alone will not fix.

## Monitoring

### Polling STATS

The `STATS` command returns a JSON snapshot of server health without running
FITS. It is safe to poll frequently (it is logged only at `debug` level to
avoid polluting examination logs).

```bash
printf 'STATS\n' | socat - UNIX-CONNECT:/run/fits/fits.sock
```

Example response:

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

### What each field means

| Field              | Meaning                                                                           |
|--------------------|-----------------------------------------------------------------------------------|
| `uptime_seconds`   | Seconds since the server started.                                                 |
| `requests_total`   | Total examinations received (success + error). Does not count `STATS` calls.     |
| `requests_success` | Examinations that returned FITS XML.                                              |
| `requests_error`   | Examinations that returned an error.                                              |
| `queue_depth`      | Connections waiting in the application queue right now.                           |
| `processing`       | `true` if a FITS examination is currently running.                                |
| `heap_used_bytes`  | JVM heap currently in use (bytes).                                                |
| `heap_max_bytes`   | Maximum JVM heap (`-Xmx`, currently 1 GB = 1 073 741 824 bytes).                 |

### Alerts to configure

| Signal | What it means | Action |
|--------|--------------|--------|
| `queue_depth` rising and not returning to 0 | The server cannot keep up with incoming requests | Check `processing` is `true` (server is working); consider reducing upstream concurrency or increasing `FITS_QUEUE_CAPACITY` |
| `heap_used_bytes` consistently above 80% of `heap_max_bytes` | Heap headroom is low | Increase `-Xmx` (and `MemoryMax=`) in the service unit, then `systemctl daemon-reload && systemctl restart fits.service` |
| `requests_error / requests_total` ratio rising | Files are failing examination | Check `journalctl -u fits.service` for `ERROR:` lines; verify file permissions and format support |
| Service restarts frequently (`systemctl status fits.service`) | OOM kill, unexpected exception, or bad config | Check journal; `-XX:+ExitOnOutOfMemoryError` triggers a clean exit so systemd can restart rather than leaving a wedged process |

### Simple polling script

```bash
#!/usr/bin/env bash
# Poll STATS every 30 seconds and print a summary line.
SOCK=/run/fits/fits.sock
while true; do
  stats=$(printf 'STATS\n' | socat - UNIX-CONNECT:"$SOCK" 2>/dev/null)
  if [ -n "$stats" ]; then
    echo "$(date -Iseconds) $stats"
  else
    echo "$(date -Iseconds) ERROR: could not connect to $SOCK"
  fi
  sleep 30
done
```

Pipe this through `jq` for formatted output or into a monitoring system (e.g.
Prometheus textfile collector, Datadog custom check, or Nagios passive check).

### Dependency security

`rake audit` (`bundle-audit check --update`) scans only `Gemfile.lock` — that is,
the **Ruby** dependencies of this wrapper. It does **not** see the **Java jars**
that FITS bundles under `$FITS_HOME/lib` (log4j-core, Tika, PDFBox, and others),
so CVEs in those jars will not surface in our tooling.

Those jars are FITS's responsibility. Operators should:

- Track FITS releases and apply security updates promptly (a new FITS release is
  the normal path to updated jars).
- Optionally scan `$FITS_HOME/lib` with a Java-aware tool such as
  [OWASP Dependency-Check](https://owasp.org/www-project-dependency-check/) or
  [`grype`](https://github.com/anchore/grype) as part of a periodic audit.

For context: the bundled `log4j-core` is 2.19.0, which is past the Log4Shell
(CVE-2021-44228) fix line, and our `config/log4j2.xml` is console-only with no
message lookups, so that specific attack surface does not apply here. This note
is about the general blind spot, not a known active vulnerability.

---

## JVM and GC tuning

The service unit sets these `JAVA_OPTS` by default:

```
-Xms256m -Xmx1g -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+ExitOnOutOfMemoryError
```

| Flag | Purpose |
|------|---------|
| `-Xms256m` | Initial heap. Kept modest (1/4 of `-Xmx`) so the process starts lean; the JVM grows the heap toward `-Xmx1g` on demand. Raise it toward `-Xmx` only if early heap-growth pauses become a concern. |
| `-Xmx1g` | Maximum heap. FITS is comfortable under 512 MB for ordinary files; 1 GB gives headroom for larger media. |
| `-XX:+UseG1GC` | G1 garbage collector (default on JDK 17). Suits a moderate heap with low-pause goals. |
| `-XX:MaxGCPauseMillis=200` | Target maximum GC pause of 200 ms. |
| `-XX:+ExitOnOutOfMemoryError` | Exit immediately on OOM so systemd can restart a wedged process. |

Adjust `-Xmx` (and the matching `MemoryMax=` in the service unit) based on what
`STATS` reports for `heap_used_bytes` vs. `heap_max_bytes` under your typical
file load.

If the server runs in a container, replace `-Xmx1g` with
`-XX:MaxRAMPercentage=50` to let the JVM respect cgroup memory limits
automatically.

---

## Concurrency behaviour under load

The server processes files **serially** — one at a time — so the JVM heap stays
small. Concurrent callers (e.g. multiple Sidekiq threads) are handled as follows:

1. An **acceptor thread** accepts connections immediately and enqueues them in
   the application-level queue (up to `FITS_QUEUE_CAPACITY`, default 64).
2. A single **worker thread** drains the queue one connection at a time.
3. If the application queue is full, further connections wait in the kernel
   listen backlog — a second cushion — rather than being refused.

Callers therefore **queue rather than fail**. Per-connection latency under burst
is roughly the number of requests ahead of it in the queue times the per-file
examination time. Watch `queue_depth` via `STATS` to understand whether the
server is keeping up.

If serial throughput is insufficient at a later date, the design allows adding a
small pool of `Fits` instances on parallel worker threads at roughly N× the heap
cost — but that is out of scope for the current version.
