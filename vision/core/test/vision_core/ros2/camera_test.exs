defmodule VisionCore.Ros2.CameraTest do
  use ExUnit.Case, async: true

  alias VisionCore.Ros2.Camera

  # A real JPEG of random pixels: a flat fill compresses to an unrepresentative short scan.
  defp jpeg(width, height) do
    pixels = :crypto.strong_rand_bytes(width * height * 3)

    pixels
    |> Evision.Mat.from_binary({:u, 8}, height, width, 3)
    |> then(&Evision.imencode(".jpg", &1))
  end

  describe "decode_dimensions/1" do
    test "agrees with Evision on a real JPEG" do
      for {width, height} <- [{480, 270}, {640, 360}, {1280, 720}, {17, 5}] do
        assert {:ok, ^width, ^height} = Camera.decode_dimensions(jpeg(width, height)),
               "failed for #{width}x#{height}"
      end
    end

    test "rejects data that is not a JPEG" do
      assert Camera.decode_dimensions(<<0, 1, 2, 3>>) == :error
      assert Camera.decode_dimensions(<<>>) == :error
      # PNG magic — a plausible mistake if a publisher changes format.
      assert Camera.decode_dimensions(<<0x89, ?P, ?N, ?G, 13, 10, 26, 10>>) == :error
    end

    test "rejects a truncated JPEG rather than guessing" do
      full = jpeg(480, 270)
      assert Camera.decode_dimensions(binary_part(full, 0, 4)) == :error
    end
  end
end
