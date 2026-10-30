defmodule VisionCore.Stereo.Parameters do
  @moduledoc """
  Declares a stereo unit's parameter groups in `VisionCore.Parameters`,
  under its topic prefix `<prefix>`:

    * `<prefix>.cameras` — the capture settings, for a driver whose one set
      of controls drives both cameras (`c:VisionCore.Camera.shared_controls?/0`),
      with the capture size, frame rate and each side's addressing as build
      parameters. Exposure and gain are set by auto exposure while it is on,
      and then read what the sensors apply; their defaults are the manual
      settings.
    * `<prefix>.left_camera` and `<prefix>.right_camera` — the same, for a
      driver with controls per camera. Auto exposure and auto gain are
      switches of their own; exposure and gain are set by them while they are
      on, and then read what the sensor applies. Their defaults are the
      manual settings the composer gives the camera.
    * `<prefix>.<stage>` — each stage of `VisionCore.Stereo.Pipeline`, in
      pipeline order, with its settings; Rectify also carries the matching
      size.
    * `<prefix>.alignment.correction` — switches
      `VisionCore.Stereo.AlignmentCorrection` on or off while it runs and
      the pipeline has an Alignment stage; it
      then sets Rectify's `right_row_offset`. The alignment group's status
      is the row offset `VisionCore.Status` measures.

  Declares nothing when the registry is not running.
  """
  use GenServer

  alias VisionCore.Stereo.{AlignmentCorrection, Pipeline}

  @side_keys [:device, :sync, :sensor_mode]
  @half_row 0.5
  @side_build_keys [:camera_id, :sync, :sensor_mode]
  @manual_keys [:exposure_time_us, :analogue_gain]
  @auto_switch_of %{exposure_time_us: :auto_exposure, analogue_gain: :auto_gain}
  @auto_switches [
    {:auto_exposure, :exposure_time_us, "Let the camera choose the shutter time"},
    {:auto_gain, :analogue_gain, "Let the camera choose the analogue gain"}
  ]

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
    stage_options = Pipeline.stage_options(pipeline)

    # The correction is declared on the alignment stage's group, so it needs both.
    correction? =
      Process.whereis(AlignmentCorrection) != nil and
        Enum.any?(stage_options, &(&1.stage == :alignment))

    stages =
      stage_options
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
      controls = driver.controls(server)

      [
        %{
          id: id,
          name: "Cameras",
          summary: "Capture settings, applied to both cameras.",
          kind: :component,
          placement: :flow,
          position: 0,
          parameters:
            Enum.map(driver.control_specs(), &control(&1, driver, server, id, controls)) ++
              camera_build_parameters(opts, [:left, :right])
        }
      ]
    else
      side_camera_groups(prefix, driver, opts)
    end
  end

  defp side_camera_groups(prefix, driver, opts) do
    if function_exported?(driver, :control_specs, 0),
      do: Enum.map([:left, :right], &side_camera_group(prefix, driver, opts, &1)),
      else: []
  end

  defp side_camera_group(prefix, driver, opts, side) do
    id = "#{prefix}.#{side}_camera"
    server = driver.name_for(Atom.to_string(side))
    configured = Keyword.get(opts, side, [])

    %{
      id: id,
      name: "#{humanise(side)} camera",
      summary: "Capture settings of the #{side} camera.",
      kind: :component,
      placement: :flow,
      position: 0,
      parameters:
        Enum.map(@auto_switches, &auto_switch(&1, driver, server)) ++
          Enum.map(
            driver.control_specs(),
            &side_control(&1, driver, server, id, side, configured)
          ) ++ side_build_parameters(opts, side)
    }
  end

  defp side_build_parameters(opts, side) do
    general = camera_build_parameters(opts, [])

    own =
      for {key, value} <- Keyword.get(opts, side, []), key in @side_build_keys, do: {key, value}

    general ++ Enum.map(own, &build_parameter/1)
  end

  defp auto_switch({name, key, description}, driver, server) do
    %{
      name: Atom.to_string(name),
      type: :bool,
      get: fn -> automatic_value?(driver.controls(server)[key]) end,
      set: &automatic_set(&1, driver, server, key),
      constraint: %{kind: :bool},
      description: description
    }
  end

  # Off is applied by the registry setting the controlled value first.
  defp automatic_set(true, driver, server, key), do: ok(driver.set_controls(server, [{key, 0}]))
  defp automatic_set(false, _driver, _server, _key), do: :ok

  defp automatic_value?(value), do: is_nil(value) or value == 0

  defp side_control(spec, driver, server, group_id, side, configured) do
    %{
      name: Atom.to_string(spec.key),
      type: spec.type,
      get: side_get(spec.key, driver, server, configured[spec.key]),
      set: &ok(driver.set_controls(server, [{spec.key, &1}])),
      constraint: side_constraint(spec),
      applies: side_applies(spec.key, group_id),
      description: side_description(spec),
      export: [:components, :stereo, side, spec.key]
    }
    |> put_configured_default(spec.key, configured[spec.key])
  end

  # While automatic and nothing is live, the manual setting (never 0): releasing it keeps the camera's value.
  defp side_get(key, driver, server, configured) when key in @manual_keys do
    fn ->
      value = driver.controls(server)[key]

      if automatic_value?(value) do
        applied = live(driver, server)
        (applied && applied[key]) || manual_value(configured)
      else
        value
      end
    end
  end

  defp side_get(key, driver, server, _configured), do: fn -> driver.controls(server)[key] end

  defp manual_value(configured), do: if(automatic_value?(configured), do: 1, else: configured)

  defp side_applies(key, group_id) when key in @manual_keys,
    do: {:auto, "#{group_id}.#{@auto_switch_of[key]}"}

  defp side_applies(_key, _group_id), do: :live

  # 0 is how the driver is told to go automatic, so a manual value starts at 1.
  defp side_constraint(%{key: :exposure_time_us}),
    do: %{kind: :range, min: 1, max: 1_000_000, step: nil}

  defp side_constraint(%{key: :analogue_gain}), do: %{kind: :range, min: 1, max: 16, step: nil}
  defp side_constraint(spec), do: constraint(spec)

  defp side_description(%{key: :exposure_time_us}),
    do: "Shutter time in microseconds; set by auto exposure while it is on"

  defp side_description(%{key: :analogue_gain}),
    do: "Analogue gain; set by auto gain while it is on"

  defp side_description(spec), do: spec.description

  defp put_configured_default(declaration, key, value) when key in @manual_keys do
    if automatic_value?(value), do: declaration, else: Map.put(declaration, :default, value)
  end

  defp put_configured_default(declaration, _key, _value), do: declaration

  defp control(spec, driver, server, group_id, controls) do
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
    |> put_manual_default(spec.key, controls)
  end

  # Auto exposure's first values are not the built-in ones: the manual settings are.
  defp put_manual_default(declaration, key, controls) when key in [:exposure_us, :analogue_gain],
    do: put_present(declaration, :default, controls[key])

  defp put_manual_default(declaration, _key, _controls), do: declaration

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

  defp camera_build_parameters(opts, sides) do
    general =
      for key <- [:width, :height, :fps], Keyword.has_key?(opts, key), do: {key, opts[key]}

    per_side =
      for side <- sides,
          {key, value} <- Keyword.get(opts, side, []),
          key in @side_keys,
          do: {:"#{side}_#{key}", value}

    Enum.map(general ++ per_side, &build_parameter/1)
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

  @doc "A build parameter declaration for `{key, value}`: read-only, fixed at start."
  @spec build_parameter({atom(), term()}) :: VisionCore.Parameters.declaration()
  def build_parameter({key, value}) do
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

  defp humanise(name),
    do: name |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp ok({:ok, _values}), do: :ok
  defp ok({:error, _reason} = error), do: error
end
