defmodule VisionCore.Stereo.Stage.SgbmTest do
  use ExUnit.Case, async: true

  alias Evision.StereoSGBM
  alias VisionCore.Stereo.Stage.Sgbm

  describe "create_matcher/1" do
    test "carries the smoothness penalties, 8 and 32 × block size² by default" do
      matcher = Sgbm.create_matcher(block_size: 9)
      assert StereoSGBM.getP1(matcher) == 648
      assert StereoSGBM.getP2(matcher) == 2592
    end

    test "takes explicit penalties" do
      matcher = Sgbm.create_matcher(block_size: 5, p1: 100, p2: 400)
      assert StereoSGBM.getP1(matcher) == 100
      assert StereoSGBM.getP2(matcher) == 400
    end
  end

  describe "set_option/3" do
    setup do
      {:ok, state} = Sgbm.init([], %{})
      %{state: state}
    end

    test "changes a live matching setting", %{state: state} do
      assert {:ok, state} = Sgbm.set_option(state, :uniqueness_ratio, 20)
      assert Sgbm.options(state).uniqueness_ratio == 20

      assert {:ok, state} = Sgbm.set_option(state, :num_disparities, 128)
      assert Sgbm.options(state).num_disparities == 128
    end

    test "refuses bad values and settings fixed at start", %{state: state} do
      assert {:error, "num_disparities must be a multiple of 16" <> _} =
               Sgbm.set_option(state, :num_disparities, 100)

      assert {:error, "uniqueness_ratio must be an integer" <> _} =
               Sgbm.set_option(state, :uniqueness_ratio, 20.5)

      assert {:error, "unknown or invalid stereo setting" <> _} =
               Sgbm.set_option(state, :block_size, 7)
    end
  end

  describe "option_specs/0" do
    test "describes every setting set_option/3 accepts" do
      for {key, spec} <- Sgbm.option_specs() do
        assert is_binary(spec.description), "#{key} has no description"
        assert spec.type == :integer
      end

      assert {:num_disparities, %{type: :integer, range: {16, 256}}} =
               List.keyfind(Sgbm.option_specs(), :num_disparities, 0)
    end
  end
end
