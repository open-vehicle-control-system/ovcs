defmodule VisionCore.Calibration.Recorder do
  @moduledoc """
  Keeps `VisionCore.Calibration.Library` in step with the calibration
  files of each target of the unit.

  At start, and at each change a target's calibration publishes
  (`VisionCore.Calibration.changed_key/1`), it reads the calibration in
  use. A stored one is selected in the library, where it is kept first
  when no calibration there holds its figures; a target back on the
  firmware's calibration, or on none, has no selection, as has one whose
  stored calibration the library cannot keep. A calibration found in the
  store that the library does not know, as one committed by
  `cameracalibrator` or stored before the library existed, is kept as
  `imported`.

  A commit that knows more tells the recorder beforehand, with
  `expect/3`: the calibrations it is about to store, and
  `{:record, options}`, the `VisionCore.Calibration.Library.record/3`
  options to keep them with, or `{:select, id}`, the calibration to
  select among those holding the same figures. What is expected is used
  by the change of the target that stores those calibrations, so that
  commits in flight each keep their own, and dropped by `forget/1`, or
  when the process that expected it ends.

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
  @type cameras :: [{String.t(), VisionCore.Ros2.CameraCalibration.t()}]

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

  @doc """
  Announces that the calling process is about to commit `cameras`, each
  camera's name and calibration, as `target`'s, and how to keep them.
  Answers the reference `forget/1` takes, also without a recorder
  running.
  """
  @spec expect(String.t(), cameras(), expected()) :: reference()
  def expect(target, cameras, expected) do
    expectation = %{
      reference: make_ref(),
      owner: self(),
      target: target,
      cameras: Enum.sort(cameras),
      expected: expected
    }

    call({:expect, expectation})
    expectation.reference
  end

  @doc "Drops what `expect/3` announced under `reference`, when no change has used it."
  @spec forget(reference()) :: :ok
  def forget(reference), do: call({:forget, reference})

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

    state = %{config: config, targets: targets, expectations: []}
    {:ok, Enum.reduce(targets, state, &sync(&2, &1.id))}
  end

  @impl GenServer
  def handle_call({:expect, expectation}, _from, state) do
    expectation = Map.put(expectation, :monitor, Process.monitor(expectation.owner))
    {:reply, :ok, %{state | expectations: state.expectations ++ [expectation]}}
  end

  def handle_call({:forget, reference}, _from, state),
    do: {:reply, :ok, drop_expectations(state, &(&1.reference == reference))}

  @impl GenServer
  def handle_cast({:stereo_calibration_changed, prefix}, state),
    do: {:noreply, sync(state, prefix)}

  def handle_cast({:camera_calibration_changed, name}, state),
    do: {:noreply, sync(state, target_of(state, name))}

  def handle_cast(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _owner, _reason}, state),
    do: {:noreply, drop_expectations(state, &(&1.monitor == monitor))}

  def handle_info(_message, state), do: {:noreply, state}

  defp drop_expectations(state, dropped?) do
    {dropped, kept} = Enum.split_with(state.expectations, dropped?)
    for %{monitor: monitor} <- dropped, do: Process.demonitor(monitor, [:flush])
    %{state | expectations: kept}
  end

  defp target_of(state, name),
    do: Enum.find_value(state.targets, &(&1.kind == :camera and &1.name == name and &1.id))

  defp sync(state, nil), do: state

  defp sync(state, target) do
    state =
      case Calibration.in_use(state.config, target) do
        {:ok, %{source: :stored} = in_use} ->
          select_stored(state, target, in_use)

        {:ok, _in_use} ->
          report(target, Library.select(target, nil))
          state

        {:error, reason} ->
          report(target, {:error, inspect(reason)})
          state
      end

    changed(target)
    state
  end

  defp select_stored(state, target, in_use) do
    cameras =
      for %{name: name, calibration: calibration} <- in_use.cameras, do: {name, calibration}

    if Enum.any?(cameras, fn {_name, calibration} -> is_nil(calibration) end) do
      select_none(target, "a stored file gives no calibration")
      state
    else
      {expected, state} = pop_expected(state, target, cameras)
      keep_stored(target, cameras, in_use, expected)
      state
    end
  end

  # What the commit of these calibrations announced, the oldest first; `nil` when none did.
  defp pop_expected(state, target, cameras) do
    stored = Enum.sort(cameras)

    case Enum.find(state.expectations, &(&1.target == target and &1.cameras == stored)) do
      nil ->
        {nil, state}

      %{reference: reference, expected: expected} ->
        {expected, drop_expectations(state, &(&1.reference == reference))}
    end
  end

  defp keep_stored(target, cameras, in_use, expected) do
    case kept(target, cameras, in_use, expected) do
      {:ok, saved} -> report(target, Library.select(target, saved.id))
      {:error, reason} -> select_none(target, reason)
    end
  end

  # The target runs on a calibration the library does not hold: none of those it holds is selected.
  defp select_none(target, reason) do
    report(target, {:error, reason})
    report(target, Library.select(target, nil))
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
