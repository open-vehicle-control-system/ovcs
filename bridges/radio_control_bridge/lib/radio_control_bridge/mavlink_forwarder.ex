defmodule RadioControlBridge.MavlinkForwarder.State do
  @moduledoc false
  defstruct rc_count: 0,
            other_counts: %{},
            last_rc_at_ms: nil
end

defmodule RadioControlBridge.MavlinkForwarder do
  @moduledoc """
  Listens to ExpressLRS MAVLink messages and re-emits the 8 RC
  channels on the OVCS CAN bus as two `radio_control_channels`
  frames (channels 1–4 and 5–8).
  """
  alias RadioControlBridge.MavlinkForwarder.State
  alias Cantastic.Emitter

  require Logger
  use GenServer

  # A periodic traffic summary tells no MAVLink from only non-RC messages.
  @heartbeat_interval_ms 5_000
  # One debug line per this many messages of a type: logging every
  # message starves the SC16IS SPI drain and overruns its RX FIFO.
  @log_sample_every 100

  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(args) do
    Logger.debug("Starting #{__MODULE__}…")
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl GenServer
  def init(_) do
    :ok = ExpressLrs.Mavlink.Interpreter.register_listener(self())
    Logger.info("#{__MODULE__}: registered as ExpressLRS listener")

    :ok =
      Emitter.configure(:ovcs, "radio_control_channels0", %{
        parameters_builder_function: :default,
        initial_data: %{
          "channel1" => 0,
          "channel2" => 0,
          "channel3" => 0,
          "channel4" => 0
        },
        enable: true
      })

    :ok =
      Emitter.configure(:ovcs, "radio_control_channels1", %{
        parameters_builder_function: :default,
        initial_data: %{
          "channel5" => 0,
          "channel6" => 0,
          "channel7" => 0,
          "channel8" => 0
        },
        enable: true
      })

    Logger.info(
      "#{__MODULE__}: emitting radio_control_channels0/1 on :ovcs (initial channels = 0)"
    )

    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
    {:ok, %State{}}
  end

  @impl GenServer
  def handle_cast({:mavlink_message, %{name: "RC_CHANNELS_OVERRIDE"} = message}, state) do
    channels = Map.new(message.base_fields, &{&1.name, &1.value})

    cond do
      state.rc_count == 0 ->
        Logger.info(
          "#{__MODULE__}: first RC_CHANNELS_OVERRIDE received — channels=#{inspect(channels)}"
        )

      rem(state.rc_count, @log_sample_every) == 0 ->
        Logger.debug(fn ->
          "RC_CHANNELS_OVERRIDE channels=#{inspect(channels)} (sample 1/#{@log_sample_every})"
        end)

      true ->
        :ok
    end

    :ok =
      Emitter.update(:ovcs, "radio_control_channels0", fn frame_data ->
        %{
          frame_data
          | "channel1" => channels["chan1_raw"],
            "channel2" => channels["chan2_raw"],
            "channel3" => channels["chan3_raw"],
            "channel4" => channels["chan4_raw"]
        }
      end)

    :ok =
      Emitter.update(:ovcs, "radio_control_channels1", fn frame_data ->
        %{
          frame_data
          | "channel5" => channels["chan5_raw"],
            "channel6" => channels["chan6_raw"],
            "channel7" => channels["chan7_raw"],
            "channel8" => channels["chan8_raw"]
        }
      end)

    {:noreply,
     %{state | rc_count: state.rc_count + 1, last_rc_at_ms: System.monotonic_time(:millisecond)}}
  end

  def handle_cast({:mavlink_message, %{name: name}}, state) do
    seen_count = Map.get(state.other_counts, name, 0)

    cond do
      seen_count == 0 ->
        Logger.info("#{__MODULE__}: first ignored MAVLink #{inspect(name)}")

      # Per-type counts still appear in the heartbeat summary.
      rem(seen_count, @log_sample_every) == 0 ->
        Logger.debug(fn ->
          "#{__MODULE__}: ignored MAVLink #{inspect(name)} (sample 1/#{@log_sample_every}, total=#{seen_count})"
        end)

      true ->
        :ok
    end

    {:noreply, %{state | other_counts: Map.update(state.other_counts, name, 1, &(&1 + 1))}}
  end

  def handle_cast({:mavlink_message, _other}, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(:heartbeat, state) do
    age_ms =
      case state.last_rc_at_ms do
        nil -> nil
        last_rc_at_ms -> System.monotonic_time(:millisecond) - last_rc_at_ms
      end

    cond do
      state.rc_count == 0 and map_size(state.other_counts) == 0 ->
        Logger.warning(
          "#{__MODULE__}: no MAVLink messages in the last #{@heartbeat_interval_ms}ms — check ExpressLRS UART link"
        )

      state.rc_count == 0 ->
        Logger.warning(
          "#{__MODULE__}: MAVLink alive but no RC_CHANNELS_OVERRIDE yet — other messages: #{inspect(state.other_counts)}"
        )

      age_ms != nil and age_ms > @heartbeat_interval_ms ->
        Logger.warning(
          "#{__MODULE__}: last RC_CHANNELS_OVERRIDE was #{age_ms}ms ago (total=#{state.rc_count})"
        )

      true ->
        Logger.info(
          "#{__MODULE__}: RC heartbeat — total=#{state.rc_count}, other=#{inspect(state.other_counts)}"
        )
    end

    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
    {:noreply, %{state | other_counts: %{}}}
  end
end
