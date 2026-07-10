# frozen_string_literal: true

# A deterministic stand-in for FitsExaminer used in fast tests.
class FakeExaminer
  def initialize(xml: '<?xml version="1.0"?><fits/>', raise_with: nil)
    @xml = xml
    @raise_with = raise_with
  end

  def examine(_path)
    raise StandardError, @raise_with if @raise_with

    @xml
  end
end
