defmodule VisionCore.Camera.Frame do
  @moduledoc """
  One frame produced by any module implementing `VisionCore.Camera`.

    * `:label` — driver-assigned identity (e.g. `"left"`, `"right"`).
      Lets a single consumer process multiplex frames from several
      cameras over its mailbox.
    * `:width`, `:height` — pixel dimensions.
    * `:capture_ns` — capture timestamp in nanoseconds, always on the
      Erlang monotonic timescale (`System.monotonic_time/1`). Drivers
      backed by hardware (libcamera) read the sensor's
      `SensorTimestamp`, which is kernel `CLOCK_MONOTONIC`, and so
      must convert with `VisionCore.Timing.monotonic_from_kernel/1`
      before populating this field — the two clocks differ by ~18
      years. See `VisionCore.Timing`.
    * `:jpeg` — the JPEG-compressed image bytes, or
    * `:grey` — `width * height` bytes of 8-bit grey, row-major.
      Exactly one of the two is set.
  """
  @enforce_keys [:label, :width, :height, :capture_ns]
  defstruct [:label, :width, :height, :capture_ns, jpeg: nil, grey: nil]

  @type t :: %__MODULE__{
          label: String.t(),
          width: pos_integer(),
          height: pos_integer(),
          capture_ns: integer(),
          jpeg: binary() | nil,
          grey: binary() | nil
        }

  @doc "The frame as JPEG bytes, encoding a grey frame through `VisionCore.Jpeg`."
  @spec to_jpeg(t()) :: {:ok, binary()} | {:error, term()}
  def to_jpeg(%__MODULE__{jpeg: jpeg}) when is_binary(jpeg), do: {:ok, jpeg}

  def to_jpeg(%__MODULE__{grey: grey, width: width, height: height}) when is_binary(grey),
    do: VisionCore.Jpeg.encode(grey, width, height, 1)

  @doc """
  The frame as a `u8` `{height, width}` tensor, decoding a JPEG frame
  to its luma through `VisionCore.Jpeg`.
  """
  @spec to_tensor(t()) :: {:ok, Nx.Tensor.t()} | {:error, {:jpeg, term()}}
  def to_tensor(%__MODULE__{grey: grey, width: width, height: height}) when is_binary(grey),
    do: {:ok, grey |> Nx.from_binary(:u8) |> Nx.reshape({height, width})}

  def to_tensor(%__MODULE__{jpeg: jpeg}) when is_binary(jpeg) do
    case VisionCore.Jpeg.decode_grey(jpeg) do
      {:ok, {width, height, pixels}} ->
        {:ok, pixels |> Nx.from_binary(:u8) |> Nx.reshape({height, width})}

      {:error, reason} ->
        {:error, {:jpeg, reason}}
    end
  end
end
