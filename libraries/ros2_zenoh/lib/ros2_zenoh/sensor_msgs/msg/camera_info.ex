defmodule Ros2Zenoh.SensorMsgs.Msg.CameraInfo do
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
    * The fixed `float64[9]` arrays that follow continue an 8-aligned
      run — no extra padding needed.
    * After the last `float64[12]`, two `uint32`s are 4-aligned by
      virtue of starting on an 8-boundary.
    * `RegionOfInterest`'s first field is u32 (4-aligned, fine after
      the previous u32 run).

  Both the encoder and the parser assume this message starts at the
  encapsulated-body origin, which is what makes `byte_size(buffer)` a
  valid CDR offset. That holds for CameraInfo on its own topic and as
  the first field of `SetCameraInfo_Request`. Embedding it at a
  non-8-aligned offset inside some larger message would need the true
  offset threaded in from the outermost parser.
  """
  use Ros2Zenoh.Common

  alias Ros2Zenoh.SensorMsgs.Msg.RegionOfInterest
  alias Ros2Zenoh.StdMsgs.Msg.Header

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

  def msg_definition do
    """
    # This message defines meta information for a camera. It should be in a
    # camera namespace on topic "camera_info" and accompanied by up to five
    # image topics named:
    #
    #   image_raw - raw data from the camera driver, possibly Bayer encoded
    #   image            - monochrome, distorted
    #   image_color      - color, distorted
    #   image_rect       - monochrome, rectified
    #   image_rect_color - color, rectified
    #
    # The image_pipeline contains packages (image_proc, stereo_image_proc)
    # for producing the four processed image topics from image_raw and
    # camera_info. The meaning of the camera parameters are described in
    # detail at http://www.ros.org/wiki/image_pipeline/CameraInfo.
    #
    # The image_geometry package provides a user-friendly interface to
    # common operations using this meta information. If you want to, e.g.,
    # project a 3d point into image coordinates, we strongly recommend
    # using image_geometry.
    #
    # If the camera is uncalibrated, the matrices D, K, R, P should be left
    # zeroed out. In particular, clients may assume that K[0] == 0.0
    # indicates an uncalibrated camera.

    #######################################################################
    #                     Image acquisition info                          #
    #######################################################################

    # Time of image acquisition, camera coordinate frame ID
    std_msgs/Header header # Header timestamp should be acquisition time of image
                                 # Header frame_id should be optical frame of camera
                                 # origin of frame should be optical center of camera
                                 # +x should point to the right in the image
                                 # +y should point down in the image
                                 # +z should point into the plane of the image


    #######################################################################
    #                      Calibration Parameters                         #
    #######################################################################
    # These are fixed during camera calibration. Their values will be the #
    # same in all messages until the camera is recalibrated. Note that    #
    # self-calibrating systems may "recalibrate" frequently.              #
    #                                                                     #
    # The internal parameters can be used to warp a raw (distorted) image #
    # to:                                                                 #
    #   1. An undistorted image (requires D and K)                        #
    #   2. A rectified image (requires D, K, R)                           #
    # The projection matrix P projects 3D points into the rectified image.#
    #######################################################################

    # The image dimensions with which the camera was calibrated.
    # Normally this will be the full camera resolution in pixels.
    uint32 height
    uint32 width

    # The distortion model used. Supported models are listed in
    # sensor_msgs/distortion_models.hpp. For most cameras, "plumb_bob" - a
    # simple model of radial and tangential distortion - is sufficent.
    string distortion_model

    # The distortion parameters, size depending on the distortion model.
    # For "plumb_bob", the 5 parameters are: (k1, k2, t1, t2, k3).
    float64[] d

    # Intrinsic camera matrix for the raw (distorted) images.
    #     [fx  0 cx]
    # K = [ 0 fy cy]
    #     [ 0  0  1]
    # Projects 3D points in the camera coordinate frame to 2D pixel
    # coordinates using the focal lengths (fx, fy) and principal point
    # (cx, cy).
    float64[9]  k # 3x3 row-major matrix

    # Rectification matrix (stereo cameras only)
    # A rotation matrix aligning the camera coordinate system to the ideal
    # stereo image plane so that epipolar lines in both stereo images are
    # parallel.
    float64[9]  r # 3x3 row-major matrix

    # Projection/camera matrix
    #     [fx'  0  cx' Tx]
    # P = [ 0  fy' cy' Ty]
    #     [ 0   0   1   0]
    # By convention, this matrix specifies the intrinsic (camera) matrix
    #  of the processed (rectified) image. That is, the left 3x3 portion
    #  is the normal camera intrinsic matrix for the rectified image.
    # It projects 3D points in the camera coordinate frame to 2D pixel
    #  coordinates using the focal lengths (fx', fy') and principal point
    #  (cx', cy') - these may differ from the values in K.
    # For monocular cameras, Tx = Ty = 0. Normally, monocular cameras will
    #  also have R = the identity and P[1:3,1:3] = K.
    # For a stereo pair, the fourth column [Tx Ty 0]' is related to the
    #  position of the optical center of the second camera in the first
    #  camera's frame. We assume Tz = 0 so both cameras are in the same
    #  stereo image plane. The first camera always has Tx = Ty = 0. For
    #  the right (second) camera of a horizontal stereo pair, Ty = 0 and
    #  Tx = -fx' * B, where B is the baseline between the cameras.
    # Given a 3D point [X Y Z]', the projection (x, y) of the point onto
    #  the rectified image is given by:
    #  [u v w]' = P * [X Y Z 1]'
    #         x = u / w
    #         y = v / w
    #  This holds for both images of a stereo pair.
    float64[12] p # 3x4 row-major matrix


    #######################################################################
    #                      Operational Parameters                         #
    #######################################################################
    # These define the image region actually captured by the camera       #
    # driver. Although they affect the geometry of the output image, they #
    # may be changed freely without recalibrating the camera.             #
    #######################################################################

    # Binning refers here to any camera setting which combines rectangular
    #  neighborhoods of pixels into larger "super-pixels." It reduces the
    #  resolution of the output image to
    #  (width / binning_x) x (height / binning_y).
    # The default values binning_x = binning_y = 0 is considered the same
    #  as binning_x = binning_y = 1 (no subsampling).
    uint32 binning_x
    uint32 binning_y

    # Region of interest (subwindow of full camera resolution), given in
    #  full resolution (unbinned) image coordinates. A particular ROI
    #  always denotes the same window of pixels on the camera sensor,
    #  regardless of binning settings.
    # The default setting of roi (all values 0) is considered the same as
    #  full resolution (roi.width = width, roi.height = height).
    RegionOfInterest roi
    """
  end

  def dependencies, do: [Header, RegionOfInterest]

  @type t :: %__MODULE__{
          header: %Header{} | nil,
          height: non_neg_integer(),
          width: non_neg_integer(),
          distortion_model: String.t(),
          d: [float()],
          k: [float()],
          r: [float()],
          p: [float()],
          binning_x: non_neg_integer(),
          binning_y: non_neg_integer(),
          roi: %RegionOfInterest{}
        }

  # RIHS01 hash for ROS 2 Lyrical; it changes with the distro.
  @dds_type "sensor_msgs::msg::dds_::CameraInfo_"
  @type_hash "RIHS01_b3dfd68ff46c9d56c80fd3bd4ed22c7a4ddce8c8348f2f59c299e73118e7e275"

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  def encode(%__MODULE__{} = camera_info) do
    Header.encode(camera_info.header)
    |> Kernel.<>(encode_uint32(camera_info.height))
    |> Kernel.<>(encode_uint32(camera_info.width))
    |> Kernel.<>(encode_string(camera_info.distortion_model))
    |> append_float64_sequence(camera_info.d)
    |> Kernel.<>(encode_float64_array_fixed(camera_info.k, 9))
    |> Kernel.<>(encode_float64_array_fixed(camera_info.r, 9))
    |> Kernel.<>(encode_float64_array_fixed(camera_info.p, 12))
    |> Kernel.<>(encode_uint32(camera_info.binning_x))
    |> Kernel.<>(encode_uint32(camera_info.binning_y))
    |> Kernel.<>(RegionOfInterest.encode(camera_info.roi))
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
