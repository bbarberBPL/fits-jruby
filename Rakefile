# frozen_string_literal: true

require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec) do |t|
  t.rspec_opts = '--tag ~integration'
end

RSpec::Core::RakeTask.new(:integration) do |t|
  t.rspec_opts = '--tag integration'
end

desc 'Run RuboCop'
task :lint do
  sh 'bundle exec rubocop'
end

desc 'Audit dependencies for known CVEs'
task :audit do
  sh 'bundle exec bundle-audit check --update'
end

desc 'Regenerate tiny media fixtures (requires ImageMagick, OpenJPEG, ffmpeg)'
task :fixtures do
  dir = 'spec/fixtures'
  sh "magick -size 32x32 gradient:blue-white #{dir}/sample.tif"
  sh 'magick -size 32x32 gradient:red-yellow /tmp/fits_fixture_src.png'
  sh "opj_compress -i /tmp/fits_fixture_src.png -o #{dir}/sample.jp2"
  sh 'ffmpeg -loglevel error -y -f lavfi -i testsrc=duration=1:size=64x64:rate=15 ' \
     "-pix_fmt yuv420p #{dir}/sample.mp4"
  sh 'ffmpeg -loglevel error -y -f lavfi -i testsrc=duration=1:size=64x64:rate=15 ' \
     "-pix_fmt yuv420p #{dir}/sample.mov"
end

task default: %i[spec lint]
