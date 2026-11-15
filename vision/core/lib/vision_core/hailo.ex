defmodule VisionCore.Hailo do
  @moduledoc """
  The unit's Hailo-8, through the `hailo` Port: one program opens the
  accelerator once and runs on it every network the configuration's
  Hailo units name, detection and segmentation alike, which HailoRT's
  scheduler gives the device in turn. Each network is a lane of
  `VisionCore.Inference.PortBackend`, named after its pipeline, with its
  own request in flight, so a long segmentation does not hold a
  detection back.

  `VisionCore.Detection.Backend.Hailo` and
  `VisionCore.Segmentation.Backend.Hailo` submit on their pipeline's
  lane; the vision core starts this once, from the `:hailo_detector`
  and `:hailo_segmenter` components' options, before their units
  (`VisionCore.Components.hailo_children/1`). A unit on it restarts with
  it (`VisionCore.Inference.Watch`), as a unit restarts with its own
  backend: its pipeline waits for no reply this process will not send.

  A Port rather than a NIF: an inference blocks for milliseconds, and a
  Hailo fault then kills a process the backend opens again, not the
  BEAM. A missing program or model is logged and leaves the Port closed,
  each lane answering `{:error, :unavailable}`.

  ## The Port's packets

  A request is its network's index among `:networks`, a byte, then the
  detection or segmentation request (`VisionCore.Detection.Backend.Wire`,
  `VisionCore.Segmentation.Backend.Wire`). A reply is the tag 10, the
  network's index, then the reply those modules read.

  ## Options

    * `:networks` (required) — the networks, a keyword list of each
      pipeline's name and its network: `kind: :detection`, `:hef_path`
      and `:score_threshold` (`0.4`), the lowest score `hailo` reports;
      or `kind: :segmentation`, `:hef_path`, `:classes` (`19`), the
      classes the pipeline names, and `:cell_pixels` (`8`), the side of
      the cells a label stands for, in the model's input pixels.
    * `:name` (this module) — the name it registers under.
    * `:executable` — the program (default `priv/hailo`).
    * `:working_directory` (`"/data"`) — where `hailo` runs; libhailort
      writes its log there.
    * `:library_path` — where libhailort is (default `Hailort.lib_dir/0`).
    * `:infer_timeout_ms`, `:reopen_delays_ms` — as
      `VisionCore.Inference.PortBackend` takes them.
  """
  @behaviour VisionCore.Inference.PortBackend

  alias VisionCore.Detection.Backend.Wire, as: DetectionWire
  alias VisionCore.Inference.PortBackend
  alias VisionCore.Options
  alias VisionCore.Segmentation.Backend.Wire, as: SegmentationWire

  # :hailort is a dependency only on targets that build hailo.
  @compile {:no_warn_undefined, Hailort}

  @reply_tag 10
  @default_score_threshold 0.4
  @default_cell_pixels 8
  @default_classes 19

  @doc false
  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @doc "Starts the Port's process; see the module doc for `opts`."
  def start_link(opts), do: PortBackend.start_link(__MODULE__, opts)

  @doc "The options of the Port, which a Hailo unit takes beside its network's."
  @spec port_options() :: [atom()]
  def port_options, do: [:executable, :working_directory, :library_path] ++ PortBackend.options()

  @impl PortBackend
  def init(opts) do
    networks = Enum.map(Keyword.get(opts, :networks, []), &network/1)

    if networks == [],
      do: raise(ArgumentError, "#{inspect(__MODULE__)} has no network: its :networks is empty")

    %{
      networks: networks,
      executable: Keyword.get_lazy(opts, :executable, &default_executable_path/0),
      working_directory: Keyword.get(opts, :working_directory, "/data"),
      library_path: Keyword.get(opts, :library_path)
    }
  end

  defp network({pipeline, opts}) do
    hef_path = Keyword.fetch!(opts, :hef_path)

    case Keyword.fetch!(opts, :kind) do
      :detection ->
        %{
          kind: :detection,
          pipeline: pipeline,
          hef_path: hef_path,
          score_threshold: Options.number!(opts, :score_threshold, @default_score_threshold) * 1.0
        }

      :segmentation ->
        %{
          kind: :segmentation,
          pipeline: pipeline,
          hef_path: hef_path,
          classes: Keyword.get(opts, :classes, @default_classes),
          cell_pixels: Keyword.get(opts, :cell_pixels, @default_cell_pixels)
        }
    end
  end

  @impl PortBackend
  def lanes(settings), do: Enum.map(settings.networks, & &1.pipeline)

  @impl PortBackend
  def wording(settings) do
    models = Enum.map(settings.networks, &Path.basename(&1.hef_path))

    %{
      label: inspect(__MODULE__),
      program: "hailo",
      loaded: "loaded #{Enum.join(models, ", ")}",
      input: "frame",
      output: "detections or labels"
    }
  end

  @impl PortBackend
  def inference_group(settings) do
    Enum.map(settings.networks, fn
      %{kind: :detection} = network ->
        VisionCore.Detection.Backend.Hailo.inference_group(network)

      %{kind: :segmentation} = network ->
        VisionCore.Segmentation.Backend.Hailo.inference_group(network)
    end)
  end

  @impl PortBackend
  def open(settings, nil) do
    missing = Enum.find(settings.networks, &(not File.exists?(&1.hef_path)))

    cond do
      not File.exists?(settings.executable) -> {:error, {:missing_binary, settings.executable}}
      missing != nil -> {:error, {:missing_hef, missing.hef_path}}
      true -> spawn_port(settings)
    end
  end

  defp spawn_port(settings) do
    port =
      Port.open({:spawn_executable, settings.executable}, [
        :binary,
        :exit_status,
        {:packet, 4},
        {:cd, String.to_charlist(settings.working_directory)},
        {:env,
         [{~c"LD_LIBRARY_PATH", String.to_charlist(settings.library_path || Hailort.lib_dir())}]},
        {:args, Enum.flat_map(settings.networks, &arguments/1)}
      ])

    {:ok, port}
  rescue
    error -> {:error, error}
  end

  defp arguments(%{kind: :detection} = network),
    do: ["--detect", network.hef_path, to_string(network.score_threshold)]

  defp arguments(%{kind: :segmentation} = network),
    do: ["--segment", network.hef_path, to_string(network.cell_pixels)]

  @impl PortBackend
  def final?({missing, _path}) when missing in [:missing_binary, :missing_hef], do: true
  def final?(_reason), do: false

  @impl PortBackend
  def lane_request(settings, lane, sequence, input) do
    {network, index} = network_of(settings, lane)
    [<<index>>, wire(network).request(sequence, input)]
  end

  @impl PortBackend
  def lane_parse(settings, <<@reply_tag, index, packet::binary>>) do
    case Enum.at(settings.networks, index) do
      nil -> :error
      network -> network |> wire() |> parse(packet) |> on_lane(network.pipeline)
    end
  end

  def lane_parse(_settings, _packet), do: :error

  @impl PortBackend
  def lane_reply_tag(settings, lane) do
    case network_of(settings, lane) do
      {%{kind: :detection}, _index} -> :inference_detections
      {%{kind: :segmentation}, _index} -> :inference_labels
    end
  end

  defp network_of(settings, lane),
    do:
      settings.networks
      |> Enum.with_index()
      |> Enum.find(fn {network, _index} -> network.pipeline == lane end)

  defp parse(wire, packet), do: wire.parse(packet)

  defp wire(%{kind: :detection}), do: DetectionWire
  defp wire(%{kind: :segmentation}), do: SegmentationWire

  defp on_lane({:ok, sequence, result, time_us}, lane), do: {:ok, lane, sequence, result, time_us}
  defp on_lane({:cut_short, sequence}, lane), do: {:cut_short, lane, sequence}
  defp on_lane(:error, _lane), do: :error

  defp default_executable_path, do: :vision_core |> :code.priv_dir() |> Path.join("hailo")
end
