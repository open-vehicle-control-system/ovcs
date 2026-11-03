defmodule VisionCore.Exporters do
  @moduledoc """
  Runs the vision unit's exporters (`VisionCore.Exporter`), each under a
  `VisionCore.Exporter.Supervisor` with a restart budget of its own,
  `:one_for_one`: an exporter that keeps crashing stops alone, for good,
  and is logged as stopped. Its child stays in the list, without a
  process.

  `VisionCore.Application` starts it last in `VisionCore.Supervisor`,
  after the components, `VisionCore.Status` and `VisionCore.Preview`:
  under `:rest_for_one`, a restart of the exporters restarts nothing
  else.

  Each exporter's child id is the `:id` in its options, its module
  without one. An exporter whose id is already taken is not started,
  with an error logged: two of one module need an `:id` each. The last
  child, a worker, watches the exporters' supervisors to log those that
  stop because they kept failing, not those stopped on purpose.

  ## Options

    * `:config` — the active `VisionCore.Config` (required), in which the
      exporters' outputs resolve.
    * `:exporters` (`from_config/1` of `:config`) — the exporters to run,
      each `{module, options}`. A `:name` in the options registers the
      exporter's runner under it.
    * `:jpeg_codec` (`VisionCore.Jpeg`) — the `VisionCore.Jpeg` instance
      the exporters encode on, put in each one's options as
      `:jpeg_codec` unless it has its own. `VisionCore.Application`
      gives `VisionCore.Jpeg.Export`, apart from the pipeline's.
  """
  use Supervisor
  require Logger

  alias VisionCore.Exporter
  alias VisionCore.Exporters.Watch
  alias VisionCore.Ros2.ZenohClient

  @ros2_stereo_keys [
    :publish_disparity_image,
    :publish_rectified_image,
    :publish_raw_images,
    :raw_image_max_hz
  ]
  @ros2_detection_keys [:topic_prefix, :frame_id, :marker_lifetime_ms, :label_font_size]

  @doc "Starts the exporters; see the module doc for `opts`."
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The exporters `config` runs, each `{module, options}`: the ROS 2
  exporter, `VisionCore.Ros2.Exporter`, registered under its module's
  name, with the node name of `config` and what its components ask to
  publish: a heartbeat for `:heartbeat`, the stereo unit of `:stereo`
  with the ROS 2 options among its own, and the detections of
  `:detector` or `:hailo_detector` with theirs.
  """
  @spec from_config(VisionCore.Config.t()) :: [{module(), keyword()}]
  def from_config(%VisionCore.Config{} = config) do
    options =
      [
        name: VisionCore.Ros2.Exporter,
        node_name: ZenohClient.configured_node_name(config)
      ] ++ Enum.flat_map(config.components, &ros2_options/1)

    [{VisionCore.Ros2.Exporter, options}]
  end

  defp ros2_options(name) when is_atom(name), do: ros2_options({name, []})
  defp ros2_options({:heartbeat, opts}), do: [heartbeat: Keyword.take(opts, [:interval_ms])]

  defp ros2_options({:stereo, opts}) do
    cameras = VisionCore.Stereo.Supervisor.camera_options(opts)
    sides = for side <- [:left, :right], do: {side, ros2_side(cameras[side])}

    [stereo: Keyword.merge(cameras, sides) ++ Keyword.take(opts, @ros2_stereo_keys)]
  end

  defp ros2_options({detector, opts}) when detector in [:detector, :hailo_detector],
    do: [detections: Keyword.take(opts, @ros2_detection_keys)]

  defp ros2_options(_component), do: []

  defp ros2_side(side_options) do
    for key <- [:frame_id, :calibration_path, :sync],
        value = side_options[key],
        do: {key, value}
  end

  @impl Supervisor
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    jpeg_codec = Keyword.get(opts, :jpeg_codec, VisionCore.Jpeg)

    exporters =
      opts
      |> Keyword.get_lazy(:exporters, fn -> from_config(config) end)
      |> Enum.map(fn {exporter, options} ->
        Exporter.Supervisor.child_spec(
          exporter: exporter,
          options: Keyword.put_new(options, :jpeg_codec, jpeg_codec),
          config: config
        )
      end)
      |> Enum.reduce({[], MapSet.new([Watch])}, &keep_first_of_id/2)
      |> elem(0)
      |> Enum.reverse()

    Supervisor.init(exporters ++ [{Watch, self()}], strategy: :one_for_one)
  end

  # A second child under one id would fail this supervisor's start, and with it the vision core's.
  defp keep_first_of_id(%{id: id, start: {_module, _function, [opts]}} = child, {kept, ids}) do
    if MapSet.member?(ids, id) do
      Logger.error(
        "#{inspect(opts[:exporter])} not started: an exporter already runs under the id " <>
          "#{inspect(id)}; give each its own :id"
      )

      {kept, ids}
    else
      {[child | kept], MapSet.put(ids, id)}
    end
  end
end

defmodule VisionCore.Exporters.Watch do
  @moduledoc false
  # Started after the exporters, so an orderly shutdown stops it first and it sees none stop.
  # An exporter supervisor that gives up and one stopped on purpose both exit :shutdown: what
  # tells them apart is a child of the exporter's that exited abnormally and was not seen again.
  use GenServer
  require Logger

  def start_link(exporters), do: GenServer.start_link(__MODULE__, exporters)

  @impl GenServer
  def init(exporters),
    do: {:ok, %{exporters: exporters, watched: %{}, failing: %{}}, {:continue, :watch}}

  @impl GenServer
  def handle_continue(:watch, state), do: {:noreply, watch(state)}

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    {watched, state} = pop_in(state, [:watched, monitor])
    {:noreply, state |> stopped(watched, reason) |> watch()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp stopped(state, {id, :exporter, _pid}, reason) do
    if reason == :shutdown and failing?(state, id), do: log_stopped(id)
    %{state | failing: Map.delete(state.failing, id)}
  end

  defp stopped(state, {id, child, _pid}, reason) do
    if crash?(reason),
      do: update_in(state, [:failing, Access.key(id, MapSet.new())], &MapSet.put(&1, child)),
      else: state
  end

  defp failing?(state, id), do: MapSet.size(Map.get(state.failing, id, MapSet.new())) > 0

  defp crash?({:shutdown, _reason}), do: false
  defp crash?(reason), do: reason not in [:normal, :shutdown, :noproc]

  defp log_stopped(id) do
    Logger.error("#{inspect(id)} stopped: it kept failing; the vision unit runs on without it")
  end

  # Monitors each exporter supervisor and child not yet watched; a child seen running is not failing.
  defp watch(state) do
    watched_pids = MapSet.new(state.watched, fn {_monitor, {_id, _what, pid}} -> pid end)

    for {id, pid, :supervisor, _modules} <- which_children(state.exporters),
        is_pid(pid),
        reduce: state do
      state ->
        for {child, child_pid, _type, _modules} <- which_children(pid),
            is_pid(child_pid),
            reduce: monitor(state, {id, :exporter, pid}, watched_pids) do
          state ->
            state
            |> monitor({id, child, child_pid}, watched_pids)
            |> running(id, child, child_pid)
        end
    end
  end

  defp monitor(state, {_id, _what, pid} = watched, watched_pids) do
    if MapSet.member?(watched_pids, pid),
      do: state,
      else: put_in(state, [:watched, Process.monitor(pid)], watched)
  end

  defp running(state, id, child, pid) do
    if Process.alive?(pid),
      do: update_in(state, [:failing, Access.key(id, MapSet.new())], &MapSet.delete(&1, child)),
      else: state
  end

  # A supervisor that stops while asked has no children to watch.
  defp which_children(supervisor) do
    Supervisor.which_children(supervisor)
  catch
    :exit, _reason -> []
  end
end
