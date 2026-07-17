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
end
