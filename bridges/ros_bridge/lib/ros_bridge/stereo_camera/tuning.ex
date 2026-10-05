defmodule RosBridge.StereoCamera.Tuning do
  @moduledoc """
  Runtime tuning of a stereo unit over ROS: camera controls and stereo
  matching settings, changed while the bridge runs.

  Listens on `<topic_prefix>/set_controls` (`std_msgs/String`). Each
  message holds one or more `target.key=value` assignments, separated
  by spaces, semicolons or new lines:

      cameras.exposure_mode=short left.lens_position=1.2
      stereo.uniqueness_ratio=20; stereo.clahe_clip_limit=3

  Targets are `left`, `right`, `cameras` (both) and `stereo`. Camera
  keys are `RosBridge.Camera.LibCamera`'s runtime controls, stereo keys
  `RosBridge.StereoCamera.OpenCV.set_options/2`'s. A message is applied
  only if every assignment in it is accepted.

  Publishes the settings in force on `<topic_prefix>/controls`
  (`std_msgs/String`, one `target.key=value` per line, then the outcome
  of the last request) after each request and every few seconds, so a
  late viewer sees them.

  Changes last until the stereo unit restarts: the vehicle's
  configuration stays the reference, and good values are copied back
  into it.
  """

  use GenServer
  require Logger

  alias Ros2.StdMsgs.Msg.String, as: RosString
  alias RosBridge.StereoCamera.OpenCV

  @status_period_ms 2_000
  @targets %{"left" => [:left], "right" => [:right], "cameras" => [:left, :right]}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    prefix = Keyword.fetch!(opts, :topic_prefix)
    driver = Keyword.fetch!(opts, :driver)
    Code.ensure_loaded(driver)

    state = %{
      driver: driver,
      backend: Keyword.get(opts, :backend, OpenCV),
      status_topic: "#{prefix}/controls",
      last: "none"
    }

    :ok = RosBridge.ZenohClient.subscribe("#{prefix}/set_controls", RosString)
    Process.send_after(self(), :publish_status, @status_period_ms)
    Logger.info("#{__MODULE__} listening on #{prefix}/set_controls")
    {:ok, state}
  end

  @impl true
  def handle_info({:ros_message, {_key, %RosString{data: text}}}, state) do
    last =
      with {:ok, assignments} <- parse(text),
           :ok <- apply_assignments(assignments, state) do
        "ok: " <> String.trim(text)
      else
        {:error, reason} ->
          Logger.warning("#{__MODULE__}: #{reason}")
          "error: " <> reason
      end

    state = %{state | last: last}
    publish_status(state)
    {:noreply, state}
  end

  def handle_info(:publish_status, state) do
    publish_status(state)
    Process.send_after(self(), :publish_status, @status_period_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  The assignments in `text` as `{target, key, value}`, targets expanded
  (`cameras` to `:left` and `:right`), or the first one that cannot be
  read. Keys and enumerated values must name existing atoms. Pure.
  """
  def parse(text) do
    text
    |> String.split(~r/[\s;]+/, trim: true)
    |> Enum.reduce_while({:ok, []}, fn assignment, {:ok, acc} ->
      case parse_assignment(assignment) do
        {:ok, parsed} -> {:cont, {:ok, acc ++ parsed}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, []} -> {:error, "no assignment in #{inspect(text)}"}
      result -> result
    end
  end

  defp parse_assignment(assignment) do
    with [target_key, raw] <- String.split(assignment, "=", parts: 2),
         [target, key] <- String.split(target_key, ".", parts: 2),
         {:ok, targets} <- targets(target),
         {:ok, key} <- existing_atom(key),
         {:ok, value} <- value(raw) do
      {:ok, Enum.map(targets, &{&1, key, value})}
    else
      {:error, _} = error -> error
      _ -> {:error, "expected target.key=value, got #{inspect(assignment)}"}
    end
  end

  defp targets("stereo"), do: {:ok, [:stereo]}

  defp targets(target) do
    case Map.fetch(@targets, target) do
      {:ok, targets} -> {:ok, targets}
      :error -> {:error, "unknown target #{inspect(target)}: left, right, cameras or stereo"}
    end
  end

  defp value("true"), do: {:ok, true}
  defp value("false"), do: {:ok, false}

  defp value(raw) do
    case Integer.parse(raw) do
      {integer, ""} ->
        {:ok, integer}

      _ ->
        case Float.parse(raw) do
          {float, ""} -> {:ok, float}
          _ -> existing_atom(raw)
        end
    end
  end

  defp existing_atom(raw) do
    {:ok, String.to_existing_atom(raw)}
  rescue
    ArgumentError -> {:error, "unknown name #{inspect(raw)}"}
  end

  # Every target's settings are checked before any is applied, so a
  # message is applied whole or not at all.
  defp apply_assignments(assignments, state) do
    grouped = Enum.group_by(assignments, &elem(&1, 0), fn {_, key, value} -> {key, value} end)

    with :ok <- check(grouped, state) do
      Enum.each(grouped, fn {target, settings} -> {:ok, _} = set(target, settings, state) end)
    end
  end

  defp check(grouped, state) do
    Enum.find_value(grouped, :ok, fn
      {:stereo, settings} ->
        case OpenCV.validate_options(settings) do
          :ok -> nil
          error -> error
        end

      {_camera, settings} ->
        cond do
          not function_exported?(state.driver, :set_controls, 2) ->
            {:error, "#{inspect(state.driver)} has no runtime controls"}

          function_exported?(state.driver, :control_commands, 1) ->
            case state.driver.control_commands(settings) do
              {:ok, _} -> nil
              error -> error
            end

          true ->
            nil
        end
    end)
  end

  defp set(:stereo, settings, state), do: OpenCV.set_options(state.backend, settings)

  defp set(camera, settings, state),
    do: state.driver.set_controls(state.driver.name_for(Atom.to_string(camera)), settings)

  defp publish_status(state) do
    lines =
      camera_lines(:left, state) ++
        camera_lines(:right, state) ++ settings_lines("stereo", OpenCV.options(state.backend))

    message = %RosString{data: Enum.join(lines ++ ["last: " <> state.last], "\n")}
    RosBridge.ZenohClient.publish(state.status_topic, RosString, message)
  end

  defp camera_lines(camera, state) do
    if function_exported?(state.driver, :controls, 1),
      do:
        settings_lines(
          Atom.to_string(camera),
          state.driver.controls(state.driver.name_for(Atom.to_string(camera)))
        ),
      else: []
  end

  defp settings_lines(target, settings) do
    settings |> Enum.sort() |> Enum.map(fn {key, value} -> "#{target}.#{key}=#{value}" end)
  end
end
