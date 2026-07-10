# frozen_string_literal: true

require 'fits_jruby/metrics'

RSpec.describe FitsJruby::Metrics do
  subject(:metrics) do
    described_class.new(
      clock: -> { @now },
      heap_reader: -> { { used: 1000, max: 4000 } }
    )
  end

  before do
    @now = 100.0
    metrics # Eagerly evaluate subject to fix lazy evaluation timing
  end

  it 'starts with zeroed counters' do
    snap = metrics.snapshot
    expect(snap[:requests_total]).to eq(0)
    expect(snap[:requests_success]).to eq(0)
    expect(snap[:requests_error]).to eq(0)
    expect(snap[:queue_depth]).to eq(0)
    expect(snap[:processing]).to be(false)
  end

  it 'counts successes and errors toward the total' do
    metrics.record_success
    metrics.record_success
    metrics.record_error
    snap = metrics.snapshot
    expect(snap[:requests_success]).to eq(2)
    expect(snap[:requests_error]).to eq(1)
    expect(snap[:requests_total]).to eq(3)
  end

  it 'tracks queue depth via enqueue/dequeue' do
    metrics.enqueue
    metrics.enqueue
    metrics.dequeue
    expect(metrics.snapshot[:queue_depth]).to eq(1)
  end

  it 'tracks the processing flag' do
    metrics.processing = true
    expect(metrics.snapshot[:processing]).to be(true)
    metrics.processing = false
    expect(metrics.snapshot[:processing]).to be(false)
  end

  it 'computes uptime from the injected clock' do
    @now = 130.5
    expect(metrics.snapshot[:uptime_seconds]).to eq(30)
  end

  it 'reports heap figures from the injected reader' do
    snap = metrics.snapshot
    expect(snap[:heap_used_bytes]).to eq(1000)
    expect(snap[:heap_max_bytes]).to eq(4000)
  end
end
