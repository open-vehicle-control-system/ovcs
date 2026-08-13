defmodule VmsCore.Components.OVCS.Gnss do
  @moduledoc """
    GNSS receiver CAN component publishing the vehicle position

    Decodes the `gnss_position` / `gnss_status` frames emitted by a
    GNSS CAN component on the OVCS network and rebroadcasts them on
    the bus as ordinary per-parameter messages, so consumers combine
    them with other components' messages following the usual
    source-module convention:

    * `:vehicle_position` — map with `:latitude` / `:longitude`
      (decimal degrees), `:fix_type`, `:satellite_count` and
      `:timestamp`. The pair travels as one message because half a
      coordinate is meaningless.
    * `:altitude` — metres.
    * `:heading` — degrees. This is the GNSS course over ground
      (derived from movement), NOT a compass heading — it's only
      meaningful while driving. A compass/IMU component can own
      `:heading` for consumers that need one at standstill.

    Nothing GNSS-specific leaks into the message names, so an
    alternative source — a position fetched from another device over
    Ethernet, a barometric altitude, … — can broadcast the same
    messages and consumers just point their `*_source` knobs at it.
    The vehicle speed is deliberately not broadcast here: it is owned
    by its own component (e.g. the ABS driver).
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
          fix_type: state.fix_type,
          satellite_count: state.satellite_count,
          timestamp: state.last_position_at
        },
        source: __MODULE__
      })

      Bus.broadcast("messages", %Bus.Message{
        name: :altitude,
        value: state.altitude,
        source: __MODULE__
      })

      Bus.broadcast("messages", %Bus.Message{
        name: :heading,
        value: state.heading,
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
