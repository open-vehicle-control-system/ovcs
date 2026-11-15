defmodule VmsCore.NormalisedRequestTest do
  use ExUnit.Case, async: true
  alias Decimal, as: D
  alias VmsCore.NormalisedRequest

  describe "braking/1" do
    test "a request at or above zero asks for no braking" do
      for requested <- ["0", "0.3", "1", "5"] do
        assert D.equal?(NormalisedRequest.braking(D.new(requested)), 0)
      end
    end

    test "a negative request asks for its magnitude" do
      assert D.equal?(NormalisedRequest.braking(D.new("-0.4")), D.new("0.4"))
      assert D.equal?(NormalisedRequest.braking(D.new("-1")), 1)
    end

    test "a request below -1 asks for full braking, not more" do
      for requested <- ["-5", "-32.768"] do
        assert D.equal?(NormalisedRequest.braking(D.new(requested)), 1)
      end
    end
  end
end
