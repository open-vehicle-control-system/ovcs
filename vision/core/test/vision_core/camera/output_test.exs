defmodule VisionCore.Camera.OutputTest do
  use ExUnit.Case, async: true

  alias VisionCore.Camera.Output

  @processors %{cpu: [{2028, 1520}, {1014, 760}]}
  @view [resolution: {2028, 1520}, processor: :cpu]

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
               from: nil,
               format: :rgb,
               quality: nil
             }

      assert inference == %Output{
               name: :inference,
               index: 1,
               width: 1014,
               height: 760,
               processor: nil,
               from: :view,
               format: :rgb,
               quality: nil
             }
    end

    test "sends an output made from another as a JPEG, at its source's size unless given one" do
      assert {:ok, [_view, view_jpeg, small_jpeg]} =
               Output.resolve(
                 [
                   view: @view,
                   view_jpeg: [from: :view, format: :jpeg, quality: 85],
                   small_jpeg: [resolution: {507, 380}, from: :view, format: :jpeg]
                 ],
                 @processors,
                 formats: [:rgb, :jpeg]
               )

      assert %Output{width: 2028, height: 1520, from: :view, format: :jpeg, quality: 85} =
               view_jpeg

      assert %Output{width: 507, height: 380, format: :jpeg, quality: 80} = small_jpeg
    end

    test "gives an output made from another its source's size, through a chain in any order" do
      assert {:ok, outputs} =
               Output.resolve(
                 [
                   copy_jpeg: [from: :copy, format: :jpeg],
                   copy: [from: :inference],
                   inference: [resolution: {1014, 760}, from: :view],
                   view: @view
                 ],
                 @processors,
                 formats: [:rgb, :jpeg]
               )

      assert Enum.map(outputs, &{&1.name, &1.width, &1.height}) == [
               {:copy_jpeg, 1014, 760},
               {:copy, 1014, 760},
               {:inference, 1014, 760},
               {:view, 2028, 1520}
             ]
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

    test "makes an output with send: false only for the outputs made from it" do
      assert {:ok, [view, view_jpeg, half, quarter]} =
               Output.resolve(
                 [
                   view: Keyword.put(@view, :send, false),
                   view_jpeg: [from: :view, format: :jpeg],
                   half: [resolution: {1014, 760}, from: :view, send: false],
                   quarter: [resolution: {507, 380}, from: :half, send: true]
                 ],
                 @processors,
                 formats: [:rgb, :jpeg]
               )

      assert Enum.map([view, view_jpeg, half, quarter], &{&1.name, &1.index, &1.send}) == [
               {:view, 0, false},
               {:view_jpeg, 1, true},
               {:half, 2, false},
               {:quarter, 3, true}
             ]

      assert Output.sent([view, view_jpeg, half, quarter]) == [view_jpeg, quarter]
    end

    test "refuses an output it does not send unless another is made from it" do
      for {outputs, message} <- [
            {[view: Keyword.put(@view, :send, false)],
             "output view: it is not sent (send: false), and no output is made from it"},
            {[view: @view, half: [resolution: {1014, 760}, from: :view, send: false]],
             "output half: it is not sent (send: false), and no output is made from it"},
            {[view: @view, view_jpeg: [from: :view, format: :jpeg, send: false]],
             "output view_jpeg: it is not sent (send: false), and no output is made from it"},
            {[view: Keyword.put(@view, :send, "no")],
             "output view: its :send is true or false, got \"no\""}
          ] do
        assert Output.resolve(outputs, @processors, formats: [:rgb, :jpeg]) == {:error, message},
               inspect(outputs)
      end
    end

    test "refuses a JPEG the camera cannot make" do
      for {outputs, formats, message} <- [
            {[view: @view, view_jpeg: [from: :view, format: :jpeg]], [:rgb],
             "output view_jpeg: its format :jpeg is not one this driver makes (:rgb)"},
            {[view: @view, view_jpeg: [from: :view, format: :png]], [:rgb, :jpeg],
             "output view_jpeg: its :format is :rgb, :jpeg or :h264, got :png"},
            {[view: Keyword.put(@view, :format, :jpeg)], [:rgb, :jpeg],
             "output view: a JPEG is made :from another output, not by a :processor"},
            {[view: @view, small: [resolution: {1014, 760}, from: :view, quality: 80]],
             [:rgb, :jpeg], "output small: its :quality is a JPEG's: give it format: :jpeg"},
            {[view: @view, view_jpeg: [from: :view, format: :jpeg, quality: 0]], [:rgb, :jpeg],
             "output view_jpeg: its :quality is an integer from 1 to 100, got 0"},
            {[view: @view, view_jpeg: [from: :view, format: :jpeg, quality: 80.0]], [:rgb, :jpeg],
             "output view_jpeg: its :quality is an integer from 1 to 100, got 80.0"},
            {[view: @view, view_jpeg: [from: :view, format: :jpeg, quality: 101]], [:rgb, :jpeg],
             "output view_jpeg: its :quality is an integer from 1 to 100, got 101"},
            {[
               view: @view,
               view_jpeg: [from: :view, format: :jpeg],
               small: [resolution: {1014, 760}, from: :view_jpeg]
             ], [:rgb, :jpeg],
             "output small: its :from, :view_jpeg, is a JPEG, which no output is made from"},
            {[view: @view, view_jpeg: [resolution: {1000, 760}, from: :view, format: :jpeg]],
             [:rgb, :jpeg], "output view_jpeg: 1000x760 is no whole fraction of view's 2028x1520"}
          ] do
        assert Output.resolve(outputs, @processors, formats: formats) == {:error, message},
               inspect(outputs)
      end
    end
  end

  describe "an H.264 output" do
    @h264 [from: :view, format: :h264, bitrate_kbps: 8_000, keyframe_interval: 30]
    @all_formats [formats: [:rgb, :jpeg, :h264]]

    test "is made from another output at its bitrate and key frame interval" do
      assert {:ok, [_view, view_h264, small_h264]} =
               Output.resolve(
                 [
                   view: Keyword.put(@view, :send, false),
                   view_h264: @h264,
                   small_h264:
                     Keyword.merge(@h264,
                       resolution: {1014, 760},
                       bitrate_kbps: 1,
                       keyframe_interval: 1
                     )
                 ],
                 @processors,
                 @all_formats
               )

      assert %Output{
               index: 1,
               width: 2028,
               height: 1520,
               from: :view,
               format: :h264,
               quality: nil,
               bitrate_kbps: 8_000,
               keyframe_interval: 30
             } = view_h264

      assert %Output{width: 1014, height: 760, bitrate_kbps: 1, keyframe_interval: 1} =
               small_h264
    end

    test "is a video, not an image" do
      {:ok, outputs} =
        Output.resolve(
          [view: @view, view_h264: @h264, view_jpeg: [from: :view, format: :jpeg]],
          @processors,
          @all_formats
        )

      assert Enum.map(Output.images(outputs), & &1.name) == [:view, :view_jpeg]
      assert Enum.map(Output.videos(outputs), & &1.name) == [:view_h264]
    end

    test "refuses one the encoder cannot make" do
      for {outputs, formats, message} <- [
            {[view: @view, view_h264: @h264], [:rgb, :jpeg],
             "output view_h264: its format :h264 is not one this driver makes (:rgb, :jpeg)"},
            {[view: Keyword.merge(@view, Keyword.drop(@h264, [:from]))], [:rgb, :h264],
             "output view: an H.264 stream is made :from another output, not by a :processor"},
            {[view: @view, view_h264: Keyword.delete(@h264, :bitrate_kbps)], [:rgb, :h264],
             "output view_h264: its :bitrate_kbps is an integer from 1 to 2000000, got nil"},
            {[view: @view, view_h264: Keyword.put(@h264, :bitrate_kbps, 0)], [:rgb, :h264],
             "output view_h264: its :bitrate_kbps is an integer from 1 to 2000000, got 0"},
            {[view: @view, view_h264: Keyword.put(@h264, :bitrate_kbps, 2_000_001)],
             [:rgb, :h264],
             "output view_h264: its :bitrate_kbps is an integer from 1 to 2000000, got 2000001"},
            {[view: @view, view_h264: Keyword.put(@h264, :bitrate_kbps, 8000.0)], [:rgb, :h264],
             "output view_h264: its :bitrate_kbps is an integer from 1 to 2000000, got 8000.0"},
            {[view: @view, view_h264: Keyword.delete(@h264, :keyframe_interval)], [:rgb, :h264],
             "output view_h264: its :keyframe_interval is a whole number of frames from 1, got nil"},
            {[view: @view, view_h264: Keyword.put(@h264, :keyframe_interval, 0)], [:rgb, :h264],
             "output view_h264: its :keyframe_interval is a whole number of frames from 1, got 0"},
            {[view: @view, view_h264: Keyword.put(@h264, :quality, 80)], [:rgb, :h264],
             "output view_h264: its :quality is a JPEG's: give it format: :jpeg"},
            {[view: @view, small: [resolution: {1014, 760}, from: :view, bitrate_kbps: 100]],
             [:rgb, :h264],
             "output small: its :bitrate_kbps is an H.264's: give it format: :h264"},
            {[view: @view, small: [from: :view, format: :jpeg, keyframe_interval: 30]],
             [:rgb, :jpeg, :h264],
             "output small: its :keyframe_interval is an H.264's: give it format: :h264"},
            {[view: @view, view_h264: @h264, small: [resolution: {1014, 760}, from: :view_h264]],
             [:rgb, :h264],
             "output small: its :from, :view_h264, is an H.264 stream, which no output is made from"},
            {[view: @view, view_h264: Keyword.put(@h264, :send, false)], [:rgb, :h264],
             "output view_h264: it is not sent (send: false), and no output is made from it"},
            {[
               view: [resolution: {1014, 760}, processor: :cpu],
               small: [resolution: {507, 380}, from: :view],
               small_h264: Keyword.put(@h264, :from, :small)
             ], [:rgb, :h264],
             "output small_h264: H.264 takes an even width and height, not 507x380"}
          ] do
        assert Output.resolve(outputs, @processors, formats: formats) == {:error, message},
               inspect(outputs)
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
