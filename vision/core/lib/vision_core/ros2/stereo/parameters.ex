defmodule VisionCore.Ros2.Stereo.Parameters do
  @moduledoc """
  A stereo unit's settings as ROS 2 parameters of the vision core's node
  (`VisionCore.Ros2.Parameters`), named under its topic prefix:

    * `<prefix>.<side>.<control>` — each camera's runtime controls, from
      the driver's `control_specs/0` (`VisionCore.Camera.LibCamera`)
    * `<prefix>.<stage>.<setting>` — the live settings of the pipeline's
      stages, from `VisionCore.Stereo.Pipeline.stage_options/1`
    * `<prefix>.preview.<setting>` — the dashboard previews' settings,
      from `VisionCore.Preview.option_specs/0`.
    * `<prefix>.alignment_correction` — switches
      `VisionCore.Stereo.AlignmentCorrection` on or off, while it runs
    * read-only, the settings fixed at start: each camera's addressing,
      sync role, sensor mode and calibration file, and the resolution
      and frame rate

  So `ros2 param set /<node> stereo.left.lens_position 1.2`, or
  Foxglove's Parameters panel, changes the running unit, and `ros2
  param dump /<node>` prints the values in force.

  Changes last until the stereo unit restarts: the vehicle's
  configuration stays the reference, and good values are copied back
  into it.
  """

  use GenServer

  alias VisionCore.Preview
  alias VisionCore.Stereo.{AlignmentCorrection, Pipeline}

  @startup_keys [:camera_id, :device, :sync, :sensor_mode, :rotation, :calibration_path]

  @doc "Declares the unit's parameters on the vision core's node; see the module doc."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    :ok = VisionCore.Ros2.Parameters.declare(declarations(opts))
    {:ok, nil}
  end

  @doc false
  def declarations(opts) do
    prefix = Keyword.fetch!(opts, :topic_prefix)
    driver = Keyword.fetch!(opts, :driver)
    pipeline = Keyword.get(opts, :pipeline, Pipeline)
    Code.ensure_loaded(driver)

    camera_parameters(prefix, driver, :left) ++
      camera_parameters(prefix, driver, :right) ++
      pipeline_parameters(prefix, pipeline) ++
      preview_parameters(prefix) ++
      alignment_correction_parameters(prefix) ++
      startup_parameters(prefix, opts)
  end

  defp camera_parameters(prefix, driver, side) do
    if function_exported?(driver, :control_specs, 0) do
      server = driver.name_for(Atom.to_string(side))
      values = driver.controls(server)

      for spec <- driver.control_specs() do
        spec
        |> Map.take([:type, :range, :values, :description])
        |> Map.merge(%{
          name: "#{prefix}.#{side}.#{spec.key}",
          value: values[spec.key],
          set: &drop_reply_value(driver.set_controls(server, [{spec.key, &1}]))
        })
      end
    else
      []
    end
  end

  defp pipeline_parameters(prefix, pipeline) do
    for %{stage: stage, specs: specs, values: values} <- Pipeline.stage_options(pipeline),
        {key, %{applies: :live} = spec} <- specs do
      spec
      |> Map.take([:type, :range, :values, :description])
      |> Map.merge(%{
        name: "#{prefix}.#{stage}.#{key}",
        value: values[key],
        set: &drop_reply_value(Pipeline.set_options(pipeline, stage, [{key, &1}]))
      })
    end
  end

  # The preview starts after the stereo unit: its settings start at their defaults.
  defp preview_parameters(prefix) do
    for {key, spec} <- Preview.option_specs() do
      spec
      |> Map.take([:type, :range, :description])
      |> Map.merge(%{
        name: "#{prefix}.preview.#{key}",
        value: spec.default,
        set: &drop_reply_value(Preview.set_options([{key, &1}]))
      })
    end
  end

  defp alignment_correction_parameters(prefix) do
    if Process.whereis(AlignmentCorrection) do
      [
        %{
          name: "#{prefix}.alignment_correction",
          type: :bool,
          value: AlignmentCorrection.enabled?(),
          description:
            "Keep the rows lined up by moving the right image; off, right_row_offset stays as set",
          set: &AlignmentCorrection.set_enabled/1
        }
      ]
    else
      []
    end
  end

  defp startup_parameters(prefix, opts) do
    sides =
      for side <- [:left, :right],
          {key, value} <- Keyword.get(opts, side, []),
          key in @startup_keys,
          do: {"#{prefix}.#{side}.#{key}", value}

    general =
      for key <- [:width, :height, :fps],
          Keyword.has_key?(opts, key),
          do: {"#{prefix}.#{key}", opts[key]}

    for {name, value} <- sides ++ general do
      {type, value} = parameter_value(value)
      %{name: name, type: type, value: value, read_only: true, description: "Fixed at start"}
    end
  end

  defp parameter_value(value) when is_integer(value), do: {:integer, value}
  defp parameter_value(value) when is_float(value), do: {:double, value}
  defp parameter_value(value) when is_boolean(value), do: {:bool, value}
  defp parameter_value({width, height}), do: {:string, "#{width}x#{height}"}
  defp parameter_value(value) when is_atom(value), do: {:string, Atom.to_string(value)}
  defp parameter_value(value), do: {:string, to_string(value)}

  defp drop_reply_value({:ok, _}), do: :ok
  defp drop_reply_value({:error, _} = error), do: error
end
