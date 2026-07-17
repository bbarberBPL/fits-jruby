# Dockerize + bin/setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a portable idempotent FITS installer (`bin/setup`) and a multi-stage Docker build so the fits-jruby socket server runs as a local-dev container that faithfully simulates the production systemd deployment.

**Architecture:** `bin/setup` (pure-Ruby stdlib) downloads + SHA-256-verifies + unzips FITS idempotently. A multi-stage Dockerfile runs `bin/setup` and builds `file` from source in a builder stage, then copies only the required artifacts into a lean `eclipse-temurin:17-jre-jammy` runtime image with JRuby installed. `docker-compose.yml` drives local runs with read-only path-parity media mounts, a bind-mounted socket dir, and a configurable unprivileged UID/GID. The systemd path is untouched.

**Tech Stack:** Ruby stdlib (net/http, digest, fileutils, tmpdir), JRuby 9.4.15.0, OpenJDK 17 (Temurin JRE), Docker multi-stage build, docker-compose, RSpec.

## Global Constraints

- JRuby only, jruby-9.4.15.0; target Ruby 3.1 syntax in RuboCop.
- `bin/setup` uses ONLY Ruby stdlib (no gems) so it runs under any Ruby present at build time; shells out to `unzip` (a documented prerequisite).
- All downloaded artifacts (FITS zip, JRuby tarball, `file` source tarball) MUST be SHA-256 verified against a pinned constant before use; fail loudly on mismatch.
- FITS validity check is exactly `Dir.exist?(File.join(fits_home, 'lib'))` — match `Config#validate_fits_home!`.
- Runtime base image: `eclipse-temurin:17-jre-jammy`. JRE is sufficient to run JRuby at runtime.
- The container always runs as an unprivileged non-root user; only the numeric UID/GID are parameterized via `FITS_UID`/`FITS_GID`. No host `fits` account is assumed.
- Socket path convention: `FITS_SOCKET_PATH=/run/fits/fits.sock`. Socket ends up `0660`, group-reachable, never world-accessible. No published network ports.
- JAVA_OPTS parity with systemd: `-Xms256m -Xmx1g -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+ExitOnOutOfMemoryError`.
- The entrypoint MUST `exec bin/fits-server` so SIGTERM/SIGINT reach the JRuby process (graceful drain already implemented).
- Image is NOT published to Docker Hub — local build only (`build: .`, no `image:` push target).
- `.env` is already gitignored; commit `.env.example` as the template.
- Only the current developer pushes/sets remotes; this plan makes local commits only.
- Documentation split: README owns ALL Docker content; INSTALL owns FITS acquisition + OS-dependency prerequisites; DEPLOYMENT stays systemd-only and is NOT modified.

## Known-Good Facts (verified 2026-07-16)

- FITS 1.6.0 zip: `https://github.com/harvard-lts/fits/releases/download/1.6.0/fits-1.6.0.zip` (HTTP 200, redirects to release-assets host).
- JRuby 9.4.15.0 bin tarball: `https://repo1.maven.org/maven2/org/jruby/jruby-dist/9.4.15.0/jruby-dist-9.4.15.0-bin.tar.gz` (HTTP 200).
- `file` 5.43 source: `https://astron.com/pub/file/file-5.43.tar.gz`, SHA-256 `8c8015e91ae0e8d0321d94c78239892ef9dbc70c4ade0008c0e95894abfb1991` (from Harvard's Dockerfile).
- `bin/fits-server` exists and calls `Config#validate!` (fails fast), then starts `SocketServer`; traps INT/TERM. Do not change it.
- FITS runtime apt deps (from Harvard's Dockerfile): `python3 python-is-python3 libarchive-zip-perl libio-compress-perl libcompress-raw-zlib-perl libcompress-bzip2-perl libcompress-raw-bzip2-perl libio-digest-perl libdigest-md5-file-perl libdigest-perl-md5-perl libdigest-sha-perl libposix-strptime-perl libunicode-linebreak-perl libmms0 libcurl3-gnutls`.
- `file` build deps (builder only): `make gcc curl` + zlib headers (`zlib1g-dev`).

## SHA-256 Pinning Protocol (applies to Tasks 1, 4, 5)

The plan does NOT contain fabricated checksums. For each pinned artifact, the implementer MUST, at implementation time:
1. Download the artifact from the URL above.
2. Compute its SHA-256 (`sha256sum <file>` or `Digest::SHA256.file(path).hexdigest`).
3. Record that value as the pinned constant in code, and paste the command + output into the task report as evidence.
The `file-5.43` SHA-256 is already known (above) and may be used directly.

## File Structure

- `bin/setup` — NEW. Executable Ruby script; idempotent validate-or-fetch FITS installer. Pure stdlib.
- `lib/fits_jruby/fits_installer.rb` — NEW. `FitsJruby::FitsInstaller` class holding the real logic (so it is unit-testable without invoking the script). `bin/setup` is a thin wrapper that instantiates and calls it.
- `spec/fits_installer_spec.rb` — NEW. Fast unit tests with mocked download/filesystem.
- `bin/docker-entrypoint` — NEW. Shell script: idempotent `bin/setup` + ensure socket dir + `exec bin/fits-server`.
- `Dockerfile` — NEW. Multi-stage.
- `.dockerignore` — NEW.
- `docker-compose.yml` — NEW.
- `.env.example` — NEW.
- `README.md` — MODIFIED. Add the Docker section.
- `INSTALL.md` — MODIFIED. Add `bin/setup` + FITS OS-dependency prerequisites.
- `DEPLOYMENT.md` — UNCHANGED.

Rationale for the `FitsInstaller` class: the design says unit-test `bin/setup`'s logic with mocked IO. Putting the logic in a class (not the executable) makes it directly testable and keeps `bin/setup` a 3-line wrapper. This mirrors the existing pattern (`bin/fits-server` is a thin wrapper over `lib/` classes).

---

## Task 1: FitsInstaller class + fast unit tests

**Files:**
- Create: `lib/fits_jruby/fits_installer.rb`
- Test: `spec/fits_installer_spec.rb`

**Interfaces:**
- Consumes: nothing (pure stdlib).
- Produces: `FitsJruby::FitsInstaller.new(fits_home:, version: '1.6.0', url: nil, sha256: nil, logger: nil, downloader: nil)`. Public method `#install! -> Symbol` returning `:present` (already valid, no-op) or `:installed` (fetched + extracted). Raises `FitsJruby::FitsInstaller::Error` on SHA-256 mismatch or download/extract failure. Class constants: `FITS_VERSION`, `DEFAULT_URL` (a template using the version), `EXPECTED_SHA256`. The `downloader` injectable is a callable `->(url, dest_path) { ... }` defaulting to a real net/http download — this is the seam that lets tests avoid real network.

Design notes for the implementer:
- `#install!` logic: (1) if `Dir.exist?(File.join(@fits_home, 'lib'))` → log "FITS already present, skipping" and return `:present`. (2) Else create a temp dir (`Dir.mktmpdir`), download the zip into it via `@downloader`, (3) verify `Digest::SHA256.file(zip).hexdigest == @sha256` (case-insensitive compare) else raise Error, (4) `unzip` into a temp extract dir, (5) locate the extracted FITS root (the zip contains a top-level dir; find the dir containing `lib/`), (6) atomically move it into place as `@fits_home` (`FileUtils.mkdir_p` parent, `FileUtils.mv`), (7) return `:installed`. Temp dirs auto-clean via `Dir.mktmpdir` block.
- Shell out to unzip with an explicit argument array (no shell string interpolation): `system('unzip', '-q', zip_path, '-d', extract_dir)` and raise Error unless it returns true.
- Do NOT extract before the SHA-256 check passes.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/fits_installer_spec.rb
# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'digest'
require 'fits_jruby/fits_installer'

RSpec.describe FitsJruby::FitsInstaller do
  # Builds a fake FITS zip whose top-level dir contains a lib/ subdir, returns its path + sha256.
  def build_fake_fits_zip(dir)
    root = File.join(dir, 'fits-1.6.0')
    FileUtils.mkdir_p(File.join(root, 'lib'))
    File.write(File.join(root, 'lib', 'fits.jar'), 'jar-bytes')
    zip = File.join(dir, 'fits.zip')
    system('zip', '-q', '-r', zip, 'fits-1.6.0', chdir: dir) or raise 'zip failed'
    [zip, Digest::SHA256.file(zip).hexdigest]
  end

  it 'is a no-op when FITS_HOME already has a lib/ directory' do
    Dir.mktmpdir do |home|
      FileUtils.mkdir_p(File.join(home, 'lib'))
      called = false
      installer = described_class.new(
        fits_home: home, sha256: 'unused',
        downloader: ->(_url, _dest) { called = true }
      )
      expect(installer.install!).to eq(:present)
      expect(called).to be(false)
    end
  end

  it 'downloads, verifies, extracts, and installs when FITS_HOME is missing' do
    Dir.mktmpdir do |work|
      zip, sha = build_fake_fits_zip(work)
      home = File.join(work, 'dest', 'fits')
      installer = described_class.new(
        fits_home: home, sha256: sha,
        downloader: ->(_url, dest) { FileUtils.cp(zip, dest) }
      )
      expect(installer.install!).to eq(:installed)
      expect(Dir.exist?(File.join(home, 'lib'))).to be(true)
      expect(File.read(File.join(home, 'lib', 'fits.jar'))).to eq('jar-bytes')
    end
  end

  it 'raises on SHA-256 mismatch and does not create FITS_HOME' do
    Dir.mktmpdir do |work|
      zip, = build_fake_fits_zip(work)
      home = File.join(work, 'dest', 'fits')
      installer = described_class.new(
        fits_home: home, sha256: 'deadbeef',
        downloader: ->(_url, dest) { FileUtils.cp(zip, dest) }
      )
      expect { installer.install! }.to raise_error(FitsJruby::FitsInstaller::Error, /sha|checksum/i)
      expect(Dir.exist?(home)).to be(false)
    end
  end

  it 'raises when the download produces no usable FITS root' do
    Dir.mktmpdir do |work|
      # A zip with no lib/ dir inside
      FileUtils.mkdir_p(File.join(work, 'empty'))
      bad = File.join(work, 'bad.zip')
      system('zip', '-q', '-r', bad, 'empty', chdir: work) or raise 'zip failed'
      home = File.join(work, 'dest', 'fits')
      installer = described_class.new(
        fits_home: home, sha256: Digest::SHA256.file(bad).hexdigest,
        downloader: ->(_url, dest) { FileUtils.cp(bad, dest) }
      )
      expect { installer.install! }.to raise_error(FitsJruby::FitsInstaller::Error)
      expect(Dir.exist?(home)).to be(false)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/fits_installer_spec.rb`
Expected: FAIL with `cannot load such file -- fits_jruby/fits_installer`.

- [ ] **Step 3: Write the implementation**

```ruby
# lib/fits_jruby/fits_installer.rb
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tmpdir'
require 'net/http'
require 'uri'
require 'logger'

module FitsJruby
  # Idempotent FITS installer: validate-or-fetch. Pure stdlib so it runs under
  # any Ruby available at build time. The downloader is injectable for testing.
  class FitsInstaller
    class Error < StandardError; end

    FITS_VERSION = '1.6.0'
    # NOTE: EXPECTED_SHA256 is filled in at implementation time per the plan's
    # SHA-256 Pinning Protocol (download the real zip, compute, paste evidence).
    EXPECTED_SHA256 = 'REPLACE_WITH_REAL_SHA256'

    def self.default_url(version)
      "https://github.com/harvard-lts/fits/releases/download/#{version}/fits-#{version}.zip"
    end

    def self.default_downloader
      lambda do |url, dest|
        uri = URI(url)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
          request = Net::HTTP::Get.new(uri)
          http.request(request) do |response|
            case response
            when Net::HTTPRedirection
              return default_downloader.call(response['location'], dest)
            when Net::HTTPSuccess
              File.open(dest, 'wb') { |f| response.read_body { |chunk| f.write(chunk) } }
            else
              raise Error, "download failed: HTTP #{response.code} for #{url}"
            end
          end
        end
      end
    end

    def initialize(fits_home:, version: FITS_VERSION, url: nil, sha256: EXPECTED_SHA256,
                   logger: nil, downloader: nil)
      @fits_home = fits_home
      @version = version
      @url = url || self.class.default_url(version)
      @sha256 = sha256
      @logger = logger || Logger.new($stdout)
      @downloader = downloader || self.class.default_downloader
    end

    # Returns :present (already valid, no-op) or :installed (fetched + extracted).
    def install!
      if valid_install?(@fits_home)
        @logger.info("FITS already present at #{@fits_home}, skipping")
        return :present
      end

      Dir.mktmpdir('fits-setup') do |tmp|
        zip = File.join(tmp, "fits-#{@version}.zip")
        @logger.info("downloading FITS #{@version} from #{@url}")
        @downloader.call(@url, zip)
        verify_checksum!(zip)
        root = extract_and_locate_root(zip, tmp)
        install_atomically(root)
      end
      @logger.info("FITS installed at #{@fits_home}")
      :installed
    end

    private

    def valid_install?(path)
      Dir.exist?(File.join(path, 'lib'))
    end

    def verify_checksum!(zip)
      actual = Digest::SHA256.file(zip).hexdigest
      return if actual.casecmp?(@sha256)

      raise Error, "FITS zip checksum mismatch: expected #{@sha256}, got #{actual}"
    end

    def extract_and_locate_root(zip, tmp)
      extract_dir = File.join(tmp, 'extract')
      FileUtils.mkdir_p(extract_dir)
      unless system('unzip', '-q', zip, '-d', extract_dir)
        raise Error, 'unzip failed (is the `unzip` command installed?)'
      end

      # The FITS zip contains a top-level dir that holds lib/. Find it.
      candidate = Dir.glob(File.join(extract_dir, '**', 'lib'), File::FNM_DOTMATCH)
                     .map { |lib| File.dirname(lib) }
                     .find { |d| valid_install?(d) }
      raise Error, 'downloaded archive did not contain a valid FITS install (no lib/)' unless candidate

      candidate
    end

    def install_atomically(root)
      FileUtils.mkdir_p(File.dirname(@fits_home))
      FileUtils.mv(root, @fits_home)
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/fits_installer_spec.rb`
Expected: PASS (4 examples, 0 failures). (These tests inject a fake downloader and never hit the network or the real EXPECTED_SHA256.)

- [ ] **Step 5: Run rubocop**

Run: `bundle exec rubocop lib/fits_jruby/fits_installer.rb spec/fits_installer_spec.rb`
Expected: clean. If `Metrics/MethodLength`/`AbcSize` trips on `install!` or `default_downloader`, extract small private helpers rather than disabling cops; a targeted disable is acceptable only for the redirect-following downloader if needed — note it in the report.

- [ ] **Step 6: Commit**

```bash
git add lib/fits_jruby/fits_installer.rb spec/fits_installer_spec.rb
git commit -m "feat: add idempotent FitsInstaller with SHA-256 verification"
```

---

## Task 2: bin/setup executable wrapper

**Files:**
- Create: `bin/setup`

**Interfaces:**
- Consumes: `FitsJruby::FitsInstaller` from Task 1.
- Produces: an executable `bin/setup` that reads `FITS_HOME` from the environment, runs `FitsInstaller#install!`, prints a clear message, and exits 0 on success (`:present` or `:installed`) or non-zero with a clear message on failure. Optional env overrides: `FITS_VERSION`, `FITS_URL`, `FITS_SHA256`.

- [ ] **Step 1: Write the executable**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

# Idempotent FITS installer. Safe to run manually, in the Docker builder stage,
# and from the container entrypoint. Uses only Ruby stdlib.
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'fits_jruby/fits_installer'

fits_home = ENV['FITS_HOME']
if fits_home.nil? || fits_home.empty?
  warn 'setup error: FITS_HOME must be set (target install directory)'
  exit 1
end

installer = FitsJruby::FitsInstaller.new(
  fits_home: fits_home,
  version: ENV.fetch('FITS_VERSION', FitsJruby::FitsInstaller::FITS_VERSION),
  url: ENV['FITS_URL'],
  sha256: ENV.fetch('FITS_SHA256', FitsJruby::FitsInstaller::EXPECTED_SHA256)
)

begin
  result = installer.install!
  puts(result == :present ? 'FITS already present.' : 'FITS installed.')
  exit 0
rescue FitsJruby::FitsInstaller::Error => e
  warn "setup error: #{e.message}"
  exit 1
end
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x bin/setup`
Expected: no output; `ls -l bin/setup` shows the `x` bit.

- [ ] **Step 3: Verify the no-op path against the real local FITS**

Run: `FITS_HOME=~/tools/fits-1.6.0 ruby bin/setup`
Expected: prints `FITS already present.` and exits 0 (this uses the real local FITS install, which has a `lib/` dir, so it takes the no-op path — no download, no need for the real SHA-256).

- [ ] **Step 4: Verify the missing-FITS-HOME error path**

Run: `ruby bin/setup` (no FITS_HOME)
Expected: prints `setup error: FITS_HOME must be set ...` and exits 1.

- [ ] **Step 5: Run rubocop**

Run: `bundle exec rubocop bin/setup`
Expected: clean. (`.rubocop.yml` may need `bin/setup` included; it already inspects the repo — confirm no offenses.)

- [ ] **Step 6: Commit**

```bash
git add bin/setup
git commit -m "feat: add bin/setup executable wrapping FitsInstaller"
```

---

## Task 3: .dockerignore

**Files:**
- Create: `.dockerignore`

**Interfaces:** none (build-context hygiene).

- [ ] **Step 1: Create `.dockerignore`**

```
.git
.github
.claude
.superpowers
docs
tmp
coverage
*.sock
fits.log
.env
```

Note: `spec/` is intentionally NOT ignored (per design — allow running specs in a container later).

- [ ] **Step 2: Commit**

```bash
git add .dockerignore
git commit -m "chore: add .dockerignore (keep spec/, drop scratch and secrets)"
```

---

## Task 4: Multi-stage Dockerfile

**Files:**
- Create: `Dockerfile`

**Interfaces:**
- Consumes: `bin/setup` (Task 2), `bin/docker-entrypoint` (Task 5 — referenced by ENTRYPOINT; create Dockerfile now, entrypoint in Task 5, and the image won't build-run until both exist, which is fine — the build itself succeeds).
- Produces: a locally-buildable image `fits-jruby` running the socket server.

Implementer notes:
- The builder base needs Ruby to run `bin/setup`. Use a base that has both a JDK/build tooling AND lets us install a Ruby simply. Simplest reproducible option: builder = `eclipse-temurin:17-jdk-jammy`, then `apt-get install -y ruby` (system Ruby is fine — `bin/setup` is stdlib-only and Ruby-agnostic). This avoids installing JRuby twice.
- SHA-256s for the FITS zip and JRuby tarball follow the SHA-256 Pinning Protocol (compute at implementation time, paste evidence into the report). The `file-5.43` SHA-256 is known (see Known-Good Facts).
- The `EXPECTED_SHA256` constant in `lib/fits_jruby/fits_installer.rb` MUST be updated to the real FITS zip checksum as part of THIS task (the builder's `bin/setup` run will verify against it, so a wrong/placeholder value makes the build fail — that is the forcing function).

- [ ] **Step 1: Write the Dockerfile**

```dockerfile
# syntax=docker/dockerfile:1

########## Builder stage ##########
FROM eclipse-temurin:17-jdk-jammy AS builder

ARG FILE_VERSION=5.43
ARG FILE_SHA256=8c8015e91ae0e8d0321d94c78239892ef9dbc70c4ade0008c0e95894abfb1991

RUN apt-get update && apt-get install -yqq --no-install-recommends \
      ruby curl unzip make gcc zlib1g-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Build `file` FILE_VERSION from source (Harvard's recipe), install into /usr/local.
RUN cd /var/tmp && \
    curl -fsSLo file-${FILE_VERSION}.tar.gz https://astron.com/pub/file/file-${FILE_VERSION}.tar.gz && \
    echo "${FILE_SHA256}  file-${FILE_VERSION}.tar.gz" | sha256sum --check && \
    tar xzf file-${FILE_VERSION}.tar.gz && \
    cd file-${FILE_VERSION} && ./configure --prefix=/usr/local && make -j"$(nproc)" && make install && \
    cd / && rm -rf /var/tmp/file-${FILE_VERSION}*

# Install FITS via bin/setup (SHA-256 verified inside FitsInstaller).
COPY bin/setup bin/setup
COPY lib/fits_jruby/fits_installer.rb lib/fits_jruby/fits_installer.rb
ENV FITS_HOME=/opt/fits
RUN ruby bin/setup

########## Runtime stage ##########
FROM eclipse-temurin:17-jre-jammy AS runtime

# FITS tool runtime dependencies (no compilers).
RUN apt-get update && apt-get install -yqq --no-install-recommends \
      python3 python-is-python3 \
      libarchive-zip-perl libio-compress-perl libcompress-raw-zlib-perl \
      libcompress-bzip2-perl libcompress-raw-bzip2-perl libio-digest-perl \
      libdigest-md5-file-perl libdigest-perl-md5-perl libdigest-sha-perl \
      libposix-strptime-perl libunicode-linebreak-perl \
      libmms0 libcurl3-gnutls \
      unzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install JRuby 9.4.15.0 (SHA-256 verified) to /opt/jruby.
ARG JRUBY_VERSION=9.4.15.0
ARG JRUBY_SHA256=REPLACE_WITH_REAL_SHA256
RUN curl -fsSLo /tmp/jruby.tar.gz \
      https://repo1.maven.org/maven2/org/jruby/jruby-dist/${JRUBY_VERSION}/jruby-dist-${JRUBY_VERSION}-bin.tar.gz && \
    echo "${JRUBY_SHA256}  /tmp/jruby.tar.gz" | sha256sum --check && \
    mkdir -p /opt/jruby && tar xzf /tmp/jruby.tar.gz -C /opt/jruby --strip-components=1 && \
    rm /tmp/jruby.tar.gz
ENV PATH=/opt/jruby/bin:$PATH

WORKDIR /app

# Bundle install (production only) using the app's Gemfile.
COPY Gemfile Gemfile.lock ./
RUN jruby -S gem install bundler && \
    jruby -S bundle config set --local without 'development test' && \
    jruby -S bundle install

# App code + the built `file` + FITS.
COPY --from=builder /usr/local /usr/local
COPY --from=builder /opt/fits /opt/fits
COPY . /app
RUN ldconfig

# Unprivileged user; UID/GID overridable at run time.
ARG FITS_UID=1000
ARG FITS_GID=1000
RUN groupadd -g ${FITS_GID} fits && \
    useradd -u ${FITS_UID} -g ${FITS_GID} -M -s /usr/sbin/nologin fits && \
    mkdir -p /run/fits && chown fits:fits /run/fits

ENV FITS_HOME=/opt/fits \
    FITS_SOCKET_PATH=/run/fits/fits.sock \
    FITS_QUEUE_CAPACITY=64 \
    FITS_LOG_LEVEL=info \
    FITS_READ_TIMEOUT=5 \
    FITS_WRITE_TIMEOUT=30 \
    JAVA_OPTS="-Xms256m -Xmx1g -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+ExitOnOutOfMemoryError"

USER fits
ENTRYPOINT ["bin/docker-entrypoint"]
```

- [ ] **Step 2: Fill in the real SHA-256 constants (SHA-256 Pinning Protocol)**

Run:
```bash
cd /tmp
curl -fsSLo fits.zip https://github.com/harvard-lts/fits/releases/download/1.6.0/fits-1.6.0.zip && sha256sum fits.zip
curl -fsSLo jruby.tar.gz https://repo1.maven.org/maven2/org/jruby/jruby-dist/9.4.15.0/jruby-dist-9.4.15.0-bin.tar.gz && sha256sum jruby.tar.gz
```
Then:
- Put the FITS zip SHA-256 into `EXPECTED_SHA256` in `lib/fits_jruby/fits_installer.rb`.
- Put the JRuby tarball SHA-256 into the `JRUBY_SHA256` ARG default in the Dockerfile.
Paste both commands + outputs into the task report.
Expected: two 64-hex-char checksums; `fits_installer_spec.rb` still passes (its tests inject their own sha, so they are independent of `EXPECTED_SHA256`).

- [ ] **Step 3: Build the image**

Run: `docker build -t fits-jruby .`
Expected: build succeeds through both stages. The builder's `ruby bin/setup` downloads FITS and verifies it against the real `EXPECTED_SHA256` (a wrong value fails here). The runtime stage verifies the JRuby tarball. If the build fails on a checksum, the pinned value is wrong — re-run Step 2.

Note: `bin/docker-entrypoint` does not exist until Task 5, so the image cannot be *run* yet, but `docker build` completes (ENTRYPOINT is not executed at build time). Confirm the build finishes and produces an image.

- [ ] **Step 4: Commit**

```bash
git add Dockerfile lib/fits_jruby/fits_installer.rb
git commit -m "feat: add multi-stage Dockerfile; pin FITS and JRuby checksums"
```

---

## Task 5: bin/docker-entrypoint

**Files:**
- Create: `bin/docker-entrypoint`

**Interfaces:**
- Consumes: `bin/setup` (Task 2), `bin/fits-server` (existing).
- Produces: an executable entrypoint that runs `bin/setup` idempotently, ensures the socket directory exists, then `exec`s the server.

- [ ] **Step 1: Write the entrypoint**

```bash
#!/usr/bin/env bash
# Container entrypoint: idempotent FITS check, then hand off to the server.
set -euo pipefail

# 1. Idempotent FITS install/verify. No-op when FITS is already baked in.
#    Fails loudly (non-zero) if FITS is missing and cannot be fetched.
ruby bin/setup

# 2. Ensure the socket directory exists (normally provided by a bind mount).
socket_dir="$(dirname "${FITS_SOCKET_PATH:-/run/fits/fits.sock}")"
mkdir -p "$socket_dir" 2>/dev/null || true

# 3. Hand off to the server so it becomes the signal-receiving process.
#    exec is required so SIGTERM/SIGINT reach JRuby for graceful shutdown.
exec bin/fits-server
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x bin/docker-entrypoint`
Expected: `ls -l bin/docker-entrypoint` shows the `x` bit.

- [ ] **Step 3: Rebuild and run the container (real end-to-end smoke)**

Run:
```bash
docker build -t fits-jruby .
mkdir -p /tmp/fits-run
docker run --rm -d --name fits-smoke \
  -u "$(id -u):$(id -g)" \
  -v /tmp/fits-run:/run/fits \
  -v "$PWD/spec/fixtures:$PWD/spec/fixtures:ro" \
  fits-jruby
# wait for the socket
for i in $(seq 1 60); do [ -S /tmp/fits-run/fits.sock ] && break; sleep 1; done
printf "$PWD/spec/fixtures/sample.tif\n" | socat - UNIX-CONNECT:/tmp/fits-run/fits.sock | head -3
printf 'STATS\n' | socat - UNIX-CONNECT:/tmp/fits-run/fits.sock
docker stop fits-smoke
```
Expected: the examine request returns XML beginning with `<?xml` identifying `image/tiff`; STATS returns a JSON object; `docker stop` shuts down cleanly. If `socat` is unavailable use `nc -U`. Note: the `-u $(id -u):$(id -g)` makes the container run as you, and the bind-mounted `/tmp/fits-run` socket dir is owned by you, so the socket is reachable. Paste the observed XML head + STATS JSON into the report.

- [ ] **Step 4: Commit**

```bash
git add bin/docker-entrypoint
git commit -m "feat: add container entrypoint (idempotent setup + exec server)"
```

---

## Task 6: docker-compose.yml + .env.example

**Files:**
- Create: `docker-compose.yml`
- Create: `.env.example`

**Interfaces:**
- Consumes: the Dockerfile (Task 4) and entrypoint (Task 5).
- Produces: `docker compose up` running the server with prod-parity config.

- [ ] **Step 1: Write `.env.example`**

```bash
# Copy to .env and adjust. .env is gitignored.
#
# Dev (default): set these to your own IDs so the socket is owned by you:
#   FITS_UID=$(id -u)  FITS_GID=$(id -g)
# Prod-rehearsal: create a `fits` group, add your client user to it, and set
#   FITS_GID to that group's gid to exercise the production posture locally.
FITS_UID=1000
FITS_GID=1000

# Host directory that will hold the Unix socket (bind-mounted to /run/fits).
FITS_SOCKET_DIR=./run

# Tunables (prod-parity defaults shown).
FITS_QUEUE_CAPACITY=64
FITS_LOG_LEVEL=info
FITS_READ_TIMEOUT=5
FITS_WRITE_TIMEOUT=30
```

- [ ] **Step 2: Write `docker-compose.yml`**

```yaml
services:
  fits:
    build: .
    # Run as a configurable unprivileged UID/GID (no host `fits` account needed).
    user: "${FITS_UID}:${FITS_GID}"
    environment:
      FITS_SOCKET_PATH: /run/fits/fits.sock
      FITS_QUEUE_CAPACITY: "${FITS_QUEUE_CAPACITY}"
      FITS_LOG_LEVEL: "${FITS_LOG_LEVEL}"
      FITS_READ_TIMEOUT: "${FITS_READ_TIMEOUT}"
      FITS_WRITE_TIMEOUT: "${FITS_WRITE_TIMEOUT}"
      JAVA_OPTS: "-Xms256m -Xmx1g -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+ExitOnOutOfMemoryError"
    volumes:
      # Socket directory shared with the host so host clients can connect.
      - "${FITS_SOCKET_DIR}:/run/fits"
      # Media to analyze: bind-mount host dirs READ-ONLY at the SAME path so a
      # client-sent absolute path resolves identically inside the container.
      # Add one line per host directory you want analyzable, e.g.:
      # - /srv/media:/srv/media:ro
      - "${PWD}/spec/fixtures:${PWD}/spec/fixtures:ro"
    # Memory ceiling mirroring the systemd MemoryMax=1500M.
    mem_limit: 1500m
    # Hardening (parity with systemd ProtectSystem/NoNewPrivileges intent).
    read_only: true
    tmpfs:
      - /tmp
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    init: true
    # No published ports: the server is reachable only over the Unix socket.
```

- [ ] **Step 3: Verify compose config parses**

Run: `cp .env.example .env && FITS_UID=$(id -u) FITS_GID=$(id -g) docker compose config`
Expected: prints the fully-resolved config with no errors; `user:` shows your real UID:GID; the socket and fixtures volumes are present. (`docker compose config` validates and interpolates without starting anything.)

- [ ] **Step 4: End-to-end via compose**

Run:
```bash
cp .env.example .env
export FITS_UID=$(id -u) FITS_GID=$(id -g)
mkdir -p ./run
docker compose up -d --build
for i in $(seq 1 60); do [ -S ./run/fits.sock ] && break; sleep 1; done
printf "$PWD/spec/fixtures/sample.jp2\n" | socat - UNIX-CONNECT:./run/fits.sock | head -3
printf 'STATS\n' | socat - UNIX-CONNECT:./run/fits.sock
docker compose down
```
Expected: XML beginning with `<?xml` (jp2 identification) and a STATS JSON object; `docker compose down` stops cleanly. Paste output into the report. Then remove the local `.env` and `./run` if desired (both are gitignored / scratch).

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml .env.example
git commit -m "feat: add docker-compose local-dev driver and .env.example"
```

---

## Task 7: Documentation (README + INSTALL)

**Files:**
- Modify: `README.md`
- Modify: `INSTALL.md`
- (DEPLOYMENT.md is intentionally NOT modified.)

**Interfaces:** none (docs).

- [ ] **Step 1: Add the Docker section to README.md**

Add a "## Run with Docker (local dev)" section that documents, matching the built artifacts exactly:
- One-line purpose: a local-dev container that simulates the production systemd deployment.
- Prerequisites: Docker + Docker Compose; `socat` or `nc` for smoke requests.
- Quick start:
  ```bash
  cp .env.example .env
  # Dev: own the socket so your host processes can reach it
  export FITS_UID=$(id -u) FITS_GID=$(id -g)
  mkdir -p ./run
  docker compose up --build
  ```
- How to send requests (path parity + socket):
  ```bash
  printf '/abs/path/to/file.tif\n' | socat - UNIX-CONNECT:./run/fits.sock
  printf 'STATS\n' | socat - UNIX-CONNECT:./run/fits.sock
  ```
- Media mounts: explain read-only path-parity bind mounts — to analyze host files, add `- /your/media:/your/media:ro` lines to the compose `volumes:` (the client sends the same absolute path).
- UID/GID recipes: **dev** (own `id -u`/`id -g`, default) vs **prod-rehearsal** (create a `fits` group, set `FITS_GID`). State that no host `fits` account is required for dev.
- The `docker run` equivalent (non-compose) with `-u`, the `-v` socket and media mounts, `-e` env vars, and `--memory 1500m`.
- Note: image is local-only (not published to a registry).

- [ ] **Step 2: Add bin/setup + FITS OS deps to INSTALL.md**

- Add a step using `bin/setup` to acquire FITS: `FITS_HOME=~/tools/fits-1.6.0 ruby bin/setup` (idempotent; downloads + verifies + unzips if missing, no-op if present). Keep/adjust any existing manual download instructions to point at `bin/setup` as the recommended path. Note `unzip` is required.
- Add a "FITS tool OS dependencies" subsection listing the apt packages FITS's bundled tools need on a host/systemd install (these are auto-installed in the container): `python3` (jpylyzer); the ExifTool Perl libraries (`libarchive-zip-perl libio-compress-perl libcompress-raw-zlib-perl libcompress-bzip2-perl libcompress-raw-bzip2-perl libio-digest-perl libdigest-md5-file-perl libdigest-perl-md5-perl libdigest-sha-perl libposix-strptime-perl libunicode-linebreak-perl`); MediaInfo libs (`libmms0 libcurl3-gnutls`); and a note that the `file` command must be present (Ubuntu ships one; FITS was tested against `file` 5.43).

- [ ] **Step 3: Verify no accidental DEPLOYMENT.md change and docs are consistent**

Run: `git status --short && git diff --stat`
Expected: only `README.md` and `INSTALL.md` modified; `DEPLOYMENT.md` NOT listed. Skim both to confirm commands match the real files (socket path `./run/fits.sock` in compose examples, `bin/setup` invocation correct).

- [ ] **Step 4: Run the full quality gate**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: all specs pass (includes the new `fits_installer_spec.rb`); rubocop clean.

- [ ] **Step 5: Commit**

```bash
git add README.md INSTALL.md
git commit -m "docs: document Docker workflow (README) and bin/setup + FITS OS deps (INSTALL)"
```

---

## Task 8: Final verification pass

**Files:** none (verification only).

- [ ] **Step 1: Full quality gate**

Run:
```bash
bundle exec rubocop
bundle exec bundle-audit check --update
bundle exec rspec
FITS_HOME=~/tools/fits-1.6.0 JRUBY_OPTS="-J-Xmx512m" bundle exec rspec --tag integration
```
Expected: rubocop clean; no CVEs; fast specs pass (incl. fits_installer); integration 4 pass.

- [ ] **Step 2: Full container smoke via compose (real end-to-end)**

Run:
```bash
export FITS_UID=$(id -u) FITS_GID=$(id -g)
cp .env.example .env && mkdir -p ./run
docker compose up -d --build
for i in $(seq 1 90); do [ -S ./run/fits.sock ] && break; sleep 1; done
printf "$PWD/spec/fixtures/sample.mp4\n" | socat - UNIX-CONNECT:./run/fits.sock | head -4
printf 'STATS\n' | socat - UNIX-CONNECT:./run/fits.sock
docker compose down
rm -f .env
```
Expected: mp4 identified in the returned XML; STATS JSON returned; clean shutdown. This is the manual smoke test the design calls for (and the basis for the Phase B G1 skill).

- [ ] **Step 3: Confirm no stray build artifacts tracked**

Run: `git status --short`
Expected: clean (or only intended files). `.env`, `./run`, `*.sock` are gitignored.

---

## Self-Review Notes

- **Spec coverage:** bin/setup idempotent installer + SHA-256 (T1/T2); multi-stage Dockerfile with file-from-source + JRuby + FITS copy (T4); eclipse-temurin:17-jre-jammy runtime (T4); entrypoint exec + idempotent setup (T5); compose + .env.example + UID/GID parameterization + read-only path-parity media + socket dir + hardening + mem limit (T6); .dockerignore keeping spec/ (T3); docs split README/INSTALL, DEPLOYMENT untouched (T7); fast unit tests with mocked IO (T1); manual container smoke (T5/T8); CI unchanged (no task touches CI). Phase B (G1 skill, ConnectionReader) intentionally deferred — not in this plan.
- **Placeholder scan:** the two `REPLACE_WITH_REAL_SHA256` values are deliberate and governed by the SHA-256 Pinning Protocol (computed against real downloads in T4 Step 2 with pasted evidence) — not silent placeholders. No other TBDs.
- **Type consistency:** `FitsInstaller.new(fits_home:, version:, url:, sha256:, logger:, downloader:)`, `#install! -> :present|:installed`, `FitsInstaller::Error`, constants `FITS_VERSION`/`EXPECTED_SHA256`/`default_url` — used consistently by `bin/setup` (T2), the Dockerfile builder (T4), and the entrypoint (T5). Socket path `/run/fits/fits.sock` and env-var names consistent across Dockerfile, compose, and docs.
