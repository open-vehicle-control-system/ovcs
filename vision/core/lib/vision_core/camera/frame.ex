defmodule VisionCore.Camera.Frame do
  @moduledoc """
  One frame produced by any module implementing `VisionCore.Camera`.

    * `:label` — driver-assigned identity (e.g. `"left"`, `"right"`).
      Lets a single consumer process multiplex frames from several
      cameras over its mailbox.
    * `:frame_id` — the camera's optical frame, the coordinate frame
      what is measured on the image is positioned in, as the driver was
      configured with it; `nil` when it was not. The stereo unit gives
      each camera its own (`VisionCore.Stereo.Supervisor`), and the
      exporters stamp what they publish of the frame with it.
    * `:width`, `:height` — pixel dimensions.
    * `:capture_ns` — capture timestamp in nanoseconds, always on the
      Erlang monotonic timescale (`System.monotonic_time/1`). Drivers
      backed by hardware (libcamera) read the sensor's
      `SensorTimestamp`, which is kernel `CLOCK_MONOTONIC`, and so
      must convert with `VisionCore.Timing.monotonic_from_kernel/1`
      before populating this field — the two clocks differ by ~18
      years. See `VisionCore.Timing`.
    * `:output` — the name of the camera's output the frame is of
      (`VisionCore.Camera.Output`), `nil` from a driver without named
      outputs.
    * `:jpeg` — the JPEG-compressed image bytes, or
    * `:grey` — `width * height` bytes of 8-bit grey, row-major, or
    * `:rgb` — `width * height * 3` bytes of 8-bit red, green and blue,
      row-major. One of the three is set, except on a frame published
      with a pipeline's results, which has none.
  """
  @enforce_keys [:label, :width, :height, :capture_ns]
  defstruct [
    :label,
    :width,
    :height,
    :capture_ns,
    frame_id: nil,
    output: nil,
    jpeg: nil,
    grey: nil,
    rgb: nil
  ]

  @type t :: %__MODULE__{
          label: String.t(),
          frame_id: String.t() | nil,
          output: atom() | nil,
          width: pos_integer(),
          height: pos_integer(),
          capture_ns: integer(),
          jpeg: binary() | nil,
          grey: binary() | nil,
          rgb: binary() | nil
        }

  @doc """
  The frame as JPEG bytes, encoding a grey or RGB frame on `jpeg_codec`,
  a `VisionCore.Jpeg` instance, once for every consumer encoding the same
  frame there: a frame is its camera's (`:label`), its output's and its
  capture time's.
  """
  @spec to_jpeg(t(), GenServer.server()) :: {:ok, binary()} | {:error, term()}
  def to_jpeg(frame, jpeg_codec \\ VisionCore.Jpeg)

  def to_jpeg(%__MODULE__{jpeg: jpeg}, _jpeg_codec) when is_binary(jpeg), do: {:ok, jpeg}

  def to_jpeg(%__MODULE__{grey: grey, width: width, height: height} = frame, jpeg_codec)
      when is_binary(grey),
      do: VisionCore.Jpeg.encode(grey, width, height, 1, encode_options(frame, jpeg_codec))

  def to_jpeg(%__MODULE__{rgb: rgb, width: width, height: height} = frame, jpeg_codec)
      when is_binary(rgb),
      do: VisionCore.Jpeg.encode(rgb, width, height, 3, encode_options(frame, jpeg_codec))

  defp encode_options(frame, jpeg_codec),
    do: [codec: jpeg_codec, frame: {{frame.label, frame.output}, frame.capture_ns}]

  @doc """
  The frame as a `u8` tensor: `{height, width, 3}` for an RGB frame,
  `{height, width}` for a grey one, and for a JPEG frame its luma,
  decoded through `VisionCore.Jpeg`.
  """
  @spec to_tensor(t()) :: {:ok, Nx.Tensor.t()} | {:error, {:jpeg, term()}}
  def to_tensor(%__MODULE__{grey: grey, width: width, height: height}) when is_binary(grey),
    do: {:ok, grey |> Nx.from_binary(:u8) |> Nx.reshape({height, width})}

  def to_tensor(%__MODULE__{rgb: rgb, width: width, height: height}) when is_binary(rgb),
    do: {:ok, rgb |> Nx.from_binary(:u8) |> Nx.reshape({height, width, 3})}

  def to_tensor(%__MODULE__{jpeg: jpeg}) when is_binary(jpeg) do
    case VisionCore.Jpeg.decode_grey(jpeg) do
      {:ok, {width, height, pixels}} ->
        {:ok, pixels |> Nx.from_binary(:u8) |> Nx.reshape({height, width})}

      {:error, reason} ->
        {:error, {:jpeg, reason}}
    end
  end
end
