# fits-jruby

fits-jruby is a long-running JRuby process that keeps a single warm instance of
the [Harvard FITS](https://projects.iq.harvard.edu/fits/home) file-characterization
tool loaded in memory and serves file-examination requests over a Unix domain
socket. Because FITS is a pure Java program and JRuby runs on the JVM, the
server constructs one `Fits` object at startup — the expensive step that loads
all the analysis-tool jars — and reuses it for every request, eliminating
per-file JVM boot time. Callers send an absolute file path over the socket and
receive the native FITS XML in return. The server is designed to be called from
Sidekiq workers (or any other client that can open a Unix socket) in a separate
Ruby application.

## Quick start

```bash
bundle install
export FITS_HOME=/path/to/fits-1.6.0
bundle exec ruby bin/fits-server
```

The server logs to stdout and listens on a per-user socket by default
(`$XDG_RUNTIME_DIR/fits.sock`, or `<tmpdir>/fits-<uid>/fits.sock` when
`XDG_RUNTIME_DIR` is unset — e.g. `/tmp/fits-1000/fits.sock`). Press
`Ctrl-C` or send `SIGTERM` to shut down cleanly.

## Environment variables

| Variable              | Default          | Required | Description                                                                                  |
|-----------------------|------------------|----------|----------------------------------------------------------------------------------------------|
| `FITS_HOME`           | *(none)*         | **Yes**  | Path to the FITS installation directory. Must contain a `lib/` subdirectory with the FITS jars. |
| `FITS_SOCKET_PATH`    | per-user *(see note)* | No  | Filesystem path for the Unix domain socket. Defaults to `$XDG_RUNTIME_DIR/fits.sock` when `XDG_RUNTIME_DIR` is set, otherwise `<tmpdir>/fits-<uid>/fits.sock` (e.g. `/tmp/fits-1000/fits.sock`). The server creates the socket's parent directory with mode `0700` if it does not exist. **Anti-squat hardening (tmpdir fallback only):** when the per-user tmpdir fallback (`/tmp/fits-<uid>/…`) is in use, the server refuses to start if that directory already exists and is not a real directory owned by the server's uid with mode `0700`. The XDG runtime dir and an explicit `FITS_SOCKET_PATH` are trusted as-is (platform-owned / operator-chosen). Use `/run/fits/fits.sock` in production (set explicitly via this variable). |
| `FITS_QUEUE_CAPACITY` | `64`             | No       | Maximum number of connections that can wait in the application-level queue.                  |
| `FITS_LOG_LEVEL`      | `info`           | No       | Logging verbosity. One of `debug`, `info`, `warn`, or `error`.                               |
| `FITS_READ_TIMEOUT`   | `5`              | No       | Seconds to wait for a client to send a complete request line. Clients that connect and never send a newline are disconnected after this timeout, keeping the worker free. |
| `FITS_WRITE_TIMEOUT`  | `30`             | No       | Seconds to wait for a client to accept the response. Clients that stop reading are abandoned after this timeout so the worker is never wedged. |
| `FITS_ALLOWED_ROOTS`  | *(none)*         | No       | Optional colon-separated list of absolute directories to confine examinations to (e.g. `/srv/media:/data`). When unset (default), any file the server's user can read may be examined. When set, a requested path is canonicalized with `realpath` (resolving symlinks and `..`) and rejected with `ERROR: path not allowed` unless it resolves under one of these roots. Each root must be an existing absolute directory or the server exits at boot. |

The server validates `FITS_HOME` at boot and exits non-zero with a clear error
message if it is missing or does not contain a `lib/` directory.

## Run with Docker (local dev)

A local-development container that simulates the production systemd deployment
(dev/prod parity): it runs as an unprivileged user, serves over a Unix socket at
`/run/fits/fits.sock`, applies the same memory ceiling and JVM options, and does
not publish any network ports.

### Prerequisites

- Docker and Docker Compose.
- `socat` or `nc` on the host for sending smoke requests to the socket.

### Quick start

Run these **from the repository root** (the media mount below uses `${PWD}`, so
running from elsewhere binds the wrong directory):

```bash
cp .env.example .env
# Dev: own the socket so your host processes can reach it.
export FITS_UID=$(id -u) FITS_GID=$(id -g)
# Create ./run BEFORE `up`. If Docker auto-creates it, it is owned by root and
# the unprivileged container cannot create the socket inside it.
mkdir -p ./run
docker compose up --build
```

The socket appears on the host at `./run/fits.sock` (bind-mounted to
`/run/fits/fits.sock` inside the container).

### Sending requests over the socket

```bash
printf '/abs/path/to/file.tif\n' | socat - UNIX-CONNECT:./run/fits.sock
printf 'STATS\n' | socat - UNIX-CONNECT:./run/fits.sock
```

> **First request is slow.** The very first examination after startup pays the
> JVM + FITS toolbelt cold-start cost while the warm `Fits` instance is built.
> Use a generous timeout on the first `examine`; subsequent requests are fast.

### Media mounts (read-only path parity)

FITS examines files by absolute path, and the client sends that same absolute
path over the socket, so the path must resolve **identically inside the
container**. To analyze host files, add a read-only bind mount at the same path
under `volumes:` in `docker-compose.yml`:

```yaml
volumes:
  - "${FITS_SOCKET_DIR}:/run/fits"
  - /your/media:/your/media:ro   # add one line per host directory to analyze
```

The compose file already mounts `spec/fixtures` read-only at its host path as an
example.

### UID/GID recipes

- **Dev (default):** `export FITS_UID=$(id -u) FITS_GID=$(id -g)` so the socket
  is owned by you. No host `fits` account or group is required.
- **Prod rehearsal:** create a `fits` group (`sudo groupadd fits`), add your
  client user to it, and set `FITS_GID` to that group's gid in `.env` to
  exercise the production socket-ownership posture locally.

### The `docker run` equivalent (non-compose)

```bash
docker build -t fits-jruby .
mkdir -p ./run   # create first so the unprivileged container can write the socket
docker run --rm \
  -u "$(id -u):$(id -g)" \
  -v "$PWD/run:/run/fits" \
  -v /your/media:/your/media:ro \
  -e FITS_QUEUE_CAPACITY=64 \
  -e FITS_LOG_LEVEL=info \
  -e FITS_READ_TIMEOUT=5 \
  -e FITS_WRITE_TIMEOUT=30 \
  --memory 1500m \
  fits-jruby
```

The socket lands at `./run/fits.sock` on the host, just as with Compose.

> The image is **local-only** — it is not published to any registry. Build it
> yourself with `docker compose build` or `docker build`.

## Logging

The server logs to stdout using Ruby's standard `Logger`. FITS's own internal
logging (via log4j) is redirected to **stderr** through `config/log4j2.xml`,
which configures a console-only appender with no file appender. This means:

- No stray `fits.log` is ever created in the working directory.
- All logs (Ruby + FITS) are captured together by your process supervisor
  (journald, Docker, etc.) from stdout/stderr.

The socket is created group-restricted (mode `0660`), and the single worker
self-heals on unexpected crashes; if it crashes repeatedly the server logs a
`worker repeatedly crashed (N times); giving up respawning` fatal line and exits
non-zero so the supervisor restarts a clean process.

## Protocol

### Examining a file

Send a single newline-terminated **absolute** file path. Read until EOF for the
response.

- **Success:** well-formed FITS XML starting with `<?xml`.
- **Failure:** a plain-text error message that does **not** start with `<?xml`
  (e.g. `ERROR: no such file: /tmp/missing.tif`).

The `<?xml` prefix is the client's signal: if the response starts with it, the
examination succeeded; otherwise it failed.

Each connection handles exactly one request. Open a new connection for each file.

#### Examples — command line

The actual socket path is the per-user default described above, or whatever
`FITS_SOCKET_PATH` is set to. Set a shell variable for convenience:

```bash
# Set this to your actual socket path (see FITS_SOCKET_PATH default above)
FITS_SOCKET="${FITS_SOCKET_PATH:-/path/to/fits.sock}"

# Examine a file with nc
printf '/abs/path/to/file.tif\n' | nc -U "$FITS_SOCKET"

# Examine a file with socat
printf '/abs/path/to/file.tif\n' | socat - UNIX-CONNECT:"$FITS_SOCKET"

# Query live metrics
printf 'STATS\n' | nc -U "$FITS_SOCKET"
```

#### Example — Ruby client (Sidekiq-style)

```ruby
require "socket"

# Set this to the server's socket path (see FITS_SOCKET_PATH default above).
socket_path = ENV.fetch("FITS_SOCKET_PATH", "/path/to/fits.sock")

xml = UNIXSocket.open(socket_path) do |sock|
  sock.write("/abs/path/to/file.tif\n")
  sock.read
end
raise "FITS error: #{xml}" unless xml.start_with?("<?xml")
```

### STATS command

Send `STATS\n` to retrieve a JSON snapshot of server health. `STATS` never runs
FITS and does not affect the examination counters.

```bash
# Replace with your socket path (see FITS_SOCKET_PATH default above).
printf 'STATS\n' | nc -U "${FITS_SOCKET:-/path/to/fits.sock}"
```

Example response:

```json
{
  "uptime_seconds": 3820,
  "requests_total": 1502,
  "requests_success": 1487,
  "requests_error": 15,
  "client_disconnects": 4,
  "queue_depth": 3,
  "processing": true,
  "heap_used_bytes": 268435456,
  "heap_max_bytes": 1073741824
}
```

| Field                | Description                                                                                                                                                             |
|----------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `uptime_seconds`     | Seconds since the server started.                                                                                                                                       |
| `requests_total`     | Total examination requests received (success + error). Does not count `STATS` calls.                                                                                   |
| `requests_success`   | Examinations that returned FITS XML.                                                                                                                                    |
| `requests_error`     | All error responses: protocol/validation errors (empty request, path not allowed, read timeout, request too long) **and** examination failures. Does not count `STATS`. |
| `client_disconnects` | Clients that connected and closed without sending a request (health checks, aborted clients). Not counted as errors.                                                    |
| `queue_depth`        | Connections currently waiting in the application queue.                                                                                                                 |
| `processing`         | `true` if a FITS examination is running right now.                                                                                                                      |
| `heap_used_bytes`    | JVM heap in use (bytes).                                                                                                                                                |
| `heap_max_bytes`     | Maximum JVM heap available (bytes).                                                                                                                                     |

## Concurrency and queuing

The server processes examinations **serially** — one file at a time — to keep
the JVM heap small and avoid FITS thread-safety concerns. Concurrent callers are
not rejected; they **queue rather than fail**:

1. An acceptor thread accepts connections as fast as they arrive and places each
   on a bounded application-level queue (`FITS_QUEUE_CAPACITY`, default 64).
2. A single worker thread drains the queue one connection at a time.
3. If the application queue is full, further connections wait in the kernel
   listen backlog — a second cushion — before being accepted.

This means multiple Sidekiq workers can send requests simultaneously without
errors. Per-request latency grows with `queue_depth`. Monitor `queue_depth` via
`STATS` to know whether the server is keeping up with load.

## Running tests

```bash
# Fast unit tests (no JVM/FITS required)
bundle exec rspec

# Integration tests against a real FITS installation
FITS_HOME=~/tools/fits-1.6.0 bundle exec rspec --tag integration
```

### Smoke test

Quick end-to-end confidence check against the standalone server — boots it,
examines a fixture, checks `STATS`, and verifies a bad request is rejected:

```bash
rake smoke          # or: ./bin/smoke-test
```

It skips cleanly (exit 0) when FITS is not installed. Set `FITS_HOME` if your
FITS install is not at `~/tools/fits-1.6.0`.

See [INSTALL.md](INSTALL.md) for setup instructions and
[DEPLOYMENT.md](DEPLOYMENT.md) for the production systemd guide.
