defmodule VisionCore.Camera.OutputTest do
  use ExUnit.Case, async: true

  alias VisionCore.Camera.Output

  @processors %{cpu: [{2028, 1520}, {1014, 760}]}

  describe "resolve/2" do
    test "gives each output its size, its maker and its index on the Port, in config order" do
      assert {:ok, [view, inference]} =
               Output.resolve(
                 [
                   view: [resolution: {2028, 1520}, processor: :cpu],
                   inference: [resolution: {1014, 760}, from: :view]
                 ],
                 @processors
               )

      assert view == %Output{
               name: :view,
               index: 0,
               width: 2028,
               height: 1520,
               processor: :cpu,
               from: nil
             }

      assert inference == %Output{
               name: :inference,
               index: 1,
               width: 1014,
               height: 760,
               processor: nil,
               from: :view
             }
    end

    test "numbers an output after the one it is scaled from, whatever the config order" do
      assert {:ok, outputs} =
               Output.resolve(
                 [
                   small: [resolution: {507, 380}, from: :inference],
                   inference: [resolution: {1014, 760}, from: :view],
                   view: [resolution: {2028, 1520}, processor: :cpu]
                 ],
                 @processors
               )

      assert Enum.map(outputs, &{&1.name, &1.index}) == [small: 2, inference: 1, view: 0]
    end

    test "takes outputs made by a processor at either of its sizes" do
      assert {:ok, [%Output{index: 0}, %Output{index: 1}]} =
               Output.resolve(
                 [
                   half: [resolution: {1014, 760}, processor: :cpu],
                   full: [resolution: {2028, 1520}, processor: :cpu]
                 ],
                 @processors
               )
    end

    test "refuses what the camera cannot make" do
      for {outputs, message} <- [
            {[], "a camera has at least one output"},
            {:view, "outputs are a keyword list of named outputs, got :view"},
            {[view: [resolution: {2028, 1520}, processor: :isp]],
             "output view: its processor :isp is not one this driver has (:cpu)"},
            {[view: [resolution: {1000, 750}, processor: :cpu]],
             "output view: its processor :cpu cannot make 1000x750; it makes 2028x1520 or 1014x760"},
            {[view: [resolution: {2028, 1520}]],
             "output view: it needs a :processor or a :from, not both"},
            {[view: [resolution: {2028, 1520}, processor: :cpu, from: :other]],
             "output view: it needs a :processor or a :from, not both"},
            {[
               view: [resolution: {2028, 1520}, processor: :cpu],
               inference: [resolution: {1014, 760}, from: nil]
             ], "output inference: its :from is an output's name, got nil"},
            {[
               view: [resolution: {2028, 1520}, processor: :cpu],
               inference: [resolution: {1014, 760}, from: "view"]
             ], "output inference: its :from is an output's name, got \"view\""},
            {[view: [resolution: {2028, 1520}, processor: "cpu"]],
             "output view: its :processor is a processor's name, got \"cpu\""},
            {[view: [processor: :cpu]],
             "output view: its :resolution is {width, height} in pixels, got nil"},
            {[view: [resolution: {2028, 1520}, processor: :cpu, zoom: 2]],
             "output view: no option :zoom"},
            {[
               view: [resolution: {2028, 1520}, processor: :cpu],
               view: [resolution: {1014, 760}, from: :view]
             ], "outputs are named once each: view twice"},
            {[
               view: [resolution: {2028, 1520}, processor: :cpu],
               inference: [resolution: {1014, 760}, from: :viewer]
             ], "output inference: its :from, :viewer, is no output of the camera"},
            {[view: [resolution: {2028, 1520}, from: :view]],
             "outputs view are made of none: their :from runs in a cycle"},
            {[
               view: [resolution: {2028, 1520}, processor: :cpu],
               a: [resolution: {1014, 760}, from: :b],
               b: [resolution: {1014, 760}, from: :a]
             ], "outputs a, b are made of none: their :from runs in a cycle"},
            {[
               view: [resolution: {2028, 1520}, processor: :cpu],
               inference: [resolution: {1000, 760}, from: :view]
             ], "output inference: 1000x760 is no whole fraction of view's 2028x1520"},
            {[
               view: [resolution: {2028, 1520}, processor: :cpu],
               inference: [resolution: {4056, 3040}, from: :view]
             ], "output inference: 4056x3040 is no whole fraction of view's 2028x1520"}
          ] do
        assert Output.resolve(outputs, @processors) == {:error, message}, inspect(outputs)
      end
    end
  end

  test "port_order/1 lists the outputs by their index" do
    {:ok, outputs} =
      Output.resolve(
        [
          inference: [resolution: {1014, 760}, from: :view],
          view: [resolution: {2028, 1520}, processor: :cpu]
        ],
        @processors
      )

    assert Enum.map(Output.port_order(outputs), & &1.name) == [:view, :inference]
  end
end
