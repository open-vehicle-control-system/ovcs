defmodule CvBridgex.RosImageEmitter do
  use GenServer
  require Logger

  alias Rclex.Pkgs.SensorMsgs
  alias Rclex.Pkgs.StdMsgs
  alias Rclex.Pkgs.BuiltinInterfaces
  alias Evision, as: Cv

  @delay 5

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(args) do
    Rclex.start_node("cameras")
    Enum.each(args, fn camera ->
      Rclex.start_publisher(SensorMsgs.Msg.Image, camera.topic, "cameras")
    end)
    send_messages(@delay)
    {:ok, %{
      cameras: args,
      loop_active: true
    }}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    state = %{state | loop_active: false}
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_call(:start, _from, state) do
    state = %{state | loop_active: true}
    send_messages(@delay)
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_info(:send_messages, state) do
    Enum.each(state.cameras, fn camera ->
      {:ok, cv_picture} = GenServer.call(camera.process_name, :get_latest_picture, 30000)
      case cv_picture do
        nil ->
          false
        _ ->
          message = create_ros_image_message(cv_picture)
          Rclex.publish(message, camera.topic, "cameras")
      end
    end)
    send_messages(@delay)
    {:noreply, state}
  end

  def stop() do
    GenServer.call(__MODULE__, :stop)
  end

  def start() do
    GenServer.call(__MODULE__, :start)
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
