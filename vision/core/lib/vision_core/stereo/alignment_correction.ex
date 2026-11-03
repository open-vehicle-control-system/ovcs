defmodule VisionCore.Stereo.AlignmentCorrection do
  @moduledoc """
  Keeps the rectified images on the same rows when the cameras shift a
  little after their calibration: reads the row offset from each
  `VisionCore.Status` tick, as the stage that provides the pair's
  `:alignment` measures it (`alignment_stage/1`,
  `VisionCore.Stereo.Stage.RowAlignment` by default), and when the
  median of the last few stays beyond a threshold, moves the right image
  through the `right_row_offset` of the stage that declares that setting
  (`offset_stage/1`, `VisionCore.Stereo.Stage.Rectification` by
  default), within a limit. Both are found by what they declare, not by
  name, and a stage list has at most one of each (`check_stages!/1`). On
  a real scene the measurement reads short of the true offset, so each
  correction moves further than the reading; it then waits for as many
  fresh measurements before it corrects again, so a moving scene or one
  odd measurement does not steer it.

  It can be switched off while running (`set_enabled/2`, the
  `auto_row_offset` parameter next to `right_row_offset`,
  `<prefix>.rectification.auto_row_offset` with the default stages), so
  a `right_row_offset` set by hand stays.

  It corrects only rows: a camera that moved sideways changes every
  disparity by the same amount, which matching cannot see, so the depth
  stays off until the cameras are recalibrated.
  """
  use GenServer
  require Logger

  alias VisionCore.Status
  alias VisionCore.Stereo.Pipeline

  @window 5
  @threshold_rows 0.1
  @gain 1.5
  @max_rows 6.0
  @subscribe_retry_ms 1_000

  @doc """
  Starts the correction. Options: `:pipeline` (`VisionCore.Stereo.Pipeline`),
  `:enabled` (`true`) and `:name` (`__MODULE__`, `nil` for none).
  """
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Whether the correction is switched on."
  @spec enabled?(GenServer.server()) :: boolean()
  def enabled?(server \\ __MODULE__), do: GenServer.call(server, :enabled?)

  @doc "Switches the correction on or off; on, it starts from fresh measurements."
  @spec set_enabled(GenServer.server(), boolean()) :: :ok
  def set_enabled(server \\ __MODULE__, enabled) when is_boolean(enabled),
    do: GenServer.call(server, {:set_enabled, enabled})

  @doc """
  The stage among `stages`, as `VisionCore.Stereo.Pipeline.stage_options/1`
  lists them, whose rows the correction moves: the one that declares the
  setting `right_row_offset`. `nil` without one.
  """
  @spec offset_stage([Pipeline.stage_options()]) :: Pipeline.stage_options() | nil
  def offset_stage(stages), do: Enum.find(stages, &declares_offset?(&1.module))

  @doc """
  The stage among `stages`, as `VisionCore.Stereo.Pipeline.stage_options/1`
  lists them, whose measure the correction follows: the one that provides
  the pair's `:alignment`. `nil` without one.
  """
  @spec alignment_stage([Pipeline.stage_options()]) :: Pipeline.stage_options() | nil
  def alignment_stage(stages), do: Enum.find(stages, &provides_alignment?(&1.module))

  @doc """
  Raises when two modules among `stages`, the pipeline's `:stages`, declare
  `right_row_offset` or provide `:alignment`: the correction, a calibration
  reload and the unit's parameters address one stage of each. A module
  listed twice is left to `VisionCore.Stereo.Pipeline`, which refuses it.
  """
  @spec check_stages!([module() | {module(), keyword()}]) :: :ok
  def check_stages!(stages) do
    modules = stages |> Enum.flat_map(&stage_module/1) |> Enum.uniq()

    check_one!(
      modules,
      &declares_offset?/1,
      "declare right_row_offset: the row correction moves one stage's rows"
    )

    check_one!(
      modules,
      &provides_alignment?/1,
      "provide :alignment: the row correction follows one stage's measure"
    )
  end

  @impl GenServer
  def init(opts) do
    pipeline = Keyword.get(opts, :pipeline, Pipeline)
    if Keyword.get(opts, :subscribe, true), do: send(self(), :subscribe)

    {:ok,
     %{
       enabled: Keyword.get(opts, :enabled, true),
       offsets: [],
       status_monitor: nil,
       current_offset: Keyword.get(opts, :current_offset, fn -> current_offset(pipeline) end),
       set_offset: Keyword.get(opts, :set_offset, &set_offset(pipeline, &1))
     }}
  end

  @impl GenServer
  def handle_call(:enabled?, _from, state), do: {:reply, state.enabled, state}

  def handle_call({:set_enabled, enabled}, _from, state),
    do: {:reply, :ok, %{state | enabled: enabled, offsets: []}}

  @impl GenServer
  def handle_info(:subscribe, state) do
    :ok = Status.subscribe()
    {:noreply, %{state | status_monitor: Process.monitor(Status)}}
  catch
    :exit, _not_started ->
      Process.send_after(self(), :subscribe, @subscribe_retry_ms)
      {:noreply, state}
  end

  def handle_info(
        {:vision_status, %{alignment: %{offset_rows: offset}}},
        %{enabled: true} = state
      )
      when is_number(offset) do
    offsets = Enum.take([offset | state.offsets], @window)

    if length(offsets) == @window and abs(median(offsets)) > @threshold_rows do
      {:noreply, %{state | offsets: []} |> correct(median(offsets))}
    else
      {:noreply, %{state | offsets: offsets}}
    end
  end

  # A restarted status has no subscribers.
  def handle_info(
        {:DOWN, monitor, :process, _status, _reason},
        %{status_monitor: monitor} = state
      ) do
    send(self(), :subscribe)
    {:noreply, %{state | status_monitor: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp correct(state, offset) do
    case state.current_offset.() do
      # No right_row_offset to move the rows.
      nil -> state
      current -> correct(state, offset, current)
    end
  end

  defp correct(state, offset, current) do
    rows = (current + @gain * offset) |> max(-@max_rows) |> min(@max_rows)

    case state.set_offset.(rows) do
      :ok ->
        Logger.info(
          "#{__MODULE__}: rows off by #{Float.round(offset, 2)}, right image moved to #{Float.round(rows, 2)} rows"
        )

      error ->
        Logger.warning("#{__MODULE__}: could not move the right image: #{inspect(error)}")
    end

    state
  end

  defp median(values), do: values |> Enum.sort() |> Enum.at(div(length(values), 2))

  # Looked up at each correction: the pipeline need not run when the correction starts.
  defp current_offset(pipeline) do
    case pipeline |> Pipeline.stage_options() |> offset_stage() do
      nil -> nil
      stage -> stage.values[:right_row_offset]
    end
  end

  defp set_offset(pipeline, rows) do
    case pipeline |> Pipeline.stage_options() |> offset_stage() do
      nil ->
        {:error, "no stage declares right_row_offset"}

      stage ->
        with {:ok, _values} <-
               Pipeline.set_options(pipeline, stage.stage, right_row_offset: rows),
             do: :ok
    end
  end

  defp stage_module({module, _opts}) when is_atom(module), do: [module]
  defp stage_module(module) when is_atom(module), do: [module]
  defp stage_module(_stage), do: []

  defp check_one!(modules, declares?, refusal) do
    case Enum.filter(modules, declares?) do
      [first, second | _] ->
        raise ArgumentError, "#{inspect(first)} and #{inspect(second)} both #{refusal}"

      _one_or_none ->
        :ok
    end
  end

  defp declares_offset?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :option_specs, 0) and
      Keyword.has_key?(module.option_specs(), :right_row_offset)
  end

  defp provides_alignment?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :provides, 0) and
      :alignment in module.provides()
  end
end
