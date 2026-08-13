defmodule VmsCore.Components.OVCS.Gnss do
  @moduledoc """
    GNSS receiver CAN component publishing the vehicle position

    Decodes the `gnss_position` / `gnss_status` frames emitted by a
    GNSS CAN component on the OVCS network and broadcasts the fused
    fix on the bus as a single `:vehicle_position` message. Consumers
    (e.g. the CoT bridge feeding WebTAK) subscribe to that message
    rather than to this module, so an alternative position source —
    say one fetched from another device over Ethernet — only has to
    broadcast the same message shape for everything downstream to
    keep working.

    The position deliberately carries no speed: the vehicle speed is
    owned by its own component following OVCS conventions (e.g. the
    ABS driver broadcasting `:speed`), and consumers combine the two
    bus messages themselves.
  """
  use GenServer

  alias Cantastic.{Frame, Receiver, Signal}
  alias OvcsBus, as: Bus

  @loop_period 100
  @fix_types %{"none" => :none, "fix_2d" => :fix_2d, "fix_3d" => :fix_3d, "dgnss" => :dgnss}

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ok = Receiver.subscribe(self(), :ovcs, ["gnss_position", "gnss_status"])
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)

    {:ok,
     %{
       latitude: nil,
       longitude: nil,
       altitude: nil,
       heading: nil,
       fix_type: :none,
       satellite_count: 0,
       last_position_at: nil,
       loop_timer: timer
     }}
  end

  @impl true
  def handle_info(:loop, state) do
    if has_fix?(state) do
      Bus.broadcast("messages", %Bus.Message{
        name: :vehicle_position,
        value: %{
          latitude: state.latitude,
          longitude: state.longitude,
          altitude: state.altitude,
          heading: state.heading,
          fix_type: state.fix_type,
          satellite_count: state.satellite_count,
          timestamp: state.last_position_at
        },
        source: __MODULE__
      })
    end

    Bus.broadcast("messages", %Bus.Message{
      name: :gnss_fix_type,
      value: state.fix_type,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :gnss_satellite_count,
      value: state.satellite_count,
      source: __MODULE__
    })

    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: "gnss_position", signals: signals}}, state) do
    %{
      "latitude" => %Signal{value: latitude},
      "longitude" => %Signal{value: longitude}
    } = signals

    {:noreply,
     %{state | latitude: latitude, longitude: longitude, last_position_at: DateTime.utc_now()}}
  end

  def handle_info({:handle_frame, %Frame{name: "gnss_status", signals: signals}}, state) do
    %{
      "altitude" => %Signal{value: altitude},
      "heading" => %Signal{value: heading},
      "fix_type" => %Signal{value: fix_type},
      "satellite_count" => %Signal{value: satellite_count}
    } = signals

    {:noreply,
     %{
       state
       | altitude: altitude,
         heading: heading,
         fix_type: @fix_types[fix_type] || :none,
         satellite_count: satellite_count
     }}
  end

  defp has_fix?(state) do
    state.fix_type != :none && !is_nil(state.latitude) && !is_nil(state.longitude)
  end
end
