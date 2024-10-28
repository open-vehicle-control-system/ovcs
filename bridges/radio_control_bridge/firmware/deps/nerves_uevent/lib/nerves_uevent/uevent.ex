defmodule NervesUEvent.UEvent do
  @moduledoc """
  GenServer that captures Linux uevent messages and passes them up to Elixir.
  """
  use GenServer
  require Logger

  @type option() :: {:autoload_modules, boolean()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    autoload = Keyword.get(opts, :autoload_modules, true)
    executable = Application.app_dir(:nerves_uevent, ["priv", "uevent"])

    args = if autoload, do: ["modprobe"], else: []

    if File.exists?(executable) do
      port =
        Port.open({:spawn_executable, executable}, [
          {:args, args},
          {:packet, 2},
          :use_stdio,
          :binary,
          :exit_status
        ])

      {:ok, port}
    else
      # Ignore if not on a platform that can build the port binary
      :ignore
    end
  end

  @impl GenServer
  def handle_info({port, {:data, message}}, port) do
    case :erlang.binary_to_term(message) do
      {:add, path, kvmap} ->
        PropertyTable.put(NervesUEvent, path, kvmap)

      {:bind, _path, _kvmap} ->
        # Ignore device driver bind updates
        :ok

      {:change, path, kvmap} ->
        PropertyTable.put(NervesUEvent, path, kvmap)

      {:move, new_path, %{"devpath_old" => devpath_old}} ->
        old_path = String.split(devpath_old, "/")
        kvmap = PropertyTable.get(NervesUEvent, old_path)
        PropertyTable.delete(NervesUEvent, old_path)
        PropertyTable.put(NervesUEvent, new_path, kvmap)

      {:remove, path, _kvmap} ->
        PropertyTable.delete(NervesUEvent, path)

      {:unbind, _path, _kvmap} ->
        # Ignore device driver unbind updates
        :ok

      {other, path, kvmap} ->
        Logger.error(
          "Unexpected uevent reported: #{inspect(other)}, #{inspect(path)}, #{inspect(kvmap)}"
        )
    end

    {:noreply, port}
  end

  def handle_info(_, port), do: {:noreply, port}
end
