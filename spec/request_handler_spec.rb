# frozen_string_literal: true

require 'json'
require 'tmpdir'
require 'fileutils'
require 'tempfile'
require 'fits_jruby/request_handler'

RSpec.describe FitsJruby::RequestHandler do
  let(:examiner) { instance_double('FitsJruby::FitsExaminer') }
  let(:metrics)  { instance_double('FitsJruby::Metrics') }
  subject(:handler) { described_class.new(examiner: examiner, metrics: metrics) }

  it 'returns metrics JSON for STATS' do
    allow(metrics).to receive(:snapshot).and_return(requests_total: 5, queue_depth: 1)
    result = handler.handle("STATS\n")
    expect(result).to start_with('{')
    expect(JSON.parse(result)).to include('requests_total' => 5, 'queue_depth' => 1)
  end

  it 'returns an error for an empty request' do
    expect(handler.handle("   \n")).to eq('ERROR: empty request')
  end

  it 'rejects a relative path' do
    expect(handler.handle("relative/file.tif\n"))
      .to eq('ERROR: path must be absolute: relative/file.tif')
  end

  it 'rejects a missing file' do
    expect(handler.handle("/does/not/exist.tif\n"))
      .to match(%r{\AERROR: .*: /does/not/exist\.tif\z})
  end

  it 'rejects a directory (not a regular file)' do
    Dir.mktmpdir do |dir|
      expect(handler.handle("#{dir}\n")).to match(/\AERROR: /)
    end
  end

  it 'rejects a FIFO (not a regular file)' do
    Dir.mktmpdir do |dir|
      fifo = File.join(dir, 'pipe')
      if File.respond_to?(:mkfifo)
        File.mkfifo(fifo)
      else
        system('mkfifo', fifo)
      end

      expect(examiner).not_to receive(:examine)
      expect(handler.handle("#{fifo}\n")).to match(/\AERROR: not a regular file: /)
    end
  end

  it 'delegates a valid path to the examiner and returns its XML' do
    Tempfile.create(['sample', '.tif']) do |file|
      allow(examiner).to receive(:examine).with(file.path).and_return('<?xml version="1.0"?><fits/>')
      expect(handler.handle("#{file.path}\n")).to eq('<?xml version="1.0"?><fits/>')
    end
  end

  it 'converts an examiner exception into an error line' do
    Tempfile.create(['sample', '.tif']) do |file|
      allow(examiner).to receive(:examine).and_raise(StandardError, 'boom')
      expect(handler.handle("#{file.path}\n")).to eq('ERROR: examination failed: boom')
    end
  end

  it 'accepts a path anywhere when no allowlist is configured (default off)' do
    Tempfile.create(['sample', '.tif']) do |file|
      allow(examiner).to receive(:examine).with(file.path).and_return('<fits/>')
      expect(handler.handle("#{file.path}\n")).to eq('<fits/>')
    end
  end

  it 'examines the raw path unchanged when no allowlist is configured (no realpath resolution)' do
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'real.tif')
      File.write(target, 'data')
      link = File.join(dir, 'link.tif')
      File.symlink(target, link)
      # No allowlist → handler must pass the path as sent, NOT the resolved target.
      allow(examiner).to receive(:examine).with(link).and_return('<fits/>')
      expect(handler.handle("#{link}\n")).to eq('<fits/>')
      expect(examiner).to have_received(:examine).with(link)
    end
  end

  describe 'NUL-byte paths (NEW-1)' do
    let(:metrics) { instance_double(FitsJruby::Metrics) }
    let(:examiner) { double('examiner') }

    it 'fails closed with a structured error when an allowlist is configured' do
      Dir.mktmpdir do |root|
        handler = described_class.new(examiner: examiner, metrics: metrics, allowed_roots: [root])
        expect { @result = handler.handle("#{root}/x\x00/etc/passwd") }.not_to raise_error
        expect(@result).to start_with('ERROR: path not allowed:')
      end
    end

    it 'never raises for a NUL path even with no allowlist' do
      handler = described_class.new(examiner: examiner, metrics: metrics)
      expect { handler.handle("/tmp/x\x00y") }.not_to raise_error
    end
  end

  # ── Path confinement (FITS_ALLOWED_ROOTS) ────────────────────────────────

  context 'with an allowlist configured' do
    around do |example|
      Dir.mktmpdir do |allowed|
        Dir.mktmpdir do |outside|
          @allowed = allowed
          @outside = outside
          example.run
        end
      end
    end

    subject(:handler) do
      described_class.new(examiner: examiner, metrics: metrics, allowed_roots: [@allowed])
    end

    it 'accepts a file inside an allowed root and delegates to the examiner' do
      path = File.join(@allowed, 'sample.tif')
      File.write(path, 'data')
      allow(examiner).to receive(:examine).with(path).and_return('<fits/>')
      expect(handler.handle("#{path}\n")).to eq('<fits/>')
    end

    it 'rejects a file outside all allowed roots' do
      path = File.join(@outside, 'sample.tif')
      File.write(path, 'data')
      expect(examiner).not_to receive(:examine)
      expect(handler.handle("#{path}\n")).to eq("ERROR: path not allowed: #{path}")
    end

    it 'rejects a symlink inside an allowed root that points outside all roots' do
      target = File.join(@outside, 'secret.tif')
      File.write(target, 'secret')
      link = File.join(@allowed, 'link.tif')
      File.symlink(target, link)
      expect(examiner).not_to receive(:examine)
      expect(handler.handle("#{link}\n")).to eq("ERROR: path not allowed: #{link}")
    end

    it 'rejects a sibling directory that shares a name prefix with an allowed root' do
      sibling = "#{@allowed}-evil"
      FileUtils.mkdir_p(sibling)
      path = File.join(sibling, 'sample.tif')
      File.write(path, 'data')
      expect(examiner).not_to receive(:examine)
      expect(handler.handle("#{path}\n")).to eq("ERROR: path not allowed: #{path}")
    ensure
      FileUtils.rm_rf(sibling) if sibling
    end

    it 'still reports a missing file cleanly rather than crashing on realpath' do
      path = File.join(@allowed, 'nope.tif')
      expect(examiner).not_to receive(:examine)
      expect(handler.handle("#{path}\n")).to match(/\AERROR: no such file: #{Regexp.escape(path)}\z/)
    end

    it 'examines the resolved realpath (not the symlink) for a link inside an allowed root' do
      target = File.join(@allowed, 'real.tif')
      File.write(target, 'data')
      link = File.join(@allowed, 'link.tif')
      File.symlink(target, link)
      real = File.realpath(link)
      allow(examiner).to receive(:examine).with(real).and_return('<fits/>')
      expect(handler.handle("#{link}\n")).to eq('<fits/>')
      expect(examiner).to have_received(:examine).with(real)
    end
  end
end
