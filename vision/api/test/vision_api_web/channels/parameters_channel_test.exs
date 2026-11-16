defmodule VisionApiWeb.ParametersChannelTest do
  use VisionApiWeb.ParametersCase

  import Phoenix.ChannelTest
  import Plug.Conn, except: [push: 2, push: 3]

  defp join do
    VisionApiWeb.DashboardSocket
    |> socket()
    |> subscribe_and_join(VisionApiWeb.ParametersChannel, "parameters")
  end

  defp value(%{included: included}, id),
    do: Enum.find_value(included, &(&1.id == id and &1.attributes.value))

  test "pushes every stage with its parameters on join, as GET /api/stages?include=parameters" do
    {:ok, _reply, _socket} = join()

    assert_push "stages", %{data: stages, meta: %{complete: true, unsaved: 0}} = document
    assert Enum.any?(stages, &(&1.id == "test.disparity"))
    assert value(document, "test.disparity.p1") == 8
  end

  test "pushes every stage again once a parameter is set" do
    {:ok, _reply, _socket} = join()
    assert_push "stages", %{meta: %{complete: true}}

    set("test.disparity.p1", 12)

    assert_push "stages", %{meta: %{complete: true, unsaved: 1}} = document, 1_000
    assert value(document, "test.disparity.p1") == 12
  end

  test "pushes the stage whose automatic parameter changed on its own, without the others", %{
    values: values
  } do
    {:ok, _reply, _socket} = join()
    settle()

    Agent.update(values, &Map.put(&1, :exposure, 250))

    assert_push "stages",
                %{data: [%{id: "test.disparity"}], meta: %{complete: false}} = document,
                2_000

    assert value(document, "test.disparity.exposure") == 250
  end

  # Takes the pushes of the join, of the setup's declaration and of the first sample.
  defp settle do
    receive do
      %Phoenix.Socket.Message{event: "stages"} -> settle()
    after
      1_200 -> :ok
    end
  end

  test "an event the channel does not take is refused, and the channel stays" do
    {:ok, _reply, socket} = join()

    reference = push(socket, "nope", %{})

    assert_reply reference, :error, %{reason: "unknown event"}
    assert Process.alive?(socket.channel_pid)
  end
end
