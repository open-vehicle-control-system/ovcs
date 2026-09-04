defmodule VmsCore.Components.OVCS.ROSControl.Throttle do
  @moduledoc """
  Control throttle/breaking based on ROS control's input.

  ## The throttle expires; it is not held

  `handle_frame` is the only thing that moves `raw_value`, and `emit/1`
  runs every 10 ms regardless. Without an expiry that combination
  means a ROS bridge which stops talking leaves the last commanded
  throttle applied *forever* — the vehicle keeps driving until
  something physical stops it. That is not a hypothetical: it is what
  happens when the bridge BEAM crashes, when Zenoh partitions, or when
  the CAN link is cut.

  So this component asks `Cantastic.ReceivedFrameWatcher` to tell it
  when `ros_control1` stops arriving, and zeroes the request when it
  does. `%{errors: true}` on the subscription is what opts into those
  events; the default is `false`, which is why nothing arrived before.

  Detection takes roughly 50 ms: the frame declares `frequency: 10`
  (Cantastic's `frequency` is a *period in milliseconds*, so 100 Hz),
  the watcher tolerates `allowed_frequency_leeway` of 10 ms on top, and
  needs `allowed_missing_frames` — 5 by default — consecutive late
  checks before it declares the frame dead. At 2 m/s that is about
  10 cm of travel.

  Recovery needs no code: the next frame to arrive sets `raw_value`
  again.

  ## Only the throttle expires

  `ROSControl.Steering` deliberately holds its last value rather than
  centring. Removing propulsion is what makes the vehicle safe;
  snapping the wheels straight mid-corner at speed is a new hazard
  rather than a mitigation, and it would be a violent input on OVCS1 in
  particular. It is also consistent with how a human takes over —
  `VmsCore.Managers.ControlLevel` switches the steering *source*, so
  this component's value stops being read at all.

  `ROSControl.Direction` is likewise untouched: direction is inert once
  throttle is zero.
  """
  use GenServer
  alias Cantastic.{Receiver, Frame, ReceivedFrameWatcher, Signal}
  alias Decimal, as: D
  alias OvcsBus, as: Bus

  require Logger

  @loop_period 10
  @zero D.new(0)
  @range 2 ** 31 - 1

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_) do
    # `%{errors: true}` subscribes to `handle_missing_frame` as well as
    # `handle_frame`; `enable/2` starts the watcher's timer. Both are
    # needed — see `Cantastic.ReceivedFrameWatcher`.
    :ok = Receiver.subscribe(self(), :ovcs, "ros_control1", %{errors: true})
    :ok = ReceivedFrameWatcher.enable(:ovcs, "ros_control1")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)

    {:ok,
     %{
       loop_timer: timer,
       raw_value: 0,
       requested_throttle: @zero
     }}
  end

  @impl true
  def handle_info(:loop, state) do
    state =
      state
      |> compute_throttle()
      |> emit()

    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: "ros_control1", signals: signals}}, state) do
    %{"throttle" => %Signal{name: "throttle", value: raw_value}} = signals
    {:noreply, %{state | raw_value: raw_value}}
  end

  # The watcher fires this once per outage, on the transition to dead,
  # so it does not need rate limiting.
  def handle_info({:handle_missing_frame, :ovcs, "ros_control1"}, state) do
    Logger.warning(
      "#{__MODULE__}: ros_control1 stopped arriving — throttle zeroed. " <>
        "The ROS bridge is not commanding this vehicle."
    )

    {:noreply, %{state | raw_value: 0}}
  end

  # Anything else is ignored rather than fatal. This process is the
  # throttle path; a stray message — a late reply, a monitor going
  # down — crashing it means a gap in throttle emission, and there is
  # no version of that which is better than doing nothing.
  # `Managers.ControlLevel` and `Traxxas.Motor` guard the same way.
  def handle_info(_message, state), do: {:noreply, state}

  defp compute_throttle(state) do
    requested_throttle = state.raw_value |> D.div(@range)
    %{state | requested_throttle: requested_throttle}
  end

  defp emit(state) do
    Bus.broadcast("messages", %Bus.Message{
      name: :requested_throttle,
      value: state.requested_throttle,
      source: __MODULE__
    })

    state
  end
end
