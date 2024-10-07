defmodule CvBridgex.RosImageEmitter do
  use GenServer
  require Logger

  alias Rclex.Pkgs.SensorMsgs
  alias Rclex.Pkgs.StdMsgs
  alias Rclex.Pkgs.BuiltinInterfaces
  alias Evision, as: Cv

  @delay 20

  def start_link(%{process_name: process_name} = args) do
    GenServer.start_link(__MODULE__, args, name: process_name)
  end

  @impl true
  def init(%{process_name: process_name, topic: topic, camera_process_name: camera_process_name} = _args) do
    Rclex.start_node(topic)
    Rclex.start_publisher(SensorMsgs.Msg.Image, "/#{topic}", topic)
    send_messages(@delay)
    {:ok, %{
      camera_process_name: camera_process_name,
      topic: topic,
      process_name: process_name,
      loop_active: true
    }}
  end

  @impl true
  def handle_info(:send_messages, state) do
    {:ok, cv_picture} = GenServer.call(state.camera_process_name, :get_latest_picture, 30000)
    case cv_picture do
      nil ->
        Logger.warning("No picture...")
        false
      _ ->
        message = create_ros_image_message(cv_picture)
        Rclex.publish(message, "/#{state.topic}", state.topic)
    end
    send_messages(@delay)
    {:noreply, state}
  end

  defp send_messages(delay) do
    Process.send_after(self(), :send_messages, delay)
  end

  defp create_ros_image_message(cv_picture) do
    stamp         = %BuiltinInterfaces.Msg.Time{sec: :os.timestamp() |> elem(1), nanosec: :os.timestamp() |> elem(2)}
    frame_id      = "OVCS"
    height        = cv_picture.shape |> elem(0)
    width         = cv_picture.shape |> elem(1)
    encoding      = "#{cv_picture.type |> elem(1)}#{cv_picture.type |> elem(0) |> to_string |> String.capitalize()}C#{cv_picture.channels}"
    is_bigendian  = 0
    step          = (cv_picture.shape |> elem(2)) * (cv_picture.shape |> elem(1))
    data          = cv_picture |> Cv.Mat.to_binary()

    %SensorMsgs.Msg.Image{
      header: %StdMsgs.Msg.Header{stamp: stamp, frame_id: frame_id},
      height: height,
      width: width,
      encoding: encoding,
      is_bigendian: is_bigendian,
      step: step,
      data: data
    }
  end
end
