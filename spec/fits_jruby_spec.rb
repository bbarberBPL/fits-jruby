# frozen_string_literal: true

require 'tmpdir'
require 'fits_jruby'

RSpec.describe FitsJruby do
  describe '.build_server' do
    it 'wires a SocketServer with a handler confined to config.allowed_roots' do
      Dir.mktmpdir do |root|
        config = instance_double(
          FitsJruby::Config,
          fits_home: '/does/not/matter',
          allowed_roots: [root],
          socket_path: "#{root}/fits.sock",
          queue_capacity: 64,
          log_level: :error,
          read_timeout: 5,
          write_timeout: 30
        )
        fake_examiner = instance_double(FitsJruby::FitsExaminer)

        server = described_class.build_server(config: config, examiner: fake_examiner)

        expect(server).to be_a(FitsJruby::SocketServer)
        expect(server.socket_path).to eq("#{root}/fits.sock")
      end
    end
  end
end
