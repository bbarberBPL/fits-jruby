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

  it 'defaults the socket path, queue capacity, and log level' do
    config = described_class.new(env)
    expect(config.socket_path).to eq('/tmp/fits.sock')
    expect(config.queue_capacity).to eq(64)
    expect(config.log_level).to eq(:info)
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
end
