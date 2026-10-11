defmodule VmsCore.Components.Volkswagen.Polo9N.IgnitionLock do
  @moduledoc """
  The Volkswagen Polo 9N ignition lock: publishes `:contact` (`:off`,
  `:on` or `:start`) from the key position it reports on the
  `:polo_drive` CAN network.
  """
  use GenServer
  alias Cantastic.{Frame, Receiver, Signal}
  alias OvcsBus, as: Bus

  @loop_period_ms 10

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl GenServer
  def init(_) do
    Receiver.subscribe(self(), :polo_drive, "key_status")
    {:ok, timer} = :timer.send_interval(@loop_period_ms, :loop)

    {:ok,
     %{
       contact: :off,
       loop_timer: timer
     }}
  end

  @impl GenServer
  def handle_info(:loop, state) do
    Bus.broadcast("messages", %Bus.Message{
      name: :contact,
      value: state.contact,
      source: __MODULE__
    })

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:handle_frame, %Frame{signals: signals}}, state) do
    %{"key_state" => %Signal{value: key_state}} = signals

    contact =
      case key_state do
        "contact_off" -> :off
        "key_engaged" -> :off
        "contact_on" -> :on
        "start_engine" -> :start
      end

    {:noreply, %{state | contact: contact}}
  end
end
