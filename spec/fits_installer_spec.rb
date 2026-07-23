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
