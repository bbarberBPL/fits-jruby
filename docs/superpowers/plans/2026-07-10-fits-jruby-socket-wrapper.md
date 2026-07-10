# fits-jruby Socket Wrapper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a long-running JRuby process that keeps one warm FITS instance in memory and serves file examinations (and a `STATS` command) over a Unix domain socket, returning native FITS XML.

**Architecture:** A thin `bin/fits-server` entrypoint wires together five focused units: `Config` (env vars), `Metrics` (thread-safe counters + JVM heap), `FitsExaminer` (the only unit touching Java/FITS), `RequestHandler` (pure protocol logic), and `SocketServer` (a `UNIXServer` with an acceptor thread feeding a bounded queue drained by one serial worker thread). Only the worker thread ever calls FITS, so examinations stay strictly serial while queue depth is exactly observable.

**Tech Stack:** JRuby 9.4.15.0 (Ruby 3.1 compat), OpenJDK 17, FITS 1.6.0 (Java jars loaded onto the JRuby classpath), RSpec, RuboCop, bundler-audit, Rake.

## Global Constraints

- JRuby only, currently jruby-9.4.15.0; target Ruby 3.1 syntax in RuboCop.
- OpenJDK >= 17.
- FITS 1.6.0 lives at `~/tools/fits-1.6.0` (jars under `lib/`); the server reads its location from `FITS_HOME` and never hard-codes it.
- Run lightweight with minimal JVM heap.
- Test-driven with RSpec is mandatory. Fast unit suite runs by default; integration tests are tagged `:integration` and excluded by default.
- Input is an absolute file path terminated by newline (`\n`); output on success is native FITS XML beginning with `<?xml`; errors are plain text not beginning with `<?xml`.
- Examinations are strictly serial (one FITS examination at a time).
- Logging goes to stdout/stderr.
- Java's `java.io.File` collides with Ruby's `File`; always reference the Java class as `Java::JavaIo::File`.
- The current developer is the only one who pushes commits or sets git remotes; this plan only creates local commits.

---

## File Structure

- `Gemfile` — declares rspec, rubocop, bundler-audit dev dependencies.
- `.rspec` — default CLI options; excludes `:integration` by default.
- `.rubocop.yml` — TargetRubyVersion 3.1, sane defaults.
- `Rakefile` — `lint`, `audit`, `spec`, `integration`, `fixtures` tasks.
- `lib/fits_jruby.rb` — top-level requires for the library.
- `lib/fits_jruby/config.rb` — `FitsJruby::Config`, env parsing + boot validation.
- `lib/fits_jruby/metrics.rb` — `FitsJruby::Metrics`, thread-safe counters/gauges + heap snapshot.
- `lib/fits_jruby/fits_examiner.rb` — `FitsJruby::FitsExaminer`, the only Java/FITS unit.
- `lib/fits_jruby/request_handler.rb` — `FitsJruby::RequestHandler`, pure protocol logic.
- `lib/fits_jruby/socket_server.rb` — `FitsJruby::SocketServer`, socket + acceptor/worker threads.
- `bin/fits-server` — executable entrypoint.
- `spec/spec_helper.rb`, `spec/*_spec.rb`, `spec/integration/*_spec.rb`, `spec/support/*`.
- Docs: `README.md`, `INSTALL.md`, `DEPLOYMENT.md`.

Tasks are ordered so each builds only on units defined earlier.

---

## Task 1: Project scaffolding (Gemfile, RSpec, RuboCop, Rakefile)

**Files:**
- Create: `Gemfile`
- Create: `.rspec`
- Create: `.rubocop.yml`
- Create: `Rakefile`
- Create: `spec/spec_helper.rb`
- Create: `lib/fits_jruby.rb`
- Create: `lib/fits_jruby/version.rb`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `FitsJruby::VERSION` (String); a runnable `bundle exec rspec` and `bundle exec rubocop`; RSpec configured so `:integration` is excluded by default.

- [ ] **Step 1: Create the Gemfile**

```ruby
# frozen_string_literal: true

source "https://rubygems.org"

gem "rake", "~> 13.0"

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "rubocop", "~> 1.60", require: false
  gem "bundler-audit", "~> 0.9", require: false
end
```

- [ ] **Step 2: Create `.rspec` so integration tests are excluded by default**

```
--require spec_helper
--format documentation
--tag ~integration
```

- [ ] **Step 3: Create `lib/fits_jruby/version.rb`**

```ruby
# frozen_string_literal: true

module FitsJruby
  VERSION = "0.1.0"
end
```

- [ ] **Step 4: Create `lib/fits_jruby.rb`**

```ruby
# frozen_string_literal: true

require_relative "fits_jruby/version"

module FitsJruby
end
```

- [ ] **Step 5: Create `spec/spec_helper.rb`**

```ruby
# frozen_string_literal: true

require "fits_jruby"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
```

- [ ] **Step 6: Create `.rubocop.yml`**

```yaml
AllCops:
  TargetRubyVersion: 3.1
  NewCops: enable
  SuggestExtensions: false
  Exclude:
    - "vendor/**/*"
    - "spec/fixtures/**/*"

Style/Documentation:
  Enabled: false

Metrics/BlockLength:
  Exclude:
    - "spec/**/*"
    - "Rakefile"

Metrics/MethodLength:
  Max: 25

Layout/LineLength:
  Max: 120
```

- [ ] **Step 7: Create the Rakefile**

```ruby
# frozen_string_literal: true

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec) do |t|
  t.rspec_opts = "--tag ~integration"
end

RSpec::Core::RakeTask.new(:integration) do |t|
  t.rspec_opts = "--tag integration"
end

desc "Run RuboCop"
task :lint do
  sh "bundle exec rubocop"
end

desc "Audit dependencies for known CVEs"
task :audit do
  sh "bundle exec bundle-audit check --update"
end

desc "Regenerate tiny media fixtures (requires ImageMagick, OpenJPEG, ffmpeg)"
task :fixtures do
  dir = "spec/fixtures"
  sh "magick -size 32x32 gradient:blue-white #{dir}/sample.tif"
  sh "magick -size 32x32 gradient:red-yellow /tmp/fits_fixture_src.png"
  sh "opj_compress -i /tmp/fits_fixture_src.png -o #{dir}/sample.jp2"
  sh "ffmpeg -loglevel error -y -f lavfi -i testsrc=duration=1:size=64x64:rate=15 " \
     "-pix_fmt yuv420p #{dir}/sample.mp4"
  sh "ffmpeg -loglevel error -y -f lavfi -i testsrc=duration=1:size=64x64:rate=15 " \
     "-pix_fmt yuv420p #{dir}/sample.mov"
end

task default: %i[spec lint]
```

- [ ] **Step 8: Install and verify the toolchain runs**

Run: `bundle install && bundle exec rspec && bundle exec rubocop`
Expected: rspec reports "0 examples, 0 failures"; rubocop reports "no offenses detected" (or only trivial ones you fix).

- [ ] **Step 9: Commit**

```bash
git add Gemfile Gemfile.lock .rspec .rubocop.yml Rakefile spec/spec_helper.rb lib/fits_jruby.rb lib/fits_jruby/version.rb
git commit -m "chore: scaffold gem with rspec, rubocop, bundler-audit, rake"
```

---

## Task 2: Config

**Files:**
- Create: `lib/fits_jruby/config.rb`
- Test: `spec/config_spec.rb`
- Modify: `lib/fits_jruby.rb` (add require)

**Interfaces:**
- Consumes: env hash (defaults to `ENV`).
- Produces: `FitsJruby::Config.new(env = ENV)` with readers `#fits_home` (String), `#socket_path` (String), `#queue_capacity` (Integer), `#log_level` (Symbol, one of `:debug/:info/:warn/:error`); and `#validate!` which raises `FitsJruby::Config::Error` (a `StandardError` subclass) when `FITS_HOME` is missing or has no `lib/` subdirectory. Defaults: socket `/tmp/fits.sock`, queue capacity `64`, log level `:info`.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/config_spec.rb
# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "fits_jruby/config"

RSpec.describe FitsJruby::Config do
  def env(overrides = {})
    { "FITS_HOME" => @fits_home }.merge(overrides)
  end

  around do |example|
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      @fits_home = dir
      example.run
    end
  end

  it "reads FITS_HOME" do
    expect(described_class.new(env).fits_home).to eq(@fits_home)
  end

  it "defaults the socket path, queue capacity, and log level" do
    config = described_class.new(env)
    expect(config.socket_path).to eq("/tmp/fits.sock")
    expect(config.queue_capacity).to eq(64)
    expect(config.log_level).to eq(:info)
  end

  it "reads overrides from the environment" do
    config = described_class.new(env(
      "FITS_SOCKET_PATH" => "/run/fits/fits.sock",
      "FITS_QUEUE_CAPACITY" => "8",
      "FITS_LOG_LEVEL" => "debug"
    ))
    expect(config.socket_path).to eq("/run/fits/fits.sock")
    expect(config.queue_capacity).to eq(8)
    expect(config.log_level).to eq(:debug)
  end

  it "validate! passes when FITS_HOME has a lib/ directory" do
    expect { described_class.new(env).validate! }.not_to raise_error
  end

  it "validate! raises when FITS_HOME is missing" do
    expect { described_class.new({}).validate! }
      .to raise_error(FitsJruby::Config::Error, /FITS_HOME/)
  end

  it "validate! raises when FITS_HOME has no lib/ directory" do
    Dir.mktmpdir do |empty|
      expect { described_class.new("FITS_HOME" => empty).validate! }
        .to raise_error(FitsJruby::Config::Error, /lib/)
    end
  end

  it "validate! raises on an invalid log level" do
    expect { described_class.new(env("FITS_LOG_LEVEL" => "verbose")).validate! }
      .to raise_error(FitsJruby::Config::Error, /log level/i)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/config_spec.rb`
Expected: FAIL with `cannot load such file -- fits_jruby/config`.

- [ ] **Step 3: Write the implementation**

```ruby
# lib/fits_jruby/config.rb
# frozen_string_literal: true

module FitsJruby
  # Reads and validates server configuration from environment variables.
  class Config
    class Error < StandardError; end

    DEFAULT_SOCKET_PATH = "/tmp/fits.sock"
    DEFAULT_QUEUE_CAPACITY = 64
    DEFAULT_LOG_LEVEL = :info
    VALID_LOG_LEVELS = %i[debug info warn error].freeze

    def initialize(env = ENV)
      @env = env
    end

    def fits_home
      @env["FITS_HOME"]
    end

    def socket_path
      @env.fetch("FITS_SOCKET_PATH", DEFAULT_SOCKET_PATH)
    end

    def queue_capacity
      Integer(@env.fetch("FITS_QUEUE_CAPACITY", DEFAULT_QUEUE_CAPACITY))
    end

    def log_level
      @env.fetch("FITS_LOG_LEVEL", DEFAULT_LOG_LEVEL.to_s).downcase.to_sym
    end

    def validate!
      raise Error, "FITS_HOME must be set" if fits_home.nil? || fits_home.empty?

      unless Dir.exist?(File.join(fits_home, "lib"))
        raise Error, "FITS_HOME (#{fits_home}) must contain a lib/ directory"
      end

      unless VALID_LOG_LEVELS.include?(log_level)
        raise Error, "invalid log level: #{log_level} (expected one of #{VALID_LOG_LEVELS.join(', ')})"
      end

      self
    end
  end
end
```

- [ ] **Step 4: Add the require to `lib/fits_jruby.rb`**

```ruby
# frozen_string_literal: true

require_relative "fits_jruby/version"
require_relative "fits_jruby/config"

module FitsJruby
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/config_spec.rb`
Expected: PASS (7 examples, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add lib/fits_jruby/config.rb lib/fits_jruby.rb spec/config_spec.rb
git commit -m "feat: add Config with env parsing and boot validation"
```

---

## Task 3: Metrics

**Files:**
- Create: `lib/fits_jruby/metrics.rb`
- Test: `spec/metrics_spec.rb`
- Modify: `lib/fits_jruby.rb` (add require)

**Interfaces:**
- Consumes: nothing external; uses `java.lang.management.ManagementFactory` for heap. To keep unit tests JVM-agnostic, the heap reader is injected: `Metrics.new(clock: -> { … }, heap_reader: -> { {used:, max:} })`. Both have real defaults (monotonic clock, live JVM MXBean).
- Produces: `FitsJruby::Metrics` with `#record_success`, `#record_error`, `#enqueue`, `#dequeue`, `#processing=(bool)`, and `#snapshot` returning a Hash with keys `:uptime_seconds`, `:requests_total`, `:requests_success`, `:requests_error`, `:queue_depth`, `:processing`, `:heap_used_bytes`, `:heap_max_bytes`. All mutators are mutex-guarded.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/metrics_spec.rb
# frozen_string_literal: true

require "fits_jruby/metrics"

RSpec.describe FitsJruby::Metrics do
  subject(:metrics) do
    described_class.new(
      clock: -> { @now },
      heap_reader: -> { { used: 1000, max: 4000 } }
    )
  end

  before { @now = 100.0 }

  it "starts with zeroed counters" do
    snap = metrics.snapshot
    expect(snap[:requests_total]).to eq(0)
    expect(snap[:requests_success]).to eq(0)
    expect(snap[:requests_error]).to eq(0)
    expect(snap[:queue_depth]).to eq(0)
    expect(snap[:processing]).to be(false)
  end

  it "counts successes and errors toward the total" do
    metrics.record_success
    metrics.record_success
    metrics.record_error
    snap = metrics.snapshot
    expect(snap[:requests_success]).to eq(2)
    expect(snap[:requests_error]).to eq(1)
    expect(snap[:requests_total]).to eq(3)
  end

  it "tracks queue depth via enqueue/dequeue" do
    metrics.enqueue
    metrics.enqueue
    metrics.dequeue
    expect(metrics.snapshot[:queue_depth]).to eq(1)
  end

  it "tracks the processing flag" do
    metrics.processing = true
    expect(metrics.snapshot[:processing]).to be(true)
    metrics.processing = false
    expect(metrics.snapshot[:processing]).to be(false)
  end

  it "computes uptime from the injected clock" do
    @now = 130.5
    expect(metrics.snapshot[:uptime_seconds]).to eq(30)
  end

  it "reports heap figures from the injected reader" do
    snap = metrics.snapshot
    expect(snap[:heap_used_bytes]).to eq(1000)
    expect(snap[:heap_max_bytes]).to eq(4000)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/metrics_spec.rb`
Expected: FAIL with `cannot load such file -- fits_jruby/metrics`.

- [ ] **Step 3: Write the implementation**

```ruby
# lib/fits_jruby/metrics.rb
# frozen_string_literal: true

module FitsJruby
  # Thread-safe counters and gauges describing server activity, plus a JVM
  # heap snapshot. Clock and heap reader are injectable for testing.
  class Metrics
    def self.default_clock
      -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    end

    def self.default_heap_reader
      lambda do
        require "java"
        bean = java.lang.management.ManagementFactory.getMemoryMXBean
        usage = bean.getHeapMemoryUsage
        { used: usage.getUsed, max: usage.getMax }
      end
    end

    def initialize(clock: self.class.default_clock, heap_reader: self.class.default_heap_reader)
      @clock = clock
      @heap_reader = heap_reader
      @started_at = @clock.call
      @mutex = Mutex.new
      @success = 0
      @error = 0
      @queue_depth = 0
      @processing = false
    end

    def record_success
      @mutex.synchronize { @success += 1 }
    end

    def record_error
      @mutex.synchronize { @error += 1 }
    end

    def enqueue
      @mutex.synchronize { @queue_depth += 1 }
    end

    def dequeue
      @mutex.synchronize { @queue_depth -= 1 if @queue_depth.positive? }
    end

    def processing=(value)
      @mutex.synchronize { @processing = value }
    end

    def snapshot
      heap = @heap_reader.call
      @mutex.synchronize do
        {
          uptime_seconds: (@clock.call - @started_at).to_i,
          requests_total: @success + @error,
          requests_success: @success,
          requests_error: @error,
          queue_depth: @queue_depth,
          processing: @processing,
          heap_used_bytes: heap[:used],
          heap_max_bytes: heap[:max]
        }
      end
    end
  end
end
```

- [ ] **Step 4: Add the require to `lib/fits_jruby.rb`**

```ruby
require_relative "fits_jruby/metrics"
```

(Add this line after the `config` require.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/metrics_spec.rb`
Expected: PASS (6 examples, 0 failures).

- [ ] **Step 6: Verify the real JVM heap reader works under JRuby**

Run: `ruby -Ilib -e 'require "fits_jruby/metrics"; p FitsJruby::Metrics.new.snapshot'`
Expected: prints a Hash where `:heap_used_bytes` and `:heap_max_bytes` are positive integers.

- [ ] **Step 7: Commit**

```bash
git add lib/fits_jruby/metrics.rb lib/fits_jruby.rb spec/metrics_spec.rb
git commit -m "feat: add thread-safe Metrics with JVM heap snapshot"
```

---

## Task 4: RequestHandler

**Files:**
- Create: `lib/fits_jruby/request_handler.rb`
- Test: `spec/request_handler_spec.rb`
- Modify: `lib/fits_jruby.rb` (add require)

**Interfaces:**
- Consumes: an `examiner` responding to `#examine(path) -> String` (may raise); a `metrics` responding to `#snapshot -> Hash`. Uses `FitsJruby::Config` only indirectly (not required here).
- Produces: `FitsJruby::RequestHandler.new(examiner:, metrics:)` with `#handle(raw_request) -> String`. Rules: strip the input; `"STATS"` → `metrics.snapshot.to_json` (a String beginning with `{`); empty → `"ERROR: empty request"`; relative path → `"ERROR: path must be absolute: <path>"`; missing/not-regular/unreadable → `"ERROR: <reason>: <path>"`; otherwise return `examiner.examine(path)`; if the examiner raises, return `"ERROR: examination failed: <message>"`. It does NOT touch counters — the server records success/error based on whether the response starts with `<?xml` (kept out of the handler so the handler stays a pure function).

- [ ] **Step 1: Write the failing test**

```ruby
# spec/request_handler_spec.rb
# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require "fits_jruby/request_handler"

RSpec.describe FitsJruby::RequestHandler do
  let(:examiner) { instance_double("FitsJruby::FitsExaminer") }
  let(:metrics)  { instance_double("FitsJruby::Metrics") }
  subject(:handler) { described_class.new(examiner: examiner, metrics: metrics) }

  it "returns metrics JSON for STATS" do
    allow(metrics).to receive(:snapshot).and_return(requests_total: 5, queue_depth: 1)
    result = handler.handle("STATS\n")
    expect(result).to start_with("{")
    expect(JSON.parse(result)).to include("requests_total" => 5, "queue_depth" => 1)
  end

  it "returns an error for an empty request" do
    expect(handler.handle("   \n")).to eq("ERROR: empty request")
  end

  it "rejects a relative path" do
    expect(handler.handle("relative/file.tif\n"))
      .to eq("ERROR: path must be absolute: relative/file.tif")
  end

  it "rejects a missing file" do
    expect(handler.handle("/does/not/exist.tif\n"))
      .to match(%r{\AERROR: .*: /does/not/exist\.tif\z})
  end

  it "rejects a directory (not a regular file)" do
    Dir.mktmpdir do |dir|
      expect(handler.handle("#{dir}\n")).to match(/\AERROR: /)
    end
  end

  it "delegates a valid path to the examiner and returns its XML" do
    Tempfile.create(["sample", ".tif"]) do |file|
      allow(examiner).to receive(:examine).with(file.path).and_return("<?xml version=\"1.0\"?><fits/>")
      expect(handler.handle("#{file.path}\n")).to eq("<?xml version=\"1.0\"?><fits/>")
    end
  end

  it "converts an examiner exception into an error line" do
    Tempfile.create(["sample", ".tif"]) do |file|
      allow(examiner).to receive(:examine).and_raise(StandardError, "boom")
      expect(handler.handle("#{file.path}\n")).to eq("ERROR: examination failed: boom")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/request_handler_spec.rb`
Expected: FAIL with `cannot load such file -- fits_jruby/request_handler`.

- [ ] **Step 3: Write the implementation**

```ruby
# lib/fits_jruby/request_handler.rb
# frozen_string_literal: true

require "json"

module FitsJruby
  # Pure protocol logic: turns a raw request line into a response string.
  # Knows nothing about sockets or threads.
  class RequestHandler
    STATS_COMMAND = "STATS"

    def initialize(examiner:, metrics:)
      @examiner = examiner
      @metrics = metrics
    end

    def handle(raw_request)
      request = raw_request.to_s.strip
      return @metrics.snapshot.to_json if request == STATS_COMMAND
      return "ERROR: empty request" if request.empty?

      error = validate_path(request)
      return error if error

      examine(request)
    end

    private

    def validate_path(path)
      return "ERROR: path must be absolute: #{path}" unless path.start_with?("/")
      return "ERROR: no such file: #{path}" unless File.exist?(path)
      return "ERROR: not a regular file: #{path}" unless File.file?(path)
      return "ERROR: not readable: #{path}" unless File.readable?(path)

      nil
    end

    def examine(path)
      @examiner.examine(path)
    rescue StandardError => e
      "ERROR: examination failed: #{e.message}"
    end
  end
end
```

- [ ] **Step 4: Add the require to `lib/fits_jruby.rb`**

```ruby
require_relative "fits_jruby/request_handler"
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/request_handler_spec.rb`
Expected: PASS (7 examples, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add lib/fits_jruby/request_handler.rb lib/fits_jruby.rb spec/request_handler_spec.rb
git commit -m "feat: add RequestHandler protocol logic with STATS command"
```

---

## Task 5: FitsExaminer (Java/FITS integration)

**Files:**
- Create: `lib/fits_jruby/fits_examiner.rb`
- Test: `spec/integration/fits_examiner_spec.rb` (tagged `:integration`)
- Modify: `lib/fits_jruby.rb` (add require)

**Interfaces:**
- Consumes: `fits_home` (String, validated by `Config`).
- Produces: `FitsJruby::FitsExaminer.new(fits_home)` — constructs one warm `Fits` instance in the initializer (loading all jars once) — with `#examine(path) -> String` returning native FITS XML beginning with `<?xml`. Raises on FITS errors (the caller/`RequestHandler` handles that).

Notes for the implementer (verified on this system):
- Load every jar under `FITS_HOME/lib/**/*.jar` with `require`.
- `Fits.FITS_HOME = fits_home` must be set before `Fits.new`.
- Java's `File` collides with Ruby's `File`; use `Java::JavaIo::File`.
- Write XML via `FitsOutput#output(ByteArrayOutputStream)` then
  `String.from_java_bytes(baos.toByteArray)`.
- This unit is only exercised by the integration suite (real JVM/FITS cost),
  so there is no fast unit test for it. It is mocked everywhere else.

- [ ] **Step 1: Write the failing integration test**

```ruby
# spec/integration/fits_examiner_spec.rb
# frozen_string_literal: true

require "fits_jruby/fits_examiner"

RSpec.describe FitsJruby::FitsExaminer, :integration do
  fits_home = ENV["FITS_HOME"]

  before(:all) do
    skip "FITS_HOME not set" if fits_home.nil? || fits_home.empty?
  end

  subject(:examiner) { described_class.new(fits_home) }

  it "examines a TIFF and returns FITS XML" do
    xml = examiner.examine(File.expand_path("../fixtures/sample.tif", __dir__))
    expect(xml).to start_with("<?xml")
    expect(xml).to include("image/tiff")
  end

  it "examines a JP2 and returns FITS XML" do
    xml = examiner.examine(File.expand_path("../fixtures/sample.jp2", __dir__))
    expect(xml).to start_with("<?xml")
    expect(xml).to include("jp2")
  end
end
```

- [ ] **Step 2: Run the integration test to verify it fails**

Run: `FITS_HOME=~/tools/fits-1.6.0 bundle exec rspec spec/integration/fits_examiner_spec.rb --tag integration`
Expected: FAIL with `cannot load such file -- fits_jruby/fits_examiner`.

- [ ] **Step 3: Write the implementation**

```ruby
# lib/fits_jruby/fits_examiner.rb
# frozen_string_literal: true

require "java"

module FitsJruby
  # The only unit that touches Java/FITS. Constructs one warm Fits instance
  # and reuses it for every examination.
  class FitsExaminer
    def initialize(fits_home)
      @fits_home = fits_home
      load_fits_jars(fits_home)
      java_import "edu.harvard.hul.ois.fits.Fits"
      Java::EduHarvardHulOisFits::Fits.FITS_HOME = fits_home
      @fits = Java::EduHarvardHulOisFits::Fits.new(fits_home)
    end

    # Returns native FITS XML (a String beginning with "<?xml"). Raises on
    # FITS errors.
    def examine(path)
      input = Java::JavaIo::File.new(path)
      output = @fits.examine(input)
      baos = Java::JavaIo::ByteArrayOutputStream.new
      output.output(baos)
      String.from_java_bytes(baos.toByteArray)
    end

    private

    def load_fits_jars(fits_home)
      Dir.glob(File.join(fits_home, "lib", "**", "*.jar")).sort.each do |jar|
        require jar
      end
    end
  end
end
```

- [ ] **Step 4: Add the require to `lib/fits_jruby.rb`**

```ruby
require_relative "fits_jruby/fits_examiner"
```

- [ ] **Step 5: Run the integration test to verify it passes**

Run: `FITS_HOME=~/tools/fits-1.6.0 bundle exec rspec spec/integration/fits_examiner_spec.rb --tag integration`
Expected: PASS (2 examples, 0 failures). This spawns the real FITS toolbelt once; it may take 10-30 seconds.

- [ ] **Step 6: Confirm the fast suite is unaffected**

Run: `bundle exec rspec`
Expected: the integration spec is skipped (excluded by `--tag ~integration`); all fast specs pass.

- [ ] **Step 7: Commit**

```bash
git add lib/fits_jruby/fits_examiner.rb lib/fits_jruby.rb spec/integration/fits_examiner_spec.rb
git commit -m "feat: add FitsExaminer wrapping a warm FITS instance"
```

---

## Task 6: SocketServer (acceptor + serial worker)

**Files:**
- Create: `lib/fits_jruby/socket_server.rb`
- Test: `spec/socket_server_spec.rb`
- Create: `spec/support/fake_examiner.rb`
- Modify: `lib/fits_jruby.rb` (add require)

**Interfaces:**
- Consumes: `config` (`FitsJruby::Config`), `handler` (responds to `#handle(String) -> String`), `metrics` (`FitsJruby::Metrics`), and an optional `logger` (a Ruby `Logger`; defaults to one writing to `$stdout`).
- Produces: `FitsJruby::SocketServer.new(config:, handler:, metrics:, logger: nil)` with `#start` (binds the socket, launches the acceptor thread + one worker thread, returns immediately), `#stop` (stops threads, closes + unlinks the socket), and `#socket_path`. On each connection the worker reads one newline-terminated line, calls `handler.handle`, writes the response, closes the connection; it records success/error on `metrics` based on whether the response starts with `<?xml` (STATS responses, starting with `{`, count as neither).

- [ ] **Step 1: Create the fake examiner support file**

```ruby
# spec/support/fake_examiner.rb
# frozen_string_literal: true

# A deterministic stand-in for FitsExaminer used in fast tests.
class FakeExaminer
  def initialize(xml: "<?xml version=\"1.0\"?><fits/>", raise_with: nil)
    @xml = xml
    @raise_with = raise_with
  end

  def examine(_path)
    raise StandardError, @raise_with if @raise_with

    @xml
  end
end
```

- [ ] **Step 2: Write the failing test**

```ruby
# spec/socket_server_spec.rb
# frozen_string_literal: true

require "socket"
require "tmpdir"
require "json"
require "tempfile"
require "fits_jruby/config"
require "fits_jruby/metrics"
require "fits_jruby/request_handler"
require "fits_jruby/socket_server"
require_relative "support/fake_examiner"

RSpec.describe FitsJruby::SocketServer do
  around do |example|
    Dir.mktmpdir do |dir|
      @socket_path = File.join(dir, "test.sock")
      example.run
    end
  end

  def build_server(examiner)
    metrics = FitsJruby::Metrics.new(heap_reader: -> { { used: 1, max: 2 } })
    config = FitsJruby::Config.new(
      "FITS_HOME" => "/unused", "FITS_SOCKET_PATH" => @socket_path
    )
    handler = FitsJruby::RequestHandler.new(examiner: examiner, metrics: metrics)
    [FitsJruby::SocketServer.new(config: config, handler: handler, metrics: metrics), metrics]
  end

  def request(path_line)
    UNIXSocket.open(@socket_path) do |sock|
      sock.write("#{path_line}\n")
      sock.read
    end
  end

  def wait_for_socket
    20.times { break if File.socket?(@socket_path); sleep 0.05 }
  end

  it "returns examiner XML for a valid path and increments success" do
    server, metrics = build_server(FakeExaminer.new)
    server.start
    wait_for_socket
    Tempfile.create(["s", ".tif"]) do |file|
      expect(request(file.path)).to eq("<?xml version=\"1.0\"?><fits/>")
    end
    expect(metrics.snapshot[:requests_success]).to eq(1)
  ensure
    server&.stop
  end

  it "returns an error line and increments error for a bad path" do
    server, metrics = build_server(FakeExaminer.new)
    server.start
    wait_for_socket
    expect(request("/does/not/exist.tif")).to match(/\AERROR: /)
    expect(metrics.snapshot[:requests_error]).to eq(1)
  ensure
    server&.stop
  end

  it "answers STATS with JSON and counts it as neither success nor error" do
    server, metrics = build_server(FakeExaminer.new)
    server.start
    wait_for_socket
    body = request("STATS")
    expect(JSON.parse(body)).to include("requests_total")
    snap = metrics.snapshot
    expect(snap[:requests_success]).to eq(0)
    expect(snap[:requests_error]).to eq(0)
  ensure
    server&.stop
  end

  it "survives an examiner that raises and keeps serving" do
    server, = build_server(FakeExaminer.new(raise_with: "boom"))
    server.start
    wait_for_socket
    Tempfile.create(["s", ".tif"]) do |file|
      expect(request(file.path)).to eq("ERROR: examination failed: boom")
      # server still responds afterward
      expect(request("STATS")).to start_with("{")
    end
  ensure
    server&.stop
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bundle exec rspec spec/socket_server_spec.rb`
Expected: FAIL with `cannot load such file -- fits_jruby/socket_server`.

- [ ] **Step 4: Write the implementation**

```ruby
# lib/fits_jruby/socket_server.rb
# frozen_string_literal: true

require "socket"
require "logger"
require "fileutils"

module FitsJruby
  # Owns the UNIXServer lifecycle. An acceptor thread accepts connections and
  # pushes them onto a bounded queue; a single worker thread drains the queue
  # serially, so only one examination runs at a time.
  class SocketServer
    def initialize(config:, handler:, metrics:, logger: nil)
      @config = config
      @handler = handler
      @metrics = metrics
      @logger = logger || default_logger(config.log_level)
      @queue = SizedQueue.new(config.queue_capacity)
      @running = false
    end

    def socket_path
      @config.socket_path
    end

    def start
      remove_stale_socket
      @server = UNIXServer.new(socket_path)
      @running = true
      @worker = Thread.new { worker_loop }
      @acceptor = Thread.new { acceptor_loop }
      @logger.info("ready: listening on #{socket_path} (queue capacity #{@config.queue_capacity})")
    end

    def stop
      @running = false
      @acceptor&.kill
      @worker&.kill
      @server&.close
      remove_stale_socket
      @logger.info("stopped")
    end

    private

    def acceptor_loop
      while @running
        connection = @server.accept
        @metrics.enqueue
        @queue.push(connection)
      rescue IOError, Errno::EBADF
        break
      rescue StandardError => e
        @logger.error("acceptor error: #{e.class}: #{e.message}")
      end
    end

    def worker_loop
      while @running
        connection = @queue.pop
        next unless connection

        @metrics.dequeue
        @metrics.processing = true
        serve(connection)
      ensure
        @metrics.processing = false
      end
    end

    def serve(connection)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raw = connection.gets
      response = @handler.handle(raw.to_s)
      connection.write(response)
      record_outcome(response)
      log_request(raw, response, started)
    rescue StandardError => e
      @logger.error("worker error: #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
    ensure
      connection.close if connection && !connection.closed?
    end

    def record_outcome(response)
      if response.start_with?("<?xml")
        @metrics.record_success
      elsif response.start_with?("ERROR:")
        @metrics.record_error
      end
    end

    def log_request(raw, response, started)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      request = raw.to_s.strip
      if request == RequestHandler::STATS_COMMAND
        @logger.debug("stats request (#{duration_ms}ms)")
      else
        outcome = response.start_with?("<?xml") ? "success" : "error"
        @logger.info("examine path=#{request} outcome=#{outcome} duration_ms=#{duration_ms}")
      end
    end

    def remove_stale_socket
      FileUtils.rm_f(socket_path)
    end

    def default_logger(level)
      logger = Logger.new($stdout)
      logger.level = Logger.const_get(level.to_s.upcase)
      logger
    end
  end
end
```

- [ ] **Step 5: Add the require to `lib/fits_jruby.rb`**

```ruby
require_relative "fits_jruby/socket_server"
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bundle exec rspec spec/socket_server_spec.rb`
Expected: PASS (4 examples, 0 failures).

- [ ] **Step 7: Run the whole fast suite and lint**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: all fast specs pass; rubocop clean (fix any offenses).

- [ ] **Step 8: Commit**

```bash
git add lib/fits_jruby/socket_server.rb lib/fits_jruby.rb spec/socket_server_spec.rb spec/support/fake_examiner.rb
git commit -m "feat: add SocketServer with acceptor thread and serial worker"
```

---

## Task 7: Executable entrypoint and end-to-end integration test

**Files:**
- Create: `bin/fits-server`
- Test: `spec/integration/end_to_end_spec.rb` (tagged `:integration`)

**Interfaces:**
- Consumes: everything above.
- Produces: an executable `bin/fits-server` that loads `Config`, validates it, builds `Metrics`, `FitsExaminer`, `RequestHandler`, and `SocketServer`, installs `SIGINT`/`SIGTERM` handlers, starts the server, and blocks until signalled.

- [ ] **Step 1: Write the executable**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "fits_jruby"

config = FitsJruby::Config.new
begin
  config.validate!
rescue FitsJruby::Config::Error => e
  warn "configuration error: #{e.message}"
  exit 1
end

metrics = FitsJruby::Metrics.new
examiner = FitsJruby::FitsExaminer.new(config.fits_home)
handler = FitsJruby::RequestHandler.new(examiner: examiner, metrics: metrics)
server = FitsJruby::SocketServer.new(config: config, handler: handler, metrics: metrics)

shutdown = lambda do
  server.stop
  exit 0
end
Signal.trap("INT", &shutdown)
Signal.trap("TERM", &shutdown)

server.start
sleep
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x bin/fits-server`
Expected: no output; `ls -l bin/fits-server` shows the `x` bit.

- [ ] **Step 3: Write the failing end-to-end integration test**

```ruby
# spec/integration/end_to_end_spec.rb
# frozen_string_literal: true

require "socket"
require "tmpdir"
require "json"

RSpec.describe "fits-server end to end", :integration do
  fits_home = ENV["FITS_HOME"]

  before(:all) do
    skip "FITS_HOME not set" if fits_home.nil? || fits_home.empty?
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @socket = File.join(dir, "e2e.sock")
      env = { "FITS_HOME" => fits_home, "FITS_SOCKET_PATH" => @socket }
      @pid = spawn(env, "bin/fits-server", { "JRUBY_OPTS" => "-J-Xmx512m" })
      40.times { break if File.socket?(@socket); sleep 0.25 }
      example.run
    ensure
      Process.kill("TERM", @pid) if @pid
      Process.wait(@pid) if @pid
    end
  end

  def request(line)
    UNIXSocket.open(@socket) do |sock|
      sock.write("#{line}\n")
      sock.read
    end
  end

  it "returns real FITS XML for a fixture over the socket" do
    xml = request(File.expand_path("../fixtures/sample.tif", __dir__))
    expect(xml).to start_with("<?xml")
    expect(xml).to include("image/tiff")
  end

  it "answers STATS with a JSON snapshot" do
    snap = JSON.parse(request("STATS"))
    expect(snap).to include("requests_total", "heap_used_bytes", "queue_depth")
  end
end
```

- [ ] **Step 4: Run the end-to-end test to verify it passes**

Run: `FITS_HOME=~/tools/fits-1.6.0 bundle exec rspec spec/integration/end_to_end_spec.rb --tag integration`
Expected: PASS (2 examples). The server boots the real FITS once (allow up to ~30s for startup).

- [ ] **Step 5: Run the full integration suite and the fast suite**

Run: `FITS_HOME=~/tools/fits-1.6.0 bundle exec rspec --tag integration && bundle exec rspec && bundle exec rubocop`
Expected: integration specs pass; fast specs pass; rubocop clean.

- [ ] **Step 6: Commit**

```bash
git add bin/fits-server spec/integration/end_to_end_spec.rb
git commit -m "feat: add fits-server entrypoint with end-to-end integration test"
```

---

## Task 8: Documentation (README, INSTALL, DEPLOYMENT)

**Files:**
- Create: `README.md`
- Create: `INSTALL.md`
- Create: `DEPLOYMENT.md`

**Interfaces:**
- Consumes: the finished server behavior and env vars.
- Produces: three docs matching the spec's Documentation section. No code interfaces.

- [ ] **Step 1: Write `README.md`**

Include, in prose a junior dev can follow:
- One-paragraph description (warm FITS instance over a Unix socket; native FITS XML out).
- Quick start: `bundle install`, set `FITS_HOME`, run `bin/fits-server`.
- Env var reference table: `FITS_HOME`, `FITS_SOCKET_PATH` (default `/tmp/fits.sock`), `FITS_QUEUE_CAPACITY` (default 64), `FITS_LOG_LEVEL` (default info).
- Protocol: newline-terminated **absolute** path; response is FITS XML on success (starts with `<?xml`), plain `ERROR: ...` text on failure. Include these concrete examples:

  ````markdown
  ```bash
  # examine a file
  printf '/abs/path/to/file.tif\n' | nc -U /tmp/fits.sock

  # with socat
  printf '/abs/path/to/file.tif\n' | socat - UNIX-CONNECT:/tmp/fits.sock

  # query metrics
  printf 'STATS\n' | nc -U /tmp/fits.sock
  ```

  ```ruby
  # Ruby client (Sidekiq-style)
  require "socket"
  xml = UNIXSocket.open("/tmp/fits.sock") do |sock|
    sock.write("/abs/path/to/file.tif\n")
    sock.read
  end
  raise "FITS error: #{xml}" unless xml.start_with?("<?xml")
  ```
  ````
- `STATS` example JSON response (uptime_seconds, requests_total/success/error, queue_depth, processing, heap_used_bytes, heap_max_bytes).
- Concurrency note: concurrent callers **queue rather than fail** (app-level queue + kernel backlog); latency grows with `queue_depth`; watch it via `STATS`.

- [ ] **Step 2: Write `INSTALL.md`**

Step-by-step for a junior dev: install rbenv + jruby-9.4.15.0 and OpenJDK 17; download and unzip the FITS 1.6.0 release; `bundle install`; `export FITS_HOME=...`; run `bin/fits-server`; verify with a `printf ... | nc -U` request; run tests (`bundle exec rspec`, and integration via `FITS_HOME=... bundle exec rspec --tag integration`).

- [ ] **Step 3: Write `DEPLOYMENT.md`**

Production guide targeting Ubuntu 22.04 + systemd, per the spec:
- Create an unprivileged `fits` user/group.
- Socket at `/run/fits/fits.sock` via `RuntimeDirectory=fits`, `RuntimeDirectoryMode=0750`, `UMask=0117` (socket ends up `0660` owned `fits:fits`); grant the calling app access via the `fits` group.
- JVM `JAVA_OPTS`: `-Xms256m -Xmx1g -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+ExitOnOutOfMemoryError`.
- A complete hardened `fits.service` unit with `User`/`Group`/`RuntimeDirectory`/`Environment` (FITS_HOME, FITS_SOCKET_PATH=/run/fits/fits.sock, FITS_QUEUE_CAPACITY, FITS_LOG_LEVEL), `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`, `ReadOnlyPaths=<FITS_HOME>`, `RestrictAddressFamilies=AF_UNIX`, `MemoryMax=1500M`, `Restart=on-failure`, `StandardOutput=journal`.
- Filesystem scoping: the `fits` user must be able to read the media it examines; grant via `ReadOnlyPaths=`/group membership.
- Monitoring: poll `STATS` (e.g. `printf 'STATS\n' | socat - UNIX-CONNECT:/run/fits/fits.sock`); alert on rising `queue_depth`, growing `heap_used_bytes` near `heap_max_bytes`, and error rate.

- [ ] **Step 4: Commit**

```bash
git add README.md INSTALL.md DEPLOYMENT.md
git commit -m "docs: add README, INSTALL, and DEPLOYMENT guides"
```

---

## Task 9: Final verification pass

**Files:** none (verification only).

- [ ] **Step 1: Run the full test + quality gate**

Run:
```bash
bundle exec rubocop
bundle exec bundle-audit check --update
bundle exec rspec
FITS_HOME=~/tools/fits-1.6.0 bundle exec rspec --tag integration
```
Expected: rubocop clean; bundler-audit reports no vulnerabilities; fast specs pass; integration specs pass.

- [ ] **Step 2: Manual smoke test**

Run (in one shell): `FITS_HOME=~/tools/fits-1.6.0 JRUBY_OPTS="-J-Xmx512m" bin/fits-server`
Then (in another): `printf "$PWD/spec/fixtures/sample.mp4\n" | nc -U /tmp/fits.sock`
Expected: FITS XML beginning with `<?xml` and containing an MP4/QuickTime identification; then `printf 'STATS\n' | nc -U /tmp/fits.sock` returns a JSON snapshot. Ctrl-C the server; it logs "stopped" and removes the socket.

- [ ] **Step 3: Commit any final fixes**

```bash
git add -A
git commit -m "chore: final verification fixes"
```

---

## Self-Review Notes

- **Spec coverage:** Config (T2), Metrics + STATS (T3, T6), RequestHandler protocol/validation/errors (T4), FitsExaminer warm instance (T5), SocketServer acceptor+serial worker+queue+logging (T6), entrypoint+signals (T7), layered testing with tiny fixtures + constrained heap (T5/T7), RuboCop + bundler-audit (T1/T9), docs incl. Ubuntu/systemd/`/run` and JVM/GC (T8). Fixtures already committed.
- **Types consistent:** `Metrics#snapshot` keys are used verbatim by `RequestHandler` (JSON) and asserted in T6/T7; `RequestHandler#handle` and `SocketServer` method names match across tasks; `RequestHandler::STATS_COMMAND` is referenced by `SocketServer` logging.
- **No placeholders:** every code step contains complete code; commands have expected output.
