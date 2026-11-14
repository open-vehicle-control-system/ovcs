defmodule VisionCore.Calibration.Recorder do
  @moduledoc """
  Keeps `VisionCore.Calibration.Library` in step with the calibration
  files of each target of the unit.

  At start, and at each change a target's calibration publishes
  (`VisionCore.Calibration.changed_key/1`), it reads the calibration in
  use. A stored one is selected in the library, where it is kept first
  when no calibration there holds its figures; a target back on the
  firmware's calibration, or on none, has no selection. A calibration
  found in the store that the library does not know, as one committed by
  `cameracalibrator` or stored before the library existed, is kept as
  `imported`.

  A commit that knows more tells the recorder beforehand, with
  `expect/2`: `{:record, options}`, the `VisionCore.Calibration.Library.record/3`
  options to keep the calibration with, or `{:select, id}`, the
  calibration to select among those holding the same figures. What is
  expected is used by the target's next change, and dropped by
  `forget/1` when the commit did not happen.

  Each change of a target's library is published as
  `{:saved_calibrations_changed, target}` under `changed_key/1`.

  ## Options

    * `:config` — the active `VisionCore.Config`, required.
    * `:name` — the registered name, by default the module.
  """
  use GenServer

  require Logger

  alias VisionCore.Calibration
  alias VisionCore.Calibration.Library
  alias VisionCore.Outputs

  @type expected :: {:record, keyword()} | {:select, integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The `VisionCore.Outputs` key a change of the library of `target` is published under."
  @spec changed_key(String.t()) :: {:saved_calibrations, String.t()}
  def changed_key(target), do: {:saved_calibrations, target}

  @doc "Publishes a change of the library of `target`, as a rename or a removal."
  @spec changed(String.t()) :: :ok
  def changed(target),
    do: Outputs.publish(changed_key(target), {:saved_calibrations_changed, target})

  @doc "What the next change of `target`'s calibration is; `:ok` without a recorder running."
  @spec expect(String.t(), expected()) :: :ok
  def expect(target, expected), do: call({:expect, target, expected})

  @doc "Drops what `expect/2` announced for `target`."
  @spec forget(String.t()) :: :ok
  def forget(target), do: call({:forget, target})

  defp call(request) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      recorder -> GenServer.call(recorder, request)
    end
  end

  @impl GenServer
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    targets = Calibration.targets(config)
    Enum.each(targets, &Outputs.subscribe(Calibration.changed_key(&1)))

    state = %{config: config, targets: targets, expected: %{}}
    {:ok, Enum.reduce(targets, state, &sync(&2, &1.id))}
  end

  @impl GenServer
  def handle_call({:expect, target, expected}, _from, state),
    do: {:reply, :ok, put_in(state.expected[target], expected)}

  def handle_call({:forget, target}, _from, state),
    do: {:reply, :ok, %{state | expected: Map.delete(state.expected, target)}}

  @impl GenServer
  def handle_cast({:stereo_calibration_changed, prefix}, state),
    do: {:noreply, sync(state, prefix)}

  def handle_cast({:camera_calibration_changed, name}, state),
    do: {:noreply, sync(state, target_of(state, name))}

  def handle_cast(_message, state), do: {:noreply, state}

  defp target_of(state, name),
    do: Enum.find_value(state.targets, &(&1.kind == :camera and &1.name == name and &1.id))

  defp sync(state, nil), do: state

  defp sync(state, target) do
    {expected, others} = Map.pop(state.expected, target)

    case Calibration.in_use(state.config, target) do
      {:ok, %{source: :stored} = in_use} -> select_stored(target, in_use, expected)
      {:ok, _in_use} -> report(target, Library.select(target, nil))
      {:error, reason} -> report(target, {:error, inspect(reason)})
    end

    changed(target)
    %{state | expected: others}
  end

  defp select_stored(target, in_use, expected) do
    cameras =
      for %{name: name, calibration: calibration} <- in_use.cameras, do: {name, calibration}

    if Enum.any?(cameras, fn {_name, calibration} -> is_nil(calibration) end) do
      report(target, {:error, "a stored file gives no calibration"})
      report(target, Library.select(target, nil))
    else
      keep_stored(target, cameras, in_use, expected)
    end
  end

  defp keep_stored(target, cameras, in_use, expected) do
    case kept(target, cameras, in_use, expected) do
      {:ok, saved} -> report(target, Library.select(target, saved.id))
      {:error, reason} -> report(target, {:error, reason})
    end
  end

  defp kept(target, cameras, in_use, expected) do
    case {held(target, cameras, expected), expected} do
      {nil, {:record, options}} -> Library.record(target, cameras, with_baseline(options, in_use))
      {nil, _none} -> Library.record(target, cameras, with_baseline(imported(in_use), in_use))
      {saved, _expected} -> {:ok, saved}
    end
  end

  # The calibration to select among those of the target that hold the stored figures.
  defp held(target, cameras, {:select, id}) do
    with {:ok, %{target: ^target} = saved} <- Library.fetch(id),
         true <- Library.holds?(saved, cameras) do
      saved
    else
      _other -> Library.holding(target, cameras)
    end
  end

  defp held(target, cameras, _expected), do: Library.holding(target, cameras)

  # Dated from its files: the unit's clock may not be set yet when it starts.
  defp imported(%{stored_at: %DateTime{} = stored_at}), do: [origin: "imported", at: stored_at]
  defp imported(_in_use), do: [origin: "imported"]

  defp with_baseline(options, in_use),
    do: Keyword.put_new(options, :baseline_m, in_use.baseline_m)

  defp report(_target, :ok), do: :ok

  defp report(target, {:error, reason}),
    do: Logger.warning("#{__MODULE__} could not keep the calibration of #{target}: #{reason}")
end
