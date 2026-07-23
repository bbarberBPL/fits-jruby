# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'tempfile'
require 'fits_jruby/config'

RSpec.describe FitsJruby::Config do
  def env(overrides = {})
    { 'FITS_HOME' => @fits_home }.merge(overrides)
  end

  around do |example|
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'lib'))
      @fits_home = dir
      example.run
    end
  end

  it 'reads FITS_HOME' do
    expect(described_class.new(env).fits_home).to eq(@fits_home)
  end

  it 'defaults the queue capacity and log level' do
    config = described_class.new(env)
    expect(config.queue_capacity).to eq(64)
    expect(config.log_level).to eq(:info)
  end

  describe 'socket_path default (no FITS_SOCKET_PATH)' do
    it 'uses XDG_RUNTIME_DIR when set' do
      config = described_class.new(env('XDG_RUNTIME_DIR' => '/run/user/1000'))
      expect(config.socket_path).to eq('/run/user/1000/fits.sock')
    end

    it 'falls back to a per-uid dir under tmpdir when XDG_RUNTIME_DIR is unset' do
      config = described_class.new(env('XDG_RUNTIME_DIR' => nil))
      expect(config.socket_path).to eq("#{Dir.tmpdir}/fits-#{Process.uid}/fits.sock")
    end

    it 'falls back when XDG_RUNTIME_DIR is empty' do
      config = described_class.new(env('XDG_RUNTIME_DIR' => ''))
      expect(config.socket_path).to eq("#{Dir.tmpdir}/fits-#{Process.uid}/fits.sock")
    end
  end

  it 'prefers an explicit FITS_SOCKET_PATH over the runtime-dir default' do
    config = described_class.new(env(
                                   'FITS_SOCKET_PATH' => '/run/fits/fits.sock',
                                   'XDG_RUNTIME_DIR' => '/run/user/1000'
                                 ))
    expect(config.socket_path).to eq('/run/fits/fits.sock')
  end

  it 'reads overrides from the environment' do
    config = described_class.new(env(
                                   'FITS_SOCKET_PATH' => '/run/fits/fits.sock',
                                   'FITS_QUEUE_CAPACITY' => '8',
                                   'FITS_LOG_LEVEL' => 'debug'
                                 ))
    expect(config.socket_path).to eq('/run/fits/fits.sock')
    expect(config.queue_capacity).to eq(8)
    expect(config.log_level).to eq(:debug)
  end

  it 'validate! passes when FITS_HOME has a lib/ directory' do
    expect { described_class.new(env).validate! }.not_to raise_error
  end

  it 'validate! raises when FITS_HOME is missing' do
    expect { described_class.new({}).validate! }
      .to raise_error(FitsJruby::Config::Error, /FITS_HOME/)
  end

  it 'validate! raises when FITS_HOME has no lib/ directory' do
    Dir.mktmpdir do |empty|
      expect { described_class.new('FITS_HOME' => empty).validate! }
        .to raise_error(FitsJruby::Config::Error, /lib/)
    end
  end

  it 'validate! raises on an invalid log level' do
    expect { described_class.new(env('FITS_LOG_LEVEL' => 'verbose')).validate! }
      .to raise_error(FitsJruby::Config::Error, /log level/i)
  end

  it 'validate! raises on a non-numeric FITS_QUEUE_CAPACITY' do
    expect { described_class.new(env('FITS_QUEUE_CAPACITY' => 'not_a_number')).validate! }
      .to raise_error(FitsJruby::Config::Error, /invalid queue capacity/i)
  end

  it 'validate! raises on a zero queue capacity' do
    expect { described_class.new(env('FITS_QUEUE_CAPACITY' => '0')).validate! }
      .to raise_error(FitsJruby::Config::Error, /invalid queue capacity/i)
  end

  it 'validate! raises on a negative queue capacity' do
    expect { described_class.new(env('FITS_QUEUE_CAPACITY' => '-5')).validate! }
      .to raise_error(FitsJruby::Config::Error, /invalid queue capacity/i)
  end

  it 'queue_capacity raises Config::Error, not ArgumentError, on non-numeric value' do
    config = described_class.new(env('FITS_QUEUE_CAPACITY' => 'bad_value'))
    expect { config.queue_capacity }
      .to raise_error(FitsJruby::Config::Error, /invalid queue capacity/i)
  end

  # ── FITS_READ_TIMEOUT ─────────────────────────────────────────────────────

  it 'defaults read_timeout to 5' do
    expect(described_class.new(env).read_timeout).to eq(5)
  end

  it 'reads FITS_READ_TIMEOUT override' do
    expect(described_class.new(env('FITS_READ_TIMEOUT' => '10')).read_timeout).to eq(10)
  end

  it 'read_timeout raises Config::Error on non-numeric value' do
    config = described_class.new(env('FITS_READ_TIMEOUT' => 'bad'))
    expect { config.read_timeout }
      .to raise_error(FitsJruby::Config::Error, /invalid read timeout/i)
  end

  it 'validate! raises on zero read timeout' do
    expect { described_class.new(env('FITS_READ_TIMEOUT' => '0')).validate! }
      .to raise_error(FitsJruby::Config::Error, /invalid read timeout/i)
  end

  it 'validate! raises on negative read timeout' do
    expect { described_class.new(env('FITS_READ_TIMEOUT' => '-1')).validate! }
      .to raise_error(FitsJruby::Config::Error, /invalid read timeout/i)
  end

  # ── FITS_WRITE_TIMEOUT ────────────────────────────────────────────────────

  it 'defaults write_timeout to 30' do
    expect(described_class.new(env).write_timeout).to eq(30)
  end

  it 'reads FITS_WRITE_TIMEOUT override' do
    expect(described_class.new(env('FITS_WRITE_TIMEOUT' => '60')).write_timeout).to eq(60)
  end

  it 'write_timeout raises Config::Error on non-numeric value' do
    config = described_class.new(env('FITS_WRITE_TIMEOUT' => 'bad'))
    expect { config.write_timeout }
      .to raise_error(FitsJruby::Config::Error, /invalid write timeout/i)
  end

  it 'validate! raises on zero write timeout' do
    expect { described_class.new(env('FITS_WRITE_TIMEOUT' => '0')).validate! }
      .to raise_error(FitsJruby::Config::Error, /invalid write timeout/i)
  end

  it 'validate! raises on negative write timeout' do
    expect { described_class.new(env('FITS_WRITE_TIMEOUT' => '-2')).validate! }
      .to raise_error(FitsJruby::Config::Error, /invalid write timeout/i)
  end

  # ── M3: base-10 integer env parsing ───────────────────────────────────────

  it 'parses a leading-zero FITS_QUEUE_CAPACITY as base-10, not octal' do
    expect(described_class.new(env('FITS_QUEUE_CAPACITY' => '010')).queue_capacity).to eq(10)
  end

  it 'parses a leading-zero FITS_READ_TIMEOUT as base-10, not octal' do
    expect(described_class.new(env('FITS_READ_TIMEOUT' => '030')).read_timeout).to eq(30)
  end

  it 'does not raise on FITS_WRITE_TIMEOUT=08 (would be an invalid octal digit)' do
    expect(described_class.new(env('FITS_WRITE_TIMEOUT' => '08')).write_timeout).to eq(8)
  end

  it 'rejects a hex FITS_QUEUE_CAPACITY (base-10 only)' do
    expect { described_class.new(env('FITS_QUEUE_CAPACITY' => '0x40')).queue_capacity }
      .to raise_error(FitsJruby::Config::Error, /invalid queue capacity/i)
  end

  it 'still uses the Integer default when the var is unset' do
    expect(described_class.new(env).queue_capacity).to eq(64)
  end

  # ── FITS_ALLOWED_ROOTS ────────────────────────────────────────────────────

  it 'defaults allowed_roots to an empty array when unset' do
    expect(described_class.new(env).allowed_roots).to eq([])
  end

  it 'treats an empty FITS_ALLOWED_ROOTS as no confinement' do
    expect(described_class.new(env('FITS_ALLOWED_ROOTS' => '')).allowed_roots).to eq([])
  end

  it 'parses a single allowed root' do
    Dir.mktmpdir do |root|
      expect(described_class.new(env('FITS_ALLOWED_ROOTS' => root)).allowed_roots)
        .to eq([root])
    end
  end

  it 'parses multiple colon-separated allowed roots' do
    Dir.mktmpdir do |a|
      Dir.mktmpdir do |b|
        expect(described_class.new(env('FITS_ALLOWED_ROOTS' => "#{a}:#{b}")).allowed_roots)
          .to eq([a, b])
      end
    end
  end

  it 'ignores empty segments between separators' do
    Dir.mktmpdir do |root|
      expect(described_class.new(env('FITS_ALLOWED_ROOTS' => "#{root}::")).allowed_roots)
        .to eq([root])
    end
  end

  it 'validate! raises when an allowed root is not absolute' do
    expect { described_class.new(env('FITS_ALLOWED_ROOTS' => 'relative/dir')).validate! }
      .to raise_error(FitsJruby::Config::Error, /allowed root/i)
  end

  it 'validate! raises when an allowed root does not exist' do
    expect { described_class.new(env('FITS_ALLOWED_ROOTS' => '/does/not/exist')).validate! }
      .to raise_error(FitsJruby::Config::Error, /allowed root/i)
  end

  it 'validate! raises when an allowed root is a file, not a directory' do
    Tempfile.create('root') do |file|
      expect { described_class.new(env('FITS_ALLOWED_ROOTS' => file.path)).validate! }
        .to raise_error(FitsJruby::Config::Error, /allowed root/i)
    end
  end

  it 'validate! passes when all allowed roots are absolute directories' do
    Dir.mktmpdir do |root|
      expect { described_class.new(env('FITS_ALLOWED_ROOTS' => root)).validate! }
        .not_to raise_error
    end
  end

  # ── M2: is the socket path the /tmp fallback (needs the strict perm check)? ─

  describe '#default_tmpdir_socket?' do
    it 'is true when neither FITS_SOCKET_PATH nor XDG_RUNTIME_DIR is set' do
      expect(described_class.new(env('XDG_RUNTIME_DIR' => nil)).default_tmpdir_socket?).to be(true)
    end

    it 'is false when XDG_RUNTIME_DIR is set' do
      expect(described_class.new(env('XDG_RUNTIME_DIR' => '/run/user/1000')).default_tmpdir_socket?).to be(false)
    end

    it 'is false when FITS_SOCKET_PATH is set explicitly' do
      expect(described_class.new(env('FITS_SOCKET_PATH' => '/run/fits/fits.sock')).default_tmpdir_socket?).to be(false)
    end
  end
end
