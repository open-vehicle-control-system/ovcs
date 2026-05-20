defmodule Ros2.SensorMsgs.Srv.SetCameraInfo do
  @moduledoc """
  ROS 2 `sensor_msgs/srv/SetCameraInfo`. Service request/response
  shape:

      Request:
        sensor_msgs/CameraInfo camera_info
      ---
      Response:
        bool   success
        string status_message

  Service-level metadata captured from a live Jazzy server's
  `@ros2_lv/**` liveliness token (entity prefix `SS`). The
  rmw_zenoh data keyexpr for the queryable is
  `<domain>/<service_name>/<dds_type>/<type_hash>`, same shape as a
  topic — the `dds_type` is the service's combined type
  (Request-side suffix stripped per rmw_zenoh convention).

  The QoS suffix in the liveliness token differs from a publisher's:
  services use `::,10:,:,:,,` (keep-last 10, reliable, volatile)
  versus our publishers' `::,:,:,:,,`. Pass `:service` to
  `Ros2.RmwZenoh.liveliness_key/6` so the right tail is emitted.
  """
  use Ros2.Common

  alias Ros2.SensorMsgs.Msg.CameraInfo

  # DDS-mangled service type. Note the trailing underscore — rosidl
  # convention. The same string is used in the data keyexpr and the
  # liveliness token.
  @dds_type "sensor_msgs::srv::dds_::SetCameraInfo_"

  # Captured against ROS 2 Jazzy via a rclpy service server's
  # liveliness token. Refresh on distro bumps.
  @type_hash "RIHS01_a10cca5d33dc637c8d49db50ab288701a3592bb9cd854f2f16a0659613b68984"

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  defmodule Request do
    @moduledoc "Wire form: a single `sensor_msgs/CameraInfo` field."
    defstruct [:camera_info]

    def parse(payload) do
      with {:ok, camera_info, rest} <- CameraInfo.parse(payload) do
        {:ok, %__MODULE__{camera_info: camera_info}, rest}
      end
    end
  end

  defmodule Response do
    @moduledoc """
    Wire form: `bool success`, `string status_message`. CDR
    alignment: u8 then string is fine — strings carry a 4-byte
    length prefix that re-establishes 4-alignment after the bool.
    """
    use Ros2.Common

    defstruct success: false, status_message: ""

    def encode(%__MODULE__{} = response) do
      # `bool` (1 byte) → padding to 4-align before the string's u32
      # length prefix.
      encode_bool(response.success)
      |> align_to(4)
      |> Kernel.<>(encode_string(response.status_message))
    end
  end
end
