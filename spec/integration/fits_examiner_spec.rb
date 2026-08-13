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

  it 'does not put FITS tool-specific nested jars onto the main classpath' do
    # fits.xml confines each external tool's dependencies to its own
    # lib/<tool> directory (via classpath-dirs) precisely so bundled jars -
    # e.g. lib/droid/log4j-api-2.17.1.jar - never collide with the top-level
    # lib/log4j-api-2.19.0.jar that log4j-core is built against. Loading every
    # nested jar onto the main classpath (a recursive lib/**/*.jar glob)
    # re-introduces that collision: whichever version's classes get loaded
    # first for a given class name wins for the rest of the process, and a
    # stale API class missing a method log4j-core expects surfaces as
    # NoSuchMethodError the moment any tool error gets logged with a stack
    # trace - which also swallows the real underlying cause.
    examiner
    expect($CLASSPATH.to_a).not_to include(a_string_matching(%r{lib/droid/}))
  end
end
