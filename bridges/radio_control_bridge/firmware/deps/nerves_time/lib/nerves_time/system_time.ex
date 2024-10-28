defmodule NervesTime.SystemTime do
  @moduledoc false
  use GenServer
  require Logger

  @default_rtc {NervesTime.FileTime, []}

  defmodule State do
    @moduledoc false
    @type t() :: %__MODULE__{
            rtc_spec: {module(), any()},
            rtc: module(),
            rtc_state: term()
          }
    defstruct rtc_spec: nil,
              rtc: nil,
              rtc_state: nil
  end

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_args) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @spec await_initialization(non_neg_integer()) :: :ok | :timeout
  def await_initialization(timeout) do
    GenServer.call(__MODULE__, :await_initialization, timeout)
  catch
    :exit, _ -> :timeout
  end

  @doc """
  Update the RTC with the latest system time
  """
  @spec update_rtc() :: :ok
  def update_rtc() do
    GenServer.call(__MODULE__, :update_rtc)
  end

  @doc """
  Update the System time and set the RTC
  """
  @spec set_time(NaiveDateTime.t()) :: :ok | :error
  def set_time(%NaiveDateTime{} = time) do
    GenServer.call(__MODULE__, {:set_time, time})
  end

  @impl GenServer
  def init(_args) do
    app_env = Application.get_all_env(:nerves_time)
    rtc_spec = Keyword.get(app_env, :rtc) |> normalize_rtc_spec()

    # Trap exits so that it's possible to call RTC.terminate/1
    Process.flag(:trap_exit, true)

    {:ok, %State{rtc_spec: rtc_spec}, {:continue, :continue}}
  end

  defp normalize_rtc_spec({module, args} = rtc_spec)
       when is_atom(module) and not is_nil(module) and is_list(args),
       do: rtc_spec

  defp normalize_rtc_spec(nil), do: @default_rtc

  defp normalize_rtc_spec(module) when is_atom(module), do: {module, []}

  defp normalize_rtc_spec(other) do
    Logger.error(
      "[NervesTime] Bad rtc spec '#{inspect(other)}. Reverting to '#{inspect(@default_rtc)}'"
    )

    @default_rtc
  end

  @impl GenServer
  def handle_continue(:continue, state) do
    new_state =
      state
      |> init_rtc()
      |> set_system_time_from_rtc()

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_call({:set_time, %NaiveDateTime{} = time}, from, state) do
    case set_system_time(time) do
      :ok ->
        handle_call(:update_rtc, from, state)

      :error ->
        {:reply, :error, state}
    end
  end

  @impl GenServer
  def handle_call(:update_rtc, _from, %State{rtc: rtc} = state) when rtc != nil do
    system_time = NaiveDateTime.utc_now()
    new_rtc_state = rtc.set_time(state.rtc_state, system_time)
    {:reply, :ok, %State{state | rtc_state: new_rtc_state}}
  end

  @impl GenServer
  def handle_call(:update_rtc, _from, state) do
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(:await_initialization, _from, state) do
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, :normal}, state) do
    # Normal exits come from calls to set the time.
    # They're initiated by us, so they can be safely ignored.
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, %{rtc: rtc, rtc_state: rtc_state}) do
    if rtc do
      Logger.warning("[NervesTime] Stopping RTC #{inspect(rtc)}: #{inspect(reason)}")
      rtc.terminate(rtc_state)
    end

    :ok
  end

  defp init_rtc(state) do
    {rtc_module, rtc_arg} = state.rtc_spec

    case rtc_module.init(rtc_arg) do
      {:ok, rtc_state} ->
        %{state | rtc: rtc_module, rtc_state: rtc_state}

      {:error, reason} ->
        Logger.error(
          "[NervesTime] Cannot initialize rtc '#{inspect(state.rtc_spec)}': #{inspect(reason)}"
        )

        state
    end
  catch
    what, why ->
      Logger.error(
        "[NervesTime] Cannot initialize rtc '#{inspect(state.rtc_spec)}': #{inspect(what)}, #{inspect(why)}"
      )

      state
  end

  @spec set_system_time_from_rtc(State.t()) :: State.t()
  defp set_system_time_from_rtc(%State{rtc: rtc} = state) when not is_nil(rtc) do
    final_rtc_state =
      case rtc.get_time(state.rtc_state) do
        {:ok, %NaiveDateTime{} = rtc_time, next_rtc_state} ->
          Logger.info(
            "[NervesTime] #{inspect(rtc)} reports that the time is #{inspect(rtc_time)}"
          )

          check_rtc_time_and_set(rtc, rtc_time, next_rtc_state)

        # Try to fix an unset or corrupt RTC
        {:unset, next_rtc_state} ->
          Logger.info("[NervesTime] #{inspect(rtc)} reports that the time hasn't been set.")
          now = sane_system_time()
          rtc.set_time(next_rtc_state, now)
      end

    %{state | rtc_state: final_rtc_state}
  end

  defp set_system_time_from_rtc(state) do
    # No RTC due to an earlier error

    # Fall back to a "sane time" at a minimum
    _ = sane_system_time()

    state
  end

  defp sane_system_time() do
    now = NaiveDateTime.utc_now()

    case NervesTime.SaneTime.derive_time(now, now) do
      ^now ->
        now

      new_time ->
        # Side effect: force the system time to be in the sane range
        set_system_time(new_time)
        new_time
    end
  end

  defp check_rtc_time_and_set(rtc, rtc_time, rtc_state) do
    system_time = NaiveDateTime.utc_now()

    case NervesTime.SaneTime.derive_time(system_time, rtc_time) do
      ^system_time ->
        # No change to the system time. This means that we either have a
        # real-time clock that already set it or the default time
        # is better than any knowledge that we have to say that it's
        # wrong.
        rtc_state

      new_time ->
        set_system_time(new_time)

        # If the RTC is off by more than an hour, then update it.
        # Otherwise, wait for NTP to give it a better time
        rtc_delta =
          NaiveDateTime.diff(rtc_time, new_time, :second)
          |> div(3600)

        if rtc_delta != 0,
          do: rtc.set_time(rtc_state, new_time),
          else: rtc_state
    end
  end

  defp set_system_time(%NaiveDateTime{} = time) do
    string_time = time |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()

    case System.cmd("date", ["-u", "-s", string_time]) do
      {_result, 0} ->
        Logger.info("[NervesTime] nerves_time set system clock to #{string_time} UTC")
        :ok

      {message, code} ->
        Logger.error(
          "[NervesTime] nerves_time can't set system clock to '#{string_time}': #{code} #{inspect(message)}"
        )

        :error
    end
  end
end
