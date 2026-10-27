defmodule OvcsBusGateway.Test.Peer do
  @moduledoc """
  Starts a peer BEAM on 127.0.0.1 running `:ovcs_bus`, then connects it to the test node.

  The peer is controlled over stdio and joins the mesh only once its bus is up, so a
  collector never sees a `:nodeup` for a node without `OvcsBus`.
  """

  @spec start(atom() | nil) :: {:ok, pid(), node()}
  def start(name \\ nil) do
    code_path_args = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    {:ok, peer, node} =
      :peer.start_link(%{
        name: name || :peer.random_name(),
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie()) | code_path_args]
      })

    {:ok, _apps} = :peer.call(peer, Application, :ensure_all_started, [:ovcs_bus])
    true = Node.connect(node)
    {:ok, peer, node}
  end

  @doc "Starts a peer with OTP's code path only, so it has no `OvcsBus`, and connects it."
  @spec start_without_bus() :: {:ok, pid(), node()}
  def start_without_bus do
    {:ok, peer, node} =
      :peer.start_link(%{
        name: :peer.random_name(),
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
      })

    true = Node.connect(node)
    {:ok, peer, node}
  end

  @spec stop(pid()) :: :ok
  def stop(peer), do: :peer.stop(peer)
end
