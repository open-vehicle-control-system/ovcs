defmodule SSHSubsystemFwup do
  @moduledoc """
  SSH subsystem for upgrading Nerves devices

  This module provides an SSH subsystem for Erlang's `ssh` application. This
  makes it possible to send firmware updates to Nerves devices using plain old
  `ssh` like this:

  ```shell
  cat $firmware | ssh -s $ip_address fwup
  ```

  Where `$ip_address` is the IP address of your Nerves device. Depending on how
  you have Erlang's `ssh` application set up, you may need to pass more
  parameters (like username, port, identities, etc.).

  See [`nerves_ssh`](https://github.com/nerves-project/nerves_ssh/) for an easy
  way to set this up. If you don't want to use `nerves_ssh`, then in your call
  to `:ssh.daemon` add the return value from
  `SSHSubsystemFwup.subsystem_spec/1`:

  ```elixir
  devpath = Nerves.Runtime.KV.get("nerves_fw_devpath")

  :ssh.daemon([
        {:subsystems, [SSHSubsystemFwup.subsystem_spec(devpath: devpath)]}
      ])
  ```

  See `SSHSubsystemFwup.subsystem_spec/1` for options. You will almost always
  need to pass the path to the device that should be updated since that is
  device-specific.
  """

  @behaviour :ssh_client_channel

  @typedoc false
  @type mfargs() :: {module(), function(), [any()]}

  @typedoc """
  Options:

  * `:devpath` - path for fwup to upgrade (Required)
  * `:fwup_path` - path to the fwup firmware update utility
  * `:fwup_env` - a list of name,value tuples to be passed to the OS environment for fwup
  * `:fwup_extra_options` - additional options to pass to fwup like for setting
    public keys
  * `:precheck_callback` - an MFArgs to call when there's a connection. If
    specified, the callback will be passed the username and the current set of
    options. If allowed, it should return `{:ok, new_options}`. Any other
    return value closes the connection.
  * `:success_callback` - an MFArgs to call when a firmware update completes
    successfully. Defaults to `{Nerves.Runtime, :reboot, []}`.
  * `:task` - the task to run in the firmware update. Defaults to `"upgrade"`
  """
  @type options :: [
          devpath: Path.t(),
          fwup_path: Path.t(),
          fwup_env: [{String.t(), String.t()}],
          fwup_extra_options: [String.t()],
          precheck_callback: mfargs() | nil,
          task: String.t(),
          success_callback: mfargs()
        ]

  require Logger

  alias SSHSubsystemFwup.FwupPort

  @doc """
  Helper for creating the SSH subsystem spec
  """
  @spec subsystem_spec(options()) :: :ssh.subsystem_spec()
  def subsystem_spec(options \\ []) do
    {~c"fwup", {__MODULE__, options}}
  end

  @impl :ssh_client_channel
  def init(options) do
    # Combine the default options, any application environment options and finally subsystem options
    combined_options =
      default_options()
      |> Keyword.merge(Application.get_all_env(:ssh_subsystem_fwup))
      |> Keyword.merge(options)

    {:ok, %{state: :running_fwup, id: nil, cm: nil, fwup: nil, options: combined_options}}
  end

  defp default_options() do
    [
      devpath: "",
      fwup_path: System.find_executable("fwup"),
      fwup_env: [],
      fwup_extra_options: [],
      precheck_callback: nil,
      task: "upgrade",
      success_callback: {Nerves.Runtime, :reboot, []}
    ]
  end

  @impl :ssh_client_channel
  def handle_msg({:ssh_channel_up, channel_id, cm}, state) do
    with {:ok, options} <- precheck(state.options[:precheck_callback], state.options),
         :ok <- check_devpath(options[:devpath]) do
      Logger.debug("ssh_subsystem_fwup: starting fwup")
      fwup = FwupPort.open_port(options)
      {:ok, %{state | id: channel_id, cm: cm, fwup: fwup}}
    else
      {:error, reason} ->
        _ = :ssh_connection.send(cm, channel_id, "Error: #{reason}")
        :ssh_connection.exit_status(cm, channel_id, 1)
        :ssh_connection.close(cm, channel_id)
        {:stop, :normal, state}
    end
  end

  def handle_msg({port, message}, %{fwup: port} = state) do
    case FwupPort.handle_port(port, message) do
      {:respond, response} ->
        _ = :ssh_connection.send(state.cm, state.id, response)

        {:ok, state}

      {:done, response, status} ->
        _ = if response != "", do: :ssh_connection.send(state.cm, state.id, response)
        _ = :ssh_connection.send_eof(state.cm, state.id)
        _ = :ssh_connection.exit_status(state.cm, state.id, status)
        :ssh_connection.close(state.cm, state.id)
        Logger.debug("ssh_subsystem_fwup: fwup exited with status #{status}")
        run_callback(status, state.options[:success_callback])
        {:stop, :normal, state}
    end
  end

  def handle_msg({:EXIT, port, _reason}, %{fwup: port} = state) do
    _ = :ssh_connection.send_eof(state.cm, state.id)
    _ = :ssh_connection.exit_status(state.cm, state.id, 1)
    :ssh_connection.close(state.cm, state.id)
    {:stop, :normal, state}
  end

  def handle_msg(message, state) do
    Logger.debug("Ignoring message #{inspect(message)}")
    {:ok, state}
  end

  @impl :ssh_client_channel
  def handle_ssh_msg({:ssh_cm, _cm, {:data, _channel_id, 0, data}}, state) do
    FwupPort.send_data(state.fwup, data)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _cm, {:data, _channel_id, 1, _data}}, state) do
    # Ignore stderr
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _cm, {:eof, _channel_id}}, state) do
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _cm, {:signal, _, _}}, state) do
    # Ignore signals
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _cm, {:exit_signal, _channel_id, _, _error, _}}, state) do
    {:stop, :normal, state}
  end

  def handle_ssh_msg({:ssh_cm, _cm, {:exit_status, _channel_id, _status}}, state) do
    {:stop, :normal, state}
  end

  def handle_ssh_msg({:ssh_cm, _cm, message}, state) do
    Logger.debug("Ignoring handle_ssh_msg #{inspect(message)}")
    {:ok, state}
  end

  @impl :ssh_client_channel
  def handle_call(_request, _from, state) do
    {:reply, :error, state}
  end

  @impl :ssh_client_channel
  def handle_cast(_message, state) do
    {:noreply, state}
  end

  defp run_callback(0 = _rc, {m, f, args}) do
    # Let others know that fwup was successful. The usual operation
    # here is to reboot. Run the callback in its own process so that
    # any issues with it don't affect processing here.
    _ = spawn(m, f, args)
    :ok
  end

  defp run_callback(_rc, _mfargs), do: :ok

  @impl :ssh_client_channel
  def terminate(_reason, _state) do
    :ok
  end

  @impl :ssh_client_channel
  def code_change(_old, state, _extra) do
    {:ok, state}
  end

  defp check_devpath(devpath) do
    if is_binary(devpath) and File.exists?(devpath) do
      :ok
    else
      {:error, "Invalid device path: #{inspect(devpath)}"}
    end
  end

  defp precheck(nil, options), do: {:ok, options}

  defp precheck({m, f, args}, options) do
    case apply(m, f, args) do
      {:ok, new_options} -> {:ok, Keyword.merge(options, new_options)}
      {:error, reason} -> {:error, reason}
      e -> {:error, "precheck failed for unknown reason - #{inspect(e)}"}
    end
  end
end
