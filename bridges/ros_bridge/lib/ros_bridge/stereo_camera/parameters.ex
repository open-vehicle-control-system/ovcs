defmodule RosBridge.StereoCamera.Parameters do
  @moduledoc """
  A stereo unit's settings as ROS 2 parameters of the bridge's node
  (`RosBridge.Parameters`), named under its topic prefix:

    * `<prefix>.<side>.<control>` — each camera's runtime controls, from
      the driver's `control_specs/0` (`RosBridge.Camera.LibCamera`)
    * `<prefix>.<setting>` — the matching settings, from
      `RosBridge.StereoCamera.OpenCV.option_specs/0`
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

  alias RosBridge.StereoCamera.OpenCV

  @startup_keys [:camera_id, :device, :sync, :sensor_mode, :rotation, :calibration_path]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    :ok = RosBridge.Parameters.declare(declarations(opts))
    {:ok, nil}
  end

  @doc false
  def declarations(opts) do
    prefix = Keyword.fetch!(opts, :topic_prefix)
    driver = Keyword.fetch!(opts, :driver)
    backend = Keyword.get(opts, :backend, OpenCV)
    Code.ensure_loaded(driver)

    camera_parameters(prefix, driver, :left) ++
      camera_parameters(prefix, driver, :right) ++
      matching_parameters(prefix, backend) ++
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
          set: &applied(driver.set_controls(server, [{spec.key, &1}]))
        })
      end
    else
      []
    end
  end

  defp matching_parameters(prefix, backend) do
    values = OpenCV.options(backend)

    for {key, spec} <- OpenCV.option_specs() do
      Map.merge(spec, %{
        name: "#{prefix}.#{key}",
        value: values[key],
        set: &applied(OpenCV.set_options(backend, [{key, &1}]))
      })
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

  defp applied({:ok, _}), do: :ok
  defp applied({:error, _} = error), do: error
end
