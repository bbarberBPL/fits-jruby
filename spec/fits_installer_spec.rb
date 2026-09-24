# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'digest'
require 'logger'
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

  describe '.fetch_to_file scheme enforcement (L11)' do
    it 'refuses a non-https initial URL before any network call' do
      expect(Net::HTTP).not_to receive(:start)
      expect { described_class.fetch_to_file('http://example.com/fits.zip', '/tmp/ignored') }
        .to raise_error(described_class::Error, /insecure URL.*expected https/)
    end

    it 'proceeds past the guard for an https URL' do
      # Sentinel: reaching Net::HTTP.start means the guard passed.
      allow(Net::HTTP).to receive(:start).and_raise(StopIteration)
      expect { described_class.fetch_to_file('https://example.com/fits.zip', '/tmp/ignored') }
        .to raise_error(StopIteration)
    end
  end

  describe '.handle_response' do
    it 'refuses a redirect to a non-https location' do
      response = Net::HTTPRedirection.allocate
      def response.[](key)
        key == 'location' ? 'http://evil.example/fits.zip' : nil
      end

      expect do
        described_class.handle_response(response, 'https://orig.example/fits.zip', '/tmp/x.zip', 3)
      end.to raise_error(FitsJruby::FitsInstaller::Error, /insecure redirect/)
    end
  end

  describe 'project tika-config.xml overlay (disables TesseractOCRParser)' do
    def tika_config_at(home)
      File.read(File.join(home, 'xml', 'tika', 'tika-config.xml'))
    end

    it 'installs the project tika-config.xml on a fresh install' do
      Dir.mktmpdir do |work|
        zip, sha = build_fake_fits_zip(work)
        home = File.join(work, 'dest', 'fits')
        installer = described_class.new(
          fits_home: home, sha256: sha,
          downloader: ->(_url, dest) { FileUtils.cp(zip, dest) }
        )
        installer.install!
        expect(tika_config_at(home)).to include('TesseractOCRParser')
      end
    end

    it 're-applies the project tika-config.xml even when FITS_HOME is already present' do
      # This is what makes re-running `bin/setup` against an existing
      # install (e.g. in production) sufficient to pick up the fix, without
      # requiring a full FITS reinstall.
      Dir.mktmpdir do |home|
        FileUtils.mkdir_p(File.join(home, 'lib'))
        installer = described_class.new(fits_home: home, sha256: 'unused')
        expect(installer.install!).to eq(:present)
        expect(tika_config_at(home)).to include('TesseractOCRParser')
      end
    end

    it 'does not raise when FITS_HOME is read-only (e.g. a Docker image at container runtime)' do
      # docker-entrypoint runs `bin/setup` on every container start, by which
      # point `read_only: true` typically makes the image's rootfs read-only.
      # The config was already baked in during the image build (when the
      # filesystem was still writable), so a failed overwrite here must be a
      # benign no-op, not a crash.
      Dir.mktmpdir do |home|
        FileUtils.mkdir_p(File.join(home, 'lib'))
        tika_dir = File.join(home, 'xml', 'tika')
        FileUtils.mkdir_p(tika_dir)
        File.chmod(0o500, tika_dir) # read+traverse, no write - simulates a read-only mount
        logger = instance_double(Logger, info: nil, warn: nil)
        installer = described_class.new(fits_home: home, sha256: 'unused', logger: logger)

        begin
          expect { installer.install! }.not_to raise_error
          expect(logger).to have_received(:warn).with(/tika-config\.xml/)
        ensure
          File.chmod(0o700, tika_dir)
        end
      end
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
