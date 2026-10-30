defmodule VisionCore.Stereo.AlignmentCorrection do
  @moduledoc """
  Keeps the rectified images on the same rows when the cameras shift a
  little after their calibration: reads the row offset
  (`VisionCore.Stereo.Stage.Alignment`) from each `VisionCore.Status`
  tick, and when the median of the last five stays beyond a tenth of a
  row, moves the right image through the Rectify stage's
  `right_row_offset`, up to six rows. On a real scene the measurement
  reads about half of the true offset, so each correction moves one and
  a half times the reading; it then waits for five fresh measurements
  before it corrects again, so a moving scene or one odd measurement
  does not steer it.

  It can be switched off while running (`set_enabled/2`, the
  `<prefix>.alignment_correction` parameter), so a `right_row_offset` set
  by hand stays.

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

  @impl GenServer
  def init(opts) do
    pipeline = Keyword.get(opts, :pipeline, Pipeline)
    if Keyword.get(opts, :subscribe, true), do: send(self(), :subscribe)

    {:ok,
     %{
       enabled: Keyword.get(opts, :enabled, true),
       offsets: [],
       current_offset:
         Keyword.get(opts, :current_offset, fn ->
           Pipeline.options(pipeline).right_row_offset
         end),
       set_offset:
         Keyword.get(opts, :set_offset, fn rows ->
           with {:ok, _options} <- Pipeline.set_options(pipeline, right_row_offset: rows),
                do: :ok
         end)
     }}
  end

  @impl GenServer
  def handle_call(:enabled?, _from, state), do: {:reply, state.enabled, state}

  def handle_call({:set_enabled, enabled}, _from, state),
    do: {:reply, :ok, %{state | enabled: enabled, offsets: []}}

  @impl GenServer
  def handle_info(:subscribe, state) do
    :ok = Status.subscribe()
    {:noreply, state}
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

  def handle_info(_message, state), do: {:noreply, state}

  defp correct(state, offset) do
    current = state.current_offset.()
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
end
