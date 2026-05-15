defmodule OvcsBus.Cluster do
  @moduledoc """
  Keeps every OVCS firmware BEAM for the active vehicle connected as
  an Erlang distribution cluster.

  The peer list is derived from the vehicle module's declared roles:

  * `vms` — every vehicle.
  * `infotainment` — vehicles that implement `infotainment/0`.
  * `bridge-<id>` — one per entry in `bridge_firmwares/0`.

  Node-name shape is inferred from `Node.self()`:

  * Host dev (`<vehicle>-<role>@<host>`) — peers share `<host>` and
    vary the sname. Example, for `ovcs1-vms@dev-laptop`:

        :"ovcs1-infotainment@dev-laptop"
        :"ovcs1-bridge-ros@dev-laptop"

  * Deployed Nerves (`nerves@<vehicle>-<role>`) — peers share the
    sname `nerves` and vary the hostname. Example, for
    `nerves@ovcs1-vms`:

        :"nerves@ovcs1-infotainment"
        :"nerves@ovcs1-bridge-ros"

  Calls `Node.connect/1` on every peer at boot and retries on a
  `@retry_interval` timer, so a peer that comes up later is pulled
  into the mesh. Once connected, `Phoenix.PubSub` (and therefore
  `OvcsBus.broadcast/2`) fans messages out across every node.

  This replaces the `OvcsBus.Mqtt.*` plumbing for inter-firmware
  traffic. A single transport (Erlang distribution) now handles both
  host dev and deployed — no Mosquitto, no Tortoise311 client, no
  AppArmor quirks on dev machines.
  """
  use GenServer
  require Logger

  @retry_interval 2_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    vehicle = Keyword.fetch!(opts, :vehicle)
    peers = peers_for(vehicle)

    Logger.info(
      "OvcsBus.Cluster starting with peers #{inspect(peers)} (self: #{inspect(Node.self())})"
    )

    send(self(), :connect)
    {:ok, %{peers: peers}}
  end

  @impl true
  def handle_info(:connect, %{peers: peers} = state) do
    connected = Node.list()
    self_node = Node.self()

    Enum.each(peers, fn peer ->
      cond do
        peer == self_node -> :ok
        peer in connected -> :ok
        true -> Node.connect(peer)
      end
    end)

    Process.send_after(self(), :connect, @retry_interval)
    {:noreply, state}
  end

  @doc """
  Derive the peer node list for `vehicle_module` given the local
  node's naming convention.
  """
  @spec peers_for(module()) :: [node()]
  def peers_for(vehicle_module) do
    case String.split(Atom.to_string(Node.self()), "@", parts: 2) do
      [sname, hostname] ->
        vehicle_hyphen = vehicle_dir_hyphen(vehicle_module)
        roles = declared_roles(vehicle_module)

        if sname == "nerves" do
          # Deployed: role is encoded in hostname.
          Enum.map(roles, fn role -> String.to_atom("nerves@#{vehicle_hyphen}-#{role}") end)
        else
          # Host dev: role is encoded in sname; hostname is shared.
          Enum.map(roles, fn role ->
            String.to_atom("#{vehicle_hyphen}-#{role}@#{hostname}")
          end)
        end

      _ ->
        []
    end
  end

  defp declared_roles(vehicle_module) do
    Code.ensure_loaded(vehicle_module)

    info_roles =
      if function_exported?(vehicle_module, :infotainment, 0), do: ["infotainment"], else: []

    bridge_roles =
      if function_exported?(vehicle_module, :bridge_firmwares, 0) do
        vehicle_module.bridge_firmwares()
        |> Map.keys()
        |> Enum.map(fn id -> "bridge-#{String.replace(id, "_", "-")}" end)
      else
        []
      end

    ["vms"] ++ info_roles ++ bridge_roles
  end

  defp vehicle_dir_hyphen(vehicle_module) do
    vehicle_module
    |> inspect()
    |> String.trim_leading("Elixir.")
    |> Macro.underscore()
    |> String.replace("_", "-")
  end
end
