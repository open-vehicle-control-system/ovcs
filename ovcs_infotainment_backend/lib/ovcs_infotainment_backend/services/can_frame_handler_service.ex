defmodule OvcsInfotainmentBackend.CanFrameHandlerService do
  use GenServer
  alias OvcsInfotainmentBackend.CanService
  alias OvcsInfotainmentBackend.Can.Polo

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{can0_socket: nil})
  end

  @impl true
  def init(state) do
    CanService.setup_can_interface("vcan0", "50000")
    {:ok, socket} = CanService.bind_socket("vcan0")
    receive_frame()
    {:ok, %{state | can0_socket: socket}}
  end

  @impl true
  def handle_info(:receive_frame, state) do
    {:ok, frame} = CanService.receive_one_frame(state.can0_socket)
    :ok = Polo.handle_frame(frame)
    receive_frame()
    {:noreply, state}
  end


  defp receive_frame do
    send(self(), :receive_frame)
  end
end
