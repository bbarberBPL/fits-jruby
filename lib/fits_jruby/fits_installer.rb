# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tmpdir'
require 'net/http'
require 'uri'
require 'logger'

module FitsJruby
  # Idempotent FITS installer: validate-or-fetch. Pure stdlib so it runs under
  # any Ruby available at build time. The downloader is injectable for testing.
  class FitsInstaller
    class Error < StandardError; end

    FITS_VERSION = '1.6.0'
    # NOTE: EXPECTED_SHA256 is a placeholder in this task; the real value is
    # pinned later (Task 4) per the plan's SHA-256 Pinning Protocol.
    EXPECTED_SHA256 = 'REPLACE_WITH_REAL_SHA256'

    def self.default_url(version)
      "https://github.com/harvard-lts/fits/releases/download/#{version}/fits-#{version}.zip"
    end

    def self.default_downloader
      lambda do |url, dest|
        fetch_to_file(url, dest)
      end
    end

    def self.fetch_to_file(url, dest)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.request(Net::HTTP::Get.new(uri)) do |response|
          case response
          when Net::HTTPRedirection
            return fetch_to_file(response['location'], dest)
          when Net::HTTPSuccess
            File.open(dest, 'wb') { |f| response.read_body { |chunk| f.write(chunk) } }
          else
            raise Error, "download failed: HTTP #{response.code} for #{url}"
          end
        end
      end
    end

    # rubocop:disable Metrics/ParameterLists -- explicit keyword seams for testing/config
    def initialize(fits_home:, version: FITS_VERSION, url: nil, sha256: EXPECTED_SHA256,
                   logger: nil, downloader: nil)
      @fits_home = fits_home
      @version = version
      @url = url || self.class.default_url(version)
      @sha256 = sha256
      @logger = logger || Logger.new($stdout)
      @downloader = downloader || self.class.default_downloader
    end
    # rubocop:enable Metrics/ParameterLists

    # Returns :present (already valid, no-op) or :installed (fetched + extracted).
    def install!
      if valid_install?(@fits_home)
        @logger.info("FITS already present at #{@fits_home}, skipping")
        return :present
      end

      fetch_and_install
      @logger.info("FITS installed at #{@fits_home}")
      :installed
    end

    private

    def fetch_and_install
      Dir.mktmpdir('fits-setup') do |tmp|
        zip = File.join(tmp, "fits-#{@version}.zip")
        @logger.info("downloading FITS #{@version} from #{@url}")
        @downloader.call(@url, zip)
        verify_checksum!(zip)
        root = extract_and_locate_root(zip, tmp)
        install_atomically(root)
      end
    end

    def valid_install?(path)
      Dir.exist?(File.join(path, 'lib'))
    end

    def verify_checksum!(zip)
      actual = Digest::SHA256.file(zip).hexdigest
      return if actual.casecmp?(@sha256)

      raise Error, "FITS zip checksum mismatch: expected #{@sha256}, got #{actual}"
    end

    def extract_and_locate_root(zip, tmp)
      extract_dir = File.join(tmp, 'extract')
      FileUtils.mkdir_p(extract_dir)
      unless system('unzip', '-q', zip, '-d', extract_dir)
        raise Error, 'unzip failed (is the `unzip` command installed?)'
      end

      # The FITS zip contains a top-level dir that holds lib/. Find it.
      candidate = Dir.glob(File.join(extract_dir, '**', 'lib'), File::FNM_DOTMATCH)
                     .map { |lib| File.dirname(lib) }
                     .find { |d| valid_install?(d) }
      raise Error, 'downloaded archive did not contain a valid FITS install (no lib/)' unless candidate

      candidate
    end

    def install_atomically(root)
      FileUtils.mkdir_p(File.dirname(@fits_home))
      FileUtils.mv(root, @fits_home)
    end
  end
end
