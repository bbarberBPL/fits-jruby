# frozen_string_literal: true

require 'java'

module FitsJruby
  # The only unit that touches Java/FITS. Constructs one warm Fits instance
  # and reuses it for every examination.
  class FitsExaminer
    def initialize(fits_home)
      # Inject our project-level log4j2 config BEFORE the FITS jars are loaded
      # so that log4j picks it up during its first initialisation. This:
      #   (a) replaces the FITS-bundled RollingRandomAccessFile appender (which
      #       writes to ./fits.log) with a Console appender targeting SYSTEM_ERR,
      #   (b) routes all FITS log4j output to stderr (unified with our Ruby logger),
      #   (c) prevents a stray fits.log from being created in the working directory.
      # Falls back gracefully if the config file is missing (log4j uses its default).
      configure_log4j!

      load_fits_jars(fits_home)
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

    def configure_log4j!
      config_path = File.expand_path('../../config/log4j2.xml', __dir__)
      return unless File.exist?(config_path)

      java.lang.System.setProperty('log4j2.configurationFile', config_path)
    end

    def load_fits_jars(fits_home)
      Dir.glob(File.join(fits_home, 'lib', '**', '*.jar')).sort.each do |jar| # rubocop:disable Lint/RedundantDirGlobSort
        require jar
      end
    end
  end
end
