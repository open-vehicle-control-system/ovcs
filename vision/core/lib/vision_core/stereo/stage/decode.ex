defmodule VisionCore.Stereo.Stage.Decode do
  @moduledoc """
  Decodes both JPEG frames to single-channel images: matching works on
  one channel, and rectification then remaps one channel instead of
  three.
  """
  @behaviour VisionCore.Stereo.Stage

  alias VisionCore.Camera.Frame
  alias VisionCore.Stereo.Pair

  @impl VisionCore.Stereo.Stage
  def init(_opts, _context), do: {:ok, nil}

  @impl VisionCore.Stereo.Stage
  def requires, do: [:left_frame, :right_frame]

  @impl VisionCore.Stereo.Stage
  def provides, do: [:left, :right]

  @impl VisionCore.Stereo.Stage
  def run(%Pair{} = pair, state) do
    with {:ok, left} <- decode(pair.left_frame),
         {:ok, right} <- decode(pair.right_frame) do
      {:ok, %{pair | left: left, right: right}, state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp decode(%Frame{jpeg: jpeg}) do
    case Evision.imdecode(jpeg, Evision.Constant.cv_IMREAD_GRAYSCALE()) do
      %Evision.Mat{} = mat -> {:ok, mat}
      other -> {:error, {:imdecode_failed, other}}
    end
  end
end
