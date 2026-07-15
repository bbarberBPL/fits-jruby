# frozen_string_literal: true

# A deterministic stand-in for FitsExaminer used in fast tests.
class FakeExaminer
  def initialize(xml: '<?xml version="1.0"?><fits/>', raise_with: nil, raise_java_error: false)
    @xml = xml
    @raise_with = raise_with
    @raise_java_error = raise_java_error
  end

  def examine(_path)
    raise StandardError, @raise_with if @raise_with
    raise java.lang.StackOverflowError.new if @raise_java_error # rubocop:disable Style/RaiseArgs

    @xml
  end
end
