defmodule CvBridgex.RosImageEmitter do
  use GenServer
  require Logger

  alias CvBridgex.CvCamera
  alias Rclex.Pkgs.SensorMsgs
  alias Rclex.Pkgs.StdMsgs
  alias Evision, as: Cv

  @delay 1000

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    Rclex.start_node("camera")
    Rclex.start_publisher(SensorMsgs.Msg.Image, "/camera", "camera")
    send_picture(@delay)
    {:ok, %{
      latest_picture: nil,
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
    send_picture(@delay)
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_info(:send_picture, state) do
    {:ok, cv_picture} = CvCamera.get_latest_picture()
    case cv_picture do
      nil ->
        {:noreply, %{state | latest_picture: nil, loop_active: false}}
      _ ->
        ros_picture = create_ros_picture(cv_picture)
        if state.loop_active do
          #Rclex.publish(ros_picture, "/camera", "camera")
          send_picture(@delay)
        end
        {:noreply, %{state | latest_picture: ros_picture}}
    end
  end

  def stop() do
    GenServer.call(__MODULE__, :stop)
  end

  def start() do
    GenServer.call(__MODULE__, :start)
  end

  defp send_picture(delay) do
    Process.send_after(self(), :send_picture, delay)
  end

  defp create_ros_picture(cv_picture) do
    stamp         = struct(Rclex.Pkgs.BuiltinInterfaces.Msg.Time, %{sec: :os.system_time(:second), nanosec: :os.system_time(:nanosecond)})
    frame_id      = "OVCS"
    height        = cv_picture.shape |> elem(0)
    width         = cv_picture.shape |> elem(1)
    encoding      = "#{cv_picture.type |> elem(1)}#{cv_picture.type |> elem(0) |> to_string |> String.capitalize()}C#{cv_picture.channels}"
    #encoding      = "bgr8"
    is_bigendian  = false
    step          = (cv_picture.shape |> elem(2)) * (cv_picture.shape |> elem(1))
    data          = (cv_picture |> Cv.Mat.to_binary() |> :binary.bin_to_list() |> IO.chardata_to_string())
    Logger.info(cv_picture)
    struct(SensorMsgs.Msg.Image, %{
      header: struct(StdMsgs.Msg.Header, %{ stamp: stamp, frame_id: frame_id }),
      height: height,
      width: width,
      encoding: encoding,
      is_bigendian: is_bigendian,
      step: step,
      data: data
    })
  end
end
