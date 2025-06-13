# defmodule Talker do
#   use GenServer
#   alias Rclex.Pkgs.StdMsgs

#   def start_link(_) do
#     GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
#   end

#   def start do
#     {:ok, _pid} = start_link(nil)
#   end

#   @impl true
#   def init(state) do
#     Rclex.start_node("talker")
#     Rclex.start_publisher(StdMsgs.Msg.String, "/chatter", "talker")
#     schedule_publish()
#     {:ok, state}
#   end

#   @impl true
#   def handle_info(:publish, state) do
#     data = "Hello World from Rclex!"
#     msg = struct(StdMsgs.Msg.String, %{data: data})

#     IO.puts("Rclex: Publishing: #{data}")
#     Rclex.publish(msg, "/chatter", "talker")

#     schedule_publish()
#     {:noreply, state}
#   end

#   defp schedule_publish do
#     Process.send_after(self(), :publish, 1000)  # Schedule next publish in 1 second
#   end
# end
