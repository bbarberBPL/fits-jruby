# frozen_string_literal: true

require 'java'

module FitsJruby
  # The only unit that touches Java/FITS. Constructs one warm Fits instance
  # and reuses it for every examination.
  class FitsExaminer
    def initialize(fits_home)
      @fits_home = fits_home
      load_fits_jars(fits_home)
      java_import 'edu.harvard.hul.ois.fits.Fits'
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
      Dir.glob(File.join(fits_home, 'lib', '**', '*.jar')).each do |jar|
        require jar
      end
    end
  end
end
