defmodule Ros2.SensorMsgs.Msg.CameraInfo do
  @moduledoc """
  ROS 2 `sensor_msgs/CameraInfo`. Field order on the wire (per the
  IDL):

      Header header
      uint32 height
      uint32 width
      string distortion_model
      float64[] D
      float64[9]  K
      float64[9]  R
      float64[12] P
      uint32 binning_x
      uint32 binning_y
      RegionOfInterest roi

  CDR alignment hazards:

    * After `Header` (tail 4-aligned via string padding) the two
      `uint32`s are 4-aligned naturally.
    * After `distortion_model` (string, 4-aligned tail), the unbounded
      `float64[] D` needs its u32 length prefix at a 4-aligned offset
      (fine) and then 8-alignment before the floats. How much padding
      that takes depends on the *actual* offset — `frame_id` lengths
      differing by one character move the prefix between the two
      8-residues — so `append_float64_sequence/2` is buffer-aware and
      `parse_float64_sequence/2` is told the body size.

  Both the encoder and the parser assume this message starts at the
  encapsulated-body origin, which is what makes `byte_size(buffer)` a
  valid CDR offset. That holds for CameraInfo on its own topic and as
  the first field of `SetCameraInfo_Request`. Embedding it at a
  non-8-aligned offset inside some larger message would need the true
  offset threaded in from the outermost parser.
    * The fixed `float64[9]` arrays that follow continue an 8-aligned
      run — no extra padding needed.
    * After the last `float64[12]`, two `uint32`s are 4-aligned by
      virtue of starting on an 8-boundary.
    * `RegionOfInterest`'s first field is u32 (4-aligned, fine after
      the previous u32 run).
  """
  use Ros2.Common

  alias Ros2.SensorMsgs.Msg.RegionOfInterest
  alias Ros2.StdMsgs.Msg.Header

  defstruct [
    :header,
    height: 0,
    width: 0,
    distortion_model: "plumb_bob",
    d: [],
    k: List.duplicate(0.0, 9),
    r: List.duplicate(0.0, 9),
    p: List.duplicate(0.0, 12),
    binning_x: 0,
    binning_y: 0,
    roi: %RegionOfInterest{}
  ]

  # Refresh on distro bumps — `ros2 topic info -v` of any live
  # CameraInfo publisher.
  @dds_type "sensor_msgs::msg::dds_::CameraInfo_"
  @type_hash "RIHS01_b3dfd68ff46c9d56c80fd3bd4ed22c7a4ddce8c8348f2f59c299e73118e7e275"

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  def encode(%__MODULE__{} = msg) do
    Header.encode(msg.header)
    |> Kernel.<>(encode_uint32(msg.height))
    |> Kernel.<>(encode_uint32(msg.width))
    |> Kernel.<>(encode_string(msg.distortion_model))
    |> append_float64_sequence(msg.d)
    |> Kernel.<>(encode_float64_array_fixed(msg.k, 9))
    |> Kernel.<>(encode_float64_array_fixed(msg.r, 9))
    |> Kernel.<>(encode_float64_array_fixed(msg.p, 12))
    |> Kernel.<>(encode_uint32(msg.binning_x))
    |> Kernel.<>(encode_uint32(msg.binning_y))
    |> Kernel.<>(RegionOfInterest.encode(msg.roi))
  end

  def parse(payload) do
    # Anchors the CDR offset used for `D`'s 8-alignment (see moduledoc).
    body_size = byte_size(payload)

    with {:ok, header, payload} <- Header.parse(payload),
         <<height::little-unsigned-integer-size(32), width::little-unsigned-integer-size(32),
           payload::binary>> <- payload,
         {:ok, distortion_model, payload} <- parse_string(payload),
         {:ok, d, payload} <- parse_float64_sequence(payload, body_size),
         {:ok, k, payload} <- parse_float64_array(payload, 9),
         {:ok, r, payload} <- parse_float64_array(payload, 9),
         {:ok, p, payload} <- parse_float64_array(payload, 12),
         <<binning_x::little-unsigned-integer-size(32),
           binning_y::little-unsigned-integer-size(32), payload::binary>> <- payload,
         {:ok, roi, payload} <- RegionOfInterest.parse(payload) do
      {:ok,
       %__MODULE__{
         header: header,
         height: height,
         width: width,
         distortion_model: distortion_model,
         d: d,
         k: k,
         r: r,
         p: p,
         binning_x: binning_x,
         binning_y: binning_y,
         roi: roi
       }, payload}
    else
      error -> error
    end
  end
end
