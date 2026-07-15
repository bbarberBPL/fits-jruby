# frozen_string_literal: true

require 'fits_jruby/fits_examiner'

RSpec.describe FitsJruby::FitsExaminer, :integration do
  fits_home = ENV.fetch('FITS_HOME', nil)

  before(:all) do
    skip 'FITS_HOME not set' if fits_home.nil? || fits_home.empty?
  end

  subject(:examiner) { described_class.new(fits_home) }

  it 'examines a TIFF and returns FITS XML' do
    xml = examiner.examine(File.expand_path('../fixtures/sample.tif', __dir__))
    expect(xml).to start_with('<?xml')
    expect(xml).to include('image/tiff')
  end

  it 'examines a JP2 and returns FITS XML' do
    xml = examiner.examine(File.expand_path('../fixtures/sample.jp2', __dir__))
    expect(xml).to start_with('<?xml')
    expect(xml).to include('jp2')
  end
end
