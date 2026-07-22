# Installation Guide

This guide walks a junior developer through setting up fits-jruby from scratch
on a development machine running Ubuntu 22.04 (or compatible). You need:

- A terminal with `sudo` access.
- Internet access to download rbenv, JDK, and FITS.

---

## Step 1 — Install OpenJDK 17

fits-jruby requires Java 17 or newer (JRuby 9.4.15.0 depends on it).

```bash
sudo apt update
sudo apt install -y openjdk-17-jdk
```

Verify:

```bash
java -version
# Expected output contains: openjdk version "17..."
```

If you have multiple JDK versions installed, make sure `java -version` shows 17.
You can select it with:

```bash
sudo update-alternatives --config java
```

---

## Step 2 — Install rbenv and the JRuby 9.4.15.0 runtime

rbenv manages Ruby (and JRuby) versions without requiring root for gems.

```bash
# Install rbenv and ruby-build
sudo apt install -y git curl
git clone https://github.com/rbenv/rbenv.git ~/.rbenv
git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build

# Add rbenv to your shell
echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
echo 'eval "$(rbenv init -)"' >> ~/.bashrc
source ~/.bashrc
```

Install JRuby 9.4.15.0. This step downloads the JRuby distribution and may
take a few minutes:

```bash
rbenv install jruby-9.4.15.0
```

Set JRuby as the version for this project. From inside the `fits-jruby`
directory:

```bash
cd /path/to/fits-jruby
rbenv local jruby-9.4.15.0
```

Verify:

```bash
ruby --version
# Expected output contains: jruby 9.4.15.0
```

---

## Step 3 — Obtain FITS 1.6.0 with `bin/setup`

The recommended way to acquire FITS is the idempotent `bin/setup` installer. It
downloads the FITS zip, verifies its SHA-256 checksum, and unzips it to
`FITS_HOME` if it is not already present — and is a no-op when FITS is already
installed there. It requires `unzip` to be available:

```bash
sudo apt install -y unzip
FITS_HOME=~/tools/fits-1.6.0 ruby bin/setup
```

After it runs you should see a `lib/` directory inside `fits-1.6.0`:

```bash
ls ~/tools/fits-1.6.0/lib/
# Should list many .jar files
```

If `lib/` is missing the server will refuse to start.

> **Manual fallback.** If you prefer to install FITS by hand, download and unzip
> the release archive yourself:
>
> ```bash
> mkdir -p ~/tools && cd ~/tools
> curl -L -O https://github.com/harvard-lts/fits/releases/download/1.6.0/fits-1.6.0.zip
> unzip fits-1.6.0.zip -d fits-1.6.0
> ```

> **System-wide alternative.** A shared, system-wide alternative is
> `/usr/local/tools/fits-1.6.0`; use that in place of `~/tools/fits-1.6.0`
> above if you prefer a location accessible to all users on the machine.

### FITS tool OS dependencies

FITS bundles a toolbelt (ExifTool, jpylyzer, MediaInfo, `file`, and others) that
relies on OS-level packages. In the Docker image these are installed
automatically; on a host or systemd install you must install them yourself.
On Ubuntu 22.04:

```bash
sudo apt install -y \
  python3 python-is-python3 \
  libarchive-zip-perl libio-compress-perl libcompress-raw-zlib-perl \
  libcompress-bzip2-perl libcompress-raw-bzip2-perl libio-digest-perl \
  libdigest-md5-file-perl libdigest-perl-md5-perl libdigest-sha-perl \
  libposix-strptime-perl libunicode-linebreak-perl \
  libmms0 libcurl3-gnutls
```

| Package(s) | Needed by |
|------------|-----------|
| `python3`, `python-is-python3` | jpylyzer (JPEG 2000 validation) |
| The `lib*-perl` packages above | ExifTool's Perl runtime and its compression/digest modules |
| `libmms0`, `libcurl3-gnutls` | MediaInfo shared libraries |

FITS also shells out to the `file` command, which **must be present** on the
host. Ubuntu ships `file` in its base install; FITS 1.6.0 was tested against
`file` 5.43. (The Docker image builds `file` 5.43 from source to match.)

---

## Step 4 — Install Ruby dependencies

From the `fits-jruby` project root:

```bash
cd /path/to/fits-jruby
gem install bundler
bundle install
```

Bundler installs RSpec, RuboCop, bundler-audit, and Rake.

---

## Step 5 — Set the required environment variable

`FITS_HOME` must point to the directory you unzipped in Step 3. Add it to your
shell profile so it persists across sessions:

```bash
echo 'export FITS_HOME="$HOME/tools/fits-1.6.0"' >> ~/.bashrc
source ~/.bashrc
```

Confirm it is set:

```bash
echo $FITS_HOME
# Should print: /home/<you>/tools/fits-1.6.0
```

You can also export additional variables for development:

```bash
# FITS_SOCKET_PATH defaults to a per-user path ($XDG_RUNTIME_DIR/fits.sock,
# or /tmp/fits-<uid>/fits.sock when XDG_RUNTIME_DIR is unset). You may set it
# explicitly if you prefer a fixed path, e.g. for scripting:
# export FITS_SOCKET_PATH=/tmp/fits-dev.sock
export FITS_QUEUE_CAPACITY=64            # default
export FITS_LOG_LEVEL=info               # default
```

---

## Step 6 — Start the server

```bash
cd /path/to/fits-jruby
bundle exec ruby bin/fits-server
```

Expected startup output (within a few seconds once the JVM warms up):

```
I, [timestamp]  INFO -- : ready: listening on /tmp/fits-1000/fits.sock (queue capacity 64)
```

*(The socket path shown is the per-user default — `$XDG_RUNTIME_DIR/fits.sock`
when `XDG_RUNTIME_DIR` is set, otherwise `/tmp/fits-<uid>/fits.sock`. Your uid
replaces `1000`.)*

The server keeps running in the foreground. Open a second terminal for the
next step. Press `Ctrl-C` to stop it.

---

## Step 7 — Verify with a sample request

In a second terminal, send a file path to the socket. The path must be
absolute and the file must exist and be readable by the process running the
server.

The startup log shows the exact socket path. Set a shell variable for
convenience (replace with the path printed by the server):

```bash
# Replace with the socket path printed in the startup log above. This mirrors
# the server's default precedence: explicit FITS_SOCKET_PATH, else
# $XDG_RUNTIME_DIR/fits.sock, else /tmp/fits-<uid>/fits.sock.
FITS_SOCKET="${FITS_SOCKET_PATH:-${XDG_RUNTIME_DIR:-/tmp/fits-$(id -u)}/fits.sock}"

# Use a file that actually exists on your system, for example:
printf '/etc/hostname\n' | nc -U "$FITS_SOCKET"
```

If the server is working correctly the response starts with `<?xml`. If
something went wrong you will see a line beginning with `ERROR:`.

You can also check server metrics:

```bash
printf 'STATS\n' | nc -U "$FITS_SOCKET"
```

This returns a JSON object describing uptime, request counts, queue depth, and
JVM heap usage.

---

## Running the tests

### Fast unit tests (no FITS required)

The default RSpec run exercises all units with mocked FITS and runs in seconds:

```bash
bundle exec rspec
```

### Integration tests (requires FITS)

Integration tests construct a real `Fits` instance and examine sample fixtures.
They are tagged `:integration` and excluded from the default run to keep the
fast loop free of JVM startup cost. Run them with:

```bash
FITS_HOME=~/tools/fits-1.6.0 bundle exec rspec --tag integration
```

### Linting and dependency audit

```bash
rake lint     # runs RuboCop
rake audit    # runs bundler-audit (checks Gemfile.lock for known CVEs)
```

Both tasks must pass before merging a branch.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `configuration error: FITS_HOME must be set` | `FITS_HOME` not exported | `export FITS_HOME=...` and restart |
| `configuration error: FITS_HOME (...) must contain a lib/ directory` | Wrong path or incomplete zip | Re-check `ls $FITS_HOME/lib/` |
| `nc: no address associated with name` or connection refused | Server is not running, or wrong socket path | Start the server; check `FITS_SOCKET_PATH` |
| `ERROR: path must be absolute: foo.tif` | Relative path sent to socket | Use a full absolute path starting with `/` |
| JRuby startup is slow (first run only) | JVM JIT warm-up | Normal; subsequent runs start faster |
