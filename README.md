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

The server logs to stdout and listens on `/tmp/fits.sock` by default. Press
`Ctrl-C` or send `SIGTERM` to shut down cleanly.

## Environment variables

| Variable             | Default          | Required | Description                                                                                  |
|----------------------|------------------|----------|----------------------------------------------------------------------------------------------|
| `FITS_HOME`          | *(none)*         | **Yes**  | Path to the FITS installation directory. Must contain a `lib/` subdirectory with the FITS jars. |
| `FITS_SOCKET_PATH`   | `/tmp/fits.sock` | No       | Filesystem path for the Unix domain socket. Use `/run/fits/fits.sock` in production.        |
| `FITS_QUEUE_CAPACITY`| `64`             | No       | Maximum number of connections that can wait in the application-level queue.                  |
| `FITS_LOG_LEVEL`     | `info`           | No       | Logging verbosity. One of `debug`, `info`, `warn`, or `error`.                               |

The server validates `FITS_HOME` at boot and exits non-zero with a clear error
message if it is missing or does not contain a `lib/` directory.

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

```bash
# Examine a file with nc
printf '/abs/path/to/file.tif\n' | nc -U /tmp/fits.sock

# Examine a file with socat
printf '/abs/path/to/file.tif\n' | socat - UNIX-CONNECT:/tmp/fits.sock

# Query live metrics
printf 'STATS\n' | nc -U /tmp/fits.sock
```

#### Example — Ruby client (Sidekiq-style)

```ruby
require "socket"

xml = UNIXSocket.open("/tmp/fits.sock") do |sock|
  sock.write("/abs/path/to/file.tif\n")
  sock.read
end
raise "FITS error: #{xml}" unless xml.start_with?("<?xml")
```

### STATS command

Send `STATS\n` to retrieve a JSON snapshot of server health. `STATS` never runs
FITS and does not affect the examination counters.

```bash
printf 'STATS\n' | nc -U /tmp/fits.sock
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

| Field              | Description                                                        |
|--------------------|--------------------------------------------------------------------|
| `uptime_seconds`   | Seconds since the server started.                                  |
| `requests_total`   | Total examination requests received (success + error).             |
| `requests_success` | Examinations that returned FITS XML.                               |
| `requests_error`   | Examinations that returned an error.                               |
| `queue_depth`      | Connections currently waiting in the application queue.            |
| `processing`       | `true` if a FITS examination is running right now.                 |
| `heap_used_bytes`  | JVM heap in use (bytes).                                           |
| `heap_max_bytes`   | Maximum JVM heap available (bytes).                                |

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

See [INSTALL.md](INSTALL.md) for setup instructions and
[DEPLOYMENT.md](DEPLOYMENT.md) for the production systemd guide.
