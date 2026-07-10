# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
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
end
