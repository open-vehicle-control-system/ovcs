defmodule VisionCore.Segmentation.LiveTest do
  use ExUnit.Case, async: false

  alias VisionCore.Camera.Frame
  alias VisionCore.Outputs
  alias VisionCore.Segmentation.{Live, Pipeline}

  @frame %Frame{label: "hq", width: 1014, height: 760, capture_ns: 123_456_789, rgb: <<>>}
  @labels %{width: 2, height: 1, data: <<0, 10>>, band: {0, 253, 1014, 507}}

  defp publish(name, data) do
    Outputs.publish(
      {:segmentation, name},
      {{:segmentation, name}, {@frame, %{@labels | data: data}, nil}}
    )
  end

  test "hands each subscriber the pipeline's label image, its band, its frame's size and capture time" do
    start_supervised!({Live, name: :road, max_hz: 1_000})
    :ok = Live.subscribe(:road)
    publish(:road, <<0, 10>>)

    assert_receive {:vision_segmentation, segmentation}

    assert segmentation == %{
             frame: {1014, 760},
             capture_ns: 123_456_789,
             band: {0, 253, 1014, 507},
             width: 2,
             height: 1,
             data: <<0, 10>>
           }
  end

  test "takes only its own pipeline's results" do
    start_supervised!({Live, name: :road, max_hz: 1_000})
    :ok = Live.subscribe(:road)
    publish(:lane, <<1, 1>>)

    refute_receive {:vision_segmentation, _segmentation}, 50
  end

  test "sends at most :max_hz results a second, the latest held for the next" do
    start_supervised!({Live, name: :road, max_hz: 5})
    :ok = Live.subscribe(:road)
    publish(:road, <<1, 1>>)
    publish(:road, <<2, 2>>)
    publish(:road, <<3, 3>>)

    assert_receive {:vision_segmentation, %{data: <<1, 1>>}}
    refute_receive {:vision_segmentation, _segmentation}, 100
    assert_receive {:vision_segmentation, %{data: <<3, 3>>}}, 300
  end

  test "refuses a :max_hz that is no integer from 1 on" do
    Process.flag(:trap_exit, true)

    for max_hz <- [0, 2.5, nil] do
      assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
               Live.start_link(name: :road, max_hz: max_hz)

      assert message == "its :max_hz is an integer from 1 on, got #{inspect(max_hz)}"
    end
  end

  test "answers its :max_hz, 5 by default" do
    start_supervised!({Live, name: :road})

    assert Live.max_hz(:road) == 5
  end
end
