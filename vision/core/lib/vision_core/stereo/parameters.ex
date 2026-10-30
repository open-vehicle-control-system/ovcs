defmodule VisionCore.Stereo.Parameters do
  @moduledoc """
  Declares a stereo unit's parameter groups in `VisionCore.Parameters`,
  under its topic prefix `<prefix>`:

    * `<prefix>.cameras` — the capture settings, for a driver whose one set
      of controls drives both cameras (`c:VisionCore.Camera.shared_controls?/0`),
      with the capture size, frame rate and each side's addressing as build
      parameters. Exposure and gain are set by auto exposure while it is on,
      and then read what the sensors apply.
    * `<prefix>.<stage>` — each stage of `VisionCore.Stereo.Pipeline`, in
      pipeline order, with its settings; Rectify also carries the matching
      size.
    * `<prefix>.alignment.correction` — switches
      `VisionCore.Stereo.AlignmentCorrection` on or off while it runs; it
      then sets Rectify's `right_row_offset`. The alignment group's status
      is the row offset `VisionCore.Status` measures.

  Declares nothing when the registry is not running.
  """
  use GenServer

  alias VisionCore.Stereo.{AlignmentCorrection, Pipeline}

  @side_keys [:device, :sync, :sensor_mode]
  @half_row 0.5

  @doc """
  Declares the unit's groups. Options: `:topic_prefix`, `:driver`,
  `:pipeline` (`VisionCore.Stereo.Pipeline`), `:left`, `:right`, `:width`,
  `:height`, `:fps`, `:match_width` and `:match_height`.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    if Process.whereis(VisionCore.Parameters),
      do: :ok = VisionCore.Parameters.declare(groups(opts))

    {:ok, nil}
  end

  @doc "The unit's group declarations for `opts`; see `start_link/1`."
  @spec groups(keyword()) :: [VisionCore.Parameters.group_declaration()]
  def groups(opts) do
    prefix = Keyword.fetch!(opts, :topic_prefix)
    pipeline = Keyword.get(opts, :pipeline, Pipeline)
    correction? = Process.whereis(AlignmentCorrection) != nil

    stages =
      pipeline
      |> Pipeline.stage_options()
      |> Enum.with_index(1)
      |> Enum.map(fn {stage, position} ->
        stage_group(prefix, pipeline, stage, position, opts, correction?)
      end)

    camera_groups(prefix, opts) ++ stages
  end

  defp camera_groups(prefix, opts) do
    driver = Keyword.fetch!(opts, :driver)
    Code.ensure_loaded(driver)

    if function_exported?(driver, :shared_controls?, 0) and driver.shared_controls?() do
      id = "#{prefix}.cameras"
      server = driver.name_for("left")

      [
        %{
          id: id,
          name: "Cameras",
          summary: "Capture settings, applied to both cameras.",
          kind: :component,
          placement: :flow,
          position: 0,
          parameters:
            Enum.map(driver.control_specs(), &control(&1, driver, server, id)) ++
              camera_build_parameters(opts)
        }
      ]
    else
      []
    end
  end

  defp control(spec, driver, server, group_id) do
    %{
      name: Atom.to_string(spec.key),
      type: spec.type,
      get: control_get(spec.key, driver, server),
      set: &ok(driver.set_controls(server, [{spec.key, &1}])),
      constraint: control_constraint(spec),
      applies: control_applies(spec.key, group_id),
      description: spec.description,
      export: [:components, :stereo, :left, spec.key]
    }
  end

  defp control_get(key, driver, server) when key in [:exposure_us, :analogue_gain] do
    fn ->
      controls = driver.controls(server)
      applied = controls.auto_exposure && live(driver, server)
      if applied, do: applied[live_key(key)] || controls[key], else: controls[key]
    end
  end

  defp control_get(key, driver, server), do: fn -> driver.controls(server)[key] end

  defp live(driver, server) do
    if function_exported?(driver, :live, 1), do: driver.live(server)
  end

  defp live_key(:exposure_us), do: :exposure_time_us
  defp live_key(:analogue_gain), do: :analogue_gain

  defp control_constraint(%{key: :rotation}), do: %{kind: :choices, values: [0, 180]}
  defp control_constraint(spec), do: constraint(spec)

  defp control_applies(key, group_id) when key in [:exposure_us, :analogue_gain],
    do: {:auto, "#{group_id}.auto_exposure"}

  defp control_applies(_key, _group_id), do: :live

  defp camera_build_parameters(opts) do
    general =
      for key <- [:width, :height, :fps], Keyword.has_key?(opts, key), do: {key, opts[key]}

    sides =
      for side <- [:left, :right],
          {key, value} <- Keyword.get(opts, side, []),
          key in @side_keys,
          do: {:"#{side}_#{key}", value}

    Enum.map(general ++ sides, &build_parameter/1)
  end

  defp stage_group(prefix, pipeline, stage, position, opts, correction?) do
    id = "#{prefix}.#{stage.stage}"

    parameters =
      Enum.map(stage.specs, fn {key, spec} ->
        stage_parameter(pipeline, stage.stage, key, spec, prefix, correction?)
      end)

    %{
      id: id,
      name: humanise(stage.stage),
      summary: stage.summary,
      kind: :stage,
      placement: :flow,
      position: position,
      parameters: parameters ++ extra_parameters(stage.stage, opts, correction?)
    }
    |> Map.merge(extra_group_fields(stage.stage))
  end

  defp stage_parameter(pipeline, stage, key, spec, prefix, correction?) do
    %{
      name: Atom.to_string(key),
      type: spec.type,
      get: fn -> stage_value(pipeline, stage, key) end,
      set: &ok(Pipeline.set_options(pipeline, stage, [{key, &1}])),
      constraint: constraint(spec),
      applies: stage_applies(stage, key, spec, prefix, correction?),
      export: [:components, :stereo, :stages, stage, key]
    }
    |> put_present(:greater_than, spec[:greater_than] && Atom.to_string(spec.greater_than))
    |> put_present(:description, spec[:description])
  end

  defp stage_value(pipeline, stage, key) do
    pipeline
    |> Pipeline.stage_options()
    |> Enum.find(&(&1.stage == stage))
    |> get_in([:values, key])
  end

  defp stage_applies(:rectify, :right_row_offset, _spec, prefix, true),
    do: {:auto, "#{prefix}.alignment.correction"}

  defp stage_applies(_stage, _key, spec, _prefix, _correction?),
    do: Map.get(spec, :applies, :live)

  defp extra_parameters(:rectify, opts, _correction?) do
    for key <- [:match_width, :match_height], Keyword.has_key?(opts, key) do
      build_parameter({key, opts[key]})
    end
  end

  defp extra_parameters(:alignment, _opts, true) do
    [
      %{
        name: "correction",
        type: :bool,
        get: fn -> AlignmentCorrection.enabled?() end,
        set: &AlignmentCorrection.set_enabled/1,
        constraint: %{kind: :bool},
        description:
          "Keep the rows lined up by moving the right image; off, right_row_offset stays as set",
        export: [:components, :stereo, :align_correction]
      }
    ]
  end

  defp extra_parameters(_stage, _opts, _correction?), do: []

  defp extra_group_fields(:alignment), do: %{status: &alignment_status/0}
  defp extra_group_fields(_stage), do: %{}

  defp alignment_status do
    with pid when is_pid(pid) <- Process.whereis(VisionCore.Status),
         %{alignment: %{offset_rows: offset}} when is_number(offset) <-
           VisionCore.Status.snapshot() do
      rows = Float.round(offset * 1.0, 2)

      if abs(rows) > @half_row,
        do: {:warning, "rows off by #{rows}"},
        else: {:ok, "#{rows} rows"}
    else
      _no_measurement -> nil
    end
  end

  defp constraint(%{type: :bool}), do: %{kind: :bool}
  defp constraint(%{values: values}), do: %{kind: :choices, values: values}

  defp constraint(%{range: {min, max}} = spec),
    do: %{kind: :range, min: min, max: max, step: spec[:step]}

  defp build_parameter({key, value}) do
    {type, value} = parameter_value(value)

    %{
      name: Atom.to_string(key),
      type: type,
      get: fn -> value end,
      applies: :build,
      description: "Fixed at start"
    }
  end

  defp parameter_value(value) when is_integer(value), do: {:integer, value}
  defp parameter_value(value) when is_float(value), do: {:double, value}
  defp parameter_value(value) when is_boolean(value), do: {:bool, value}
  defp parameter_value({width, height}), do: {:string, "#{width}x#{height}"}
  defp parameter_value(value) when is_atom(value), do: {:string, Atom.to_string(value)}
  defp parameter_value(value), do: {:string, to_string(value)}

  defp humanise(stage),
    do: stage |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp ok({:ok, _values}), do: :ok
  defp ok({:error, _reason} = error), do: error
end
