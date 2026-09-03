defmodule RosBridge.Camera.ZenohTest do
  use ExUnit.Case, async: true

  alias RosBridge.Camera.Zenoh

  # A real JPEG, encoded the way the pipeline's frames are, so the
  # scanner is checked against bytes it will actually meet rather than
  # a hand-built header.
  defp jpeg(width, height) do
    # Random pixels rather than a flat fill: a uniform image compresses
    # to a JPEG with an unusually short scan, which is not
    # representative of the frames this parser actually meets.
    bytes = :crypto.strong_rand_bytes(width * height * 3)

    bytes
    |> Evision.Mat.from_binary({:u, 8}, height, width, 3)
    |> then(&Evision.imencode(".jpg", &1))
  end

  describe "decode_dimensions/1" do
    test "agrees with Evision on a real JPEG" do
      for {width, height} <- [{480, 270}, {640, 360}, {1280, 720}, {17, 5}] do
        assert {:ok, ^width, ^height} = Zenoh.decode_dimensions(jpeg(width, height)),
               "failed for #{width}x#{height}"
      end
    end

    test "rejects data that is not a JPEG" do
      assert Zenoh.decode_dimensions(<<0, 1, 2, 3>>) == :error
      assert Zenoh.decode_dimensions(<<>>) == :error
      # PNG magic — a plausible mistake if a publisher changes format.
      assert Zenoh.decode_dimensions(<<0x89, ?P, ?N, ?G, 13, 10, 26, 10>>) == :error
    end

    test "rejects a truncated JPEG rather than guessing" do
      full = jpeg(480, 270)
      assert Zenoh.decode_dimensions(binary_part(full, 0, 4)) == :error
    end
  end
end
