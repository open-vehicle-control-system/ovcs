defmodule VisionCore.Exporter do
  @moduledoc """
  Takes the vision unit's outputs out of it: to ROS 2, an MQTT broker,
  a recorder. An exporter is a module of plain functions implementing
  this behaviour. `VisionCore.Exporter.Runner` runs it, and
  `VisionCore.Exporters` starts each exporter under a supervisor and
  restart budget of its own (`VisionCore.Exporter.Supervisor`), so an
  exporter that keeps crashing stops alone while the cameras, the
  pipelines and the other exporters run on.

  ## Outputs

  `c:outputs/1` names what the exporter reads by output, not by the
  process producing it. Each output hands `c:handle_output/3` a value:

    * `:stereo_pair` — a `VisionCore.Stereo.Pair` the stereo pipeline
      finished;
    * `{:camera_frame, :left}`, `{:camera_frame, :right}` — a
      `VisionCore.Camera.Frame` a stereo camera captured;
    * `{:camera_frame, name}` — a `VisionCore.Camera.Frame` the camera
      `name` captured, a `:camera` component (`VisionCore.Camera.Unit`),
      of its default output;
    * `{:camera_frame, name, output}` — a frame of the camera `name`'s
      image output `output` (`VisionCore.Camera.Output`);
    * `{:camera_video, name, output}` — a frame of the camera `name`'s
      H.264 output `output`, carrying one frame of the stream
      (`VisionCore.Camera.Frame`);
    * `{:detections, name}` — `{pair, detections}`, the result for
      `pair` of the detection pipeline named `name`, `:detection` for
      the one a detector without a `:name` starts
      (`VisionCore.Detection`), or `{frame, detections}`, the result for
      the `VisionCore.Camera.Frame` `frame` of one whose source is a
      camera of its own;
    * `{:segmentation, name}` — `{frame, labels, clouds}`, the result for
      the `VisionCore.Camera.Frame` `frame` of the segmentation pipeline
      named `name`: its label image and its road and off-road points,
      `nil` without a stereo pair matched with the frame, or when the
      camera's calibration or pose is missing or its calibration cannot
      be projected at the frame's size (`VisionCore.Segmentation.Pipeline`).

  An entry is an output, or `{output, options}` whose one option is
  `:max_hz`, the most values of the output handed over a second
  (`output_specs/2`), which a video does not take:

      [{:camera_frame, :left}, {{:detections, :road}, max_hz: 2}, stereo_pair: [max_hz: 5]]

  The runner subscribes to each output through `VisionCore.Outputs`,
  under the key `output_key/2` resolves in the configuration, and leaves
  out an output nothing in the configuration produces, such as
  `{:detections, :road}` on a unit without a detector named `:road`, or `{:camera_frame, :hq}` on
  one without a camera named `:hq`. The exporter is handed the
  newest value of each output only: values that came while it was busy
  are dropped, and under `:max_hz` the latest one is held until the
  output's next slot opens. A video is the exception: a decoder needs
  every frame from a key frame on, so the exporter is handed every frame
  of it in order, from a key frame, those that come while it is busy
  queued (`VisionCore.Camera.VideoQueue`).

  An output's messages are `{output, value}`, but a camera's, which are
  `{:camera_frame, frame}`, the frame carrying the camera's side, or
  its name, as its `:label`. A new output is one more entry in this
  module's table of outputs, with the unit whose `outputs/1` gives its
  key, its messages `{output, value}`.

  ## Callbacks

  `c:init/1`, `c:handle_output/3`, `c:handle_info/2`,
  `c:handle_action/4`, `c:status/1` and `c:terminate/2` run in the
  runner's process, and each returns at once:

    * `c:init/1` must not block. It is called after the runner starts,
      and again, after a growing delay, until it returns `{:ok, state}`;
      the exporter receives no output until then, and the messages that
      reach the runner before are dropped.
    * A connection belongs to a helper `c:children/1` names, which the
      exporter's supervisor starts before the runner: its `start_link`
      returns at once and it reconnects on its own, telling the exporter
      about its link with messages (`c:handle_info/2`) that `c:status/1`
      reports. `c:init/1` reads the helper's link itself and gives it
      the runner's pid to send to: the helper outlives the runner's
      restarts, and a send to a pid that is gone does nothing, where one
      to a name not registered raises. A helper that fails to start
      leaves the exporter down.
    * `c:handle_output/3` does not wait on a slow transport: it returns
      `{:busy, state}`, and the runner hands it nothing more of that
      output, holding the newest value, until `c:handle_info/2` returns
      `{:ready, output, state}`, typically on the transport's
      acknowledgement. `{:error, reason, state}` counts a value not
      exported, which the default status shows.
    * `c:status/1` answers `VisionCore.Exporter.Runner.status/2`; one
      that raises, or answers no status, is reported as a warning.
    * `c:terminate/2`, when defined, makes the runner trap exits so that
      it is called on shutdown too; an exit of a linked process then
      stops the runner as it would without it, and `c:handle_info/2`
      never sees `{:EXIT, _, _}`.

  The callbacks that take options get the exporter's own, to which
  `VisionCore.Exporters` adds `:jpeg_codec`, the `VisionCore.Jpeg`
  instance to encode on, apart from the pipeline's, and `:config`, the
  active `VisionCore.Config`. A `:name` among them registers the runner,
  so that other processes can send the exporter messages; an `:id` tells
  two exporters of one module apart, replacing the id of
  `c:describe/1`.

  ## Starting and listing

  `c:check/1`, when defined, runs before anything else: an exporter
  whose options, or the configuration they need, cannot work, such as
  the ROS 2 exporter without the ROS 2 link, is not started, with the
  reason logged, and the unit runs on without it. `c:describe/1` gives
  the id and the name `VisionCore.Exporters.list/0` lists the exporter
  under, the dashboard's Exporters menu among its readers.

  These return at once, as `c:children/1` does: `c:check/1`,
  `c:children/1` and `c:describe/1` run while `VisionCore.Exporters`
  starts, which the vision unit's start waits for, and `c:describe/1`,
  `c:outputs/1` and `c:actions/1` again at each listing, which
  `VisionCore.Status` makes every second.

  `c:actions/1` lists what people can ask of the exporter, such as an
  export to download, each run by `VisionCore.Exporters.action/4` through
  the runner. The runner answers `{:error, :not_running}` until
  `c:init/1` succeeds and `{:error, :unknown_action}` for a name the
  exporter does not list, without calling it; otherwise it hands the
  action to `c:handle_action/4`, which returns at once: with its result,
  or with `{:noreply, state}` and answers later with `reply/2`, from any
  process.

  ## Example

      defmodule MyCar.Vision.MqttExporter do
        @behaviour VisionCore.Exporter

        @impl VisionCore.Exporter
        def children(options), do: [{MyCar.Mqtt, broker: Keyword.fetch!(options, :broker)}]

        @impl VisionCore.Exporter
        def outputs(_options), do: [{:stereo_pair, max_hz: 5}, {:detections, :detection}]

        @impl VisionCore.Exporter
        def init(options) do
          link = MyCar.Mqtt.attach(self())
          {:ok, %{prefix: Keyword.fetch!(options, :prefix), link: link}}
        end

        @impl VisionCore.Exporter
        def handle_output(:stereo_pair, pair, state),
          do: publish(state, "/depth", pair.depth, :stereo_pair)

        def handle_output({:detections, :detection} = output, {_pair, detections}, state),
          do: publish(state, "/detections", Jason.encode!(detections), output)

        @impl VisionCore.Exporter
        def handle_info({:mqtt_published, output}, state), do: {:ready, output, state}
        def handle_info({:mqtt_link, link}, state), do: {:ok, %{state | link: link}}
        def handle_info(_message, state), do: {:ok, state}

        @impl VisionCore.Exporter
        def status(%{link: :up}), do: {:ok, "Connected"}
        def status(_state), do: {:warning, "Broker unreachable"}

        defp publish(state, topic, payload, output) do
          case MyCar.Mqtt.publish_async(state.prefix <> topic, payload, output) do
            :ok -> {:busy, state}
            {:error, reason} -> {:error, reason, state}
          end
        end
      end

  started as `{MyCar.Vision.MqttExporter, broker: "10.0.0.2", prefix:
  "car/vision"}`. Its helper, `MyCar.Mqtt`, connects and reconnects on
  its own; `MyCar.Mqtt.attach/1` answers its link at once and has it
  send the runner each change of link. `MyCar.Mqtt.publish_async/3`
  returns at once, `{:error, :not_connected}` without a link, and has
  the helper send `{:mqtt_published, output}` once the broker
  acknowledges the message.
  """

  alias VisionCore.Camera.Frame
  alias VisionCore.Stereo.Pair

  # Each output, and the unit whose `outputs/1` gives its key; named ones in `producer/1`.
  @outputs %{
    :stereo_pair => VisionCore.Stereo.Supervisor,
    {:camera_frame, :left} => VisionCore.Stereo.Supervisor,
    {:camera_frame, :right} => VisionCore.Stereo.Supervisor
  }

  @typedoc "One of the unit's outputs; see the module doc."
  @type output ::
          :stereo_pair
          | {:detections, atom()}
          | {:segmentation, atom()}
          | {:camera_frame, atom()}
          | {:camera_frame, atom(), atom()}
          | {:camera_video, atom(), atom()}

  @typedoc "An entry of `c:outputs/1`: an output, with its options or without."
  @type output_spec :: output() | {output(), [{:max_hz, number()}]}

  @typedoc "What an output hands over; see the module doc."
  @type value ::
          Pair.t()
          | Frame.t()
          | {Pair.t() | Frame.t(), [map()]}
          | {Frame.t(), map(), map() | nil}

  @typedoc "How the exporter is doing, with a sentence saying why."
  @type status :: {:ok | :warning | :off, String.t()}

  @typedoc "The exporter's own state, from `c:init/1`."
  @type state :: term()

  @typedoc """
  An action people can run on the exporter: its `name`, then a `label`
  and a `description` for them.
  """
  @type action :: %{name: atom(), label: String.t(), description: String.t()}

  @typedoc """
  What an action answers: a JSON object, a file to download, or why it
  did not run.
  """
  @type action_result ::
          {:ok, map()}
          | {:file, filename :: String.t(), content_type :: String.t(), binary()}
          | {:error, :busy | {:timeout, String.t()} | {:failed, String.t()}}

  @doc "The outputs the exporter reads, given its options; it returns at once."
  @callback outputs(options :: keyword()) :: [output_spec()]

  @doc """
  The exporter's state, from its options, without blocking. On
  `{:error, reason}` or a raise the runner reports the exporter not
  started and calls it again later.
  """
  @callback init(options :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  Takes `value`, the newest of `output`, out of the unit, without
  waiting: `{:busy, state}` until `c:handle_info/2` says the output is
  ready again, `{:error, reason, state}` for a value not exported.
  """
  @callback handle_output(output(), value(), state()) ::
              {:ok, state()} | {:busy, state()} | {:error, term(), state()}

  @doc """
  Handles a message sent to the runner, such as a timer of its own or a
  helper's; `{:ready, output_or_outputs, state}` ends the outputs'
  `{:busy, state}`. An exporter whose `c:init/1` subscribes to a
  `VisionCore.Outputs` key that is none of its outputs receives here
  every message published under that key. It must accept any message.
  """
  @callback handle_info(message :: term(), state()) ::
              {:ok, state()} | {:ready, output() | [output()], state()}

  @doc """
  How the exporter is doing. Without it, `VisionCore.Exporter.Runner`
  reports its own: running, or the values not exported.
  """
  @callback status(state()) :: status()

  @doc """
  Helper processes, started before the runner under the exporter's
  supervisor. It returns at once: the vision unit's start waits for it.
  """
  @callback children(options :: keyword()) ::
              [Supervisor.child_spec() | {module(), term()} | module()]

  @doc "Flushes or closes what the exporter holds, as the runner stops."
  @callback terminate(reason :: term(), state()) :: term()

  @doc """
  Whether the exporter can run with `options`: `:ok`, or `{:error, reason}`,
  a sentence saying why not. Without it, every exporter can. It answers
  at once, from the options and the configuration: the vision unit's
  start waits for it.
  """
  @callback check(options :: keyword()) :: :ok | {:error, String.t()}

  @doc """
  How the exporter is listed: its id, an atom unique among the unit's
  exporters, and its name, for people. Without it, both are the
  exporter's module. It answers at once: the vision unit's start and
  each listing wait for it.
  """
  @callback describe(options :: keyword()) :: %{id: atom(), name: String.t()}

  @doc """
  The actions people can run on the exporter, given its options.
  Without it, none. It answers at once: each listing waits for it.
  """
  @callback actions(options :: keyword()) :: [action()]

  @doc """
  Runs `name`, one of `c:actions/1`, with `params`, without waiting:
  `{:reply, result, state}`, or `{:noreply, state}` to answer `from`
  later with `reply/2`. One that raises, or returns anything else,
  answers `{:error, {:failed, reason}}`, the state kept as it was.
  """
  @callback handle_action(name :: atom(), params :: map(), from :: GenServer.from(), state()) ::
              {:reply, action_result(), state()} | {:noreply, state()}

  @optional_callbacks handle_info: 2,
                      status: 1,
                      children: 1,
                      terminate: 2,
                      check: 1,
                      describe: 1,
                      actions: 1,
                      handle_action: 4

  @doc """
  Whether `term` is one of the outputs an exporter can name:
  `{:detections, name}` and `{:segmentation, name}` for a valid pipeline
  name (`VisionCore.Pipelines.name?/1`),
  `{:camera_frame, name}` for a stereo side or a valid camera name, and
  `{:camera_frame, name, output}` and `{:camera_video, name, output}` for
  a valid camera name and an atom.
  """
  @spec output?(term()) :: boolean()
  def output?({:detections, name}), do: VisionCore.Pipelines.name?(name)
  def output?({:segmentation, name}), do: VisionCore.Pipelines.name?(name)
  def output?({:camera_frame, side}) when side in [:left, :right], do: true
  def output?({:camera_frame, name}), do: VisionCore.Pipelines.name?(name)

  def output?({kind, name, output}) when kind in [:camera_frame, :camera_video],
    do: name not in [:left, :right] and VisionCore.Pipelines.name?(name) and is_atom(output)

  def output?(term), do: is_map_key(@outputs, term)

  defp producer({:detections, _name}), do: VisionCore.Detection.Supervisor
  defp producer({:segmentation, _name}), do: VisionCore.Segmentation.Supervisor

  defp producer({:camera_frame, name}) when name not in [:left, :right],
    do: VisionCore.Camera.Unit

  defp producer(output), do: Map.fetch!(@outputs, output)

  @doc """
  The outputs `exporter` reads with `options`, in its `c:outputs/1`
  order, each with the most values it is handed a second, `nil` when
  unbounded. `{:error, {:invalid_output, entry}}` for the first entry
  that names no output, names one a second time, has options other
  than a positive `:max_hz`, or a `:max_hz` on a video;
  `{:error, {:outputs_raised, message}}` when
  `c:outputs/1` raises.
  """
  @spec output_specs(module(), keyword()) ::
          {:ok, [{output(), number() | nil}]}
          | {:error, {:invalid_output, term()} | {:outputs_raised, String.t()}}
  def output_specs(exporter, options) do
    options
    |> exporter.outputs()
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, specs} ->
      with {output, _max_hz} = spec <- output_spec(entry),
           false <- List.keymember?(specs, output, 0) do
        {:cont, {:ok, [spec | specs]}}
      else
        _invalid -> {:halt, {:error, {:invalid_output, entry}}}
      end
    end)
    |> case do
      {:ok, specs} -> {:ok, Enum.reverse(specs)}
      error -> error
    end
  rescue
    exception -> {:error, {:outputs_raised, Exception.message(exception)}}
  end

  defp output_spec({{:camera_video, _name, _output}, [_option | _others]}), do: nil

  defp output_spec({output, options}) when is_list(options) do
    with true <- output?(output),
         {:ok, max_hz} <- max_hz(options),
         do: {output, max_hz},
         else: (_invalid -> nil)
  end

  defp output_spec(output), do: output_spec({output, []})

  defp max_hz([]), do: {:ok, nil}
  defp max_hz(max_hz: max_hz) when is_number(max_hz) and max_hz > 0, do: {:ok, max_hz}
  defp max_hz(_options), do: :error

  @doc """
  The id and name `exporter` is listed under with `options`: those of its
  `c:describe/1`, the id replaced by an `:id` among `options`, and without
  `c:describe/1`, or when it raises, its module.
  """
  @spec identity(module(), keyword()) :: %{id: term(), name: String.t()}
  def identity(exporter, options) do
    described =
      if Code.ensure_loaded?(exporter) and function_exported?(exporter, :describe, 1),
        do: exporter.describe(options),
        else: %{id: exporter, name: inspect(exporter)}

    Map.put(described, :id, Keyword.get(options, :id, described.id))
  rescue
    _exception -> %{id: Keyword.get(options, :id, exporter), name: inspect(exporter)}
  end

  @doc """
  The actions people can run on `exporter` with `options`, those of its
  `c:actions/1`; none without it, or when it raises.
  """
  @spec actions(module(), keyword()) :: [action()]
  def actions(exporter, options) do
    if Code.ensure_loaded?(exporter) and function_exported?(exporter, :actions, 1),
      do: exporter.actions(options),
      else: []
  rescue
    _exception -> []
  end

  @doc """
  Answers the action `from` asked for, after `c:handle_action/4` returned
  `{:noreply, state}`. It can be called from any process, such as a task
  the exporter starts.
  """
  @spec reply(GenServer.from(), action_result()) :: :ok
  def reply(from, result), do: GenServer.reply(from, result)

  @doc """
  The `VisionCore.Outputs` key `output` is published under on the unit
  `config` describes, the active `VisionCore.Config` by default, from
  the `outputs/1` of the unit that produces it
  (`VisionCore.Stereo.Supervisor`, `VisionCore.Detection.Supervisor`,
  `VisionCore.Segmentation.Supervisor`, `VisionCore.Camera.Unit`), and for
  a camera's named output from `VisionCore.Camera.Unit.output_key/3`, or
  `VisionCore.Camera.Unit.video_key/3` for a video.
  `nil` when nothing in `config` produces `output`; raises
  `ArgumentError` for a term that is no output (`output?/1`).
  """
  @spec output_key(output(), VisionCore.Config.t() | nil) :: VisionCore.Outputs.key() | nil
  def output_key(output, config \\ VisionCore.Application.active_config())

  def output_key(_output, nil), do: nil

  def output_key(output, %VisionCore.Config{} = config) do
    unless output?(output), do: raise(ArgumentError, "no output #{inspect(output)}")
    key(output, config)
  end

  defp key({:camera_frame, name, output}, config),
    do: VisionCore.Camera.Unit.output_key(config, name, output)

  defp key({:camera_video, name, output}, config),
    do: VisionCore.Camera.Unit.video_key(config, name, output)

  defp key(output, config) do
    case List.keyfind(producer(output).outputs(config), output, 0) do
      {^output, key} -> key
      nil -> nil
    end
  end
end
