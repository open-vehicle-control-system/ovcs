defmodule OvcsInfotainmentBackend.Can.Polo do
  alias OvcsInfotainmentBackend.Can.{Signal, Frame}

  def handle_frame(%Frame{id: 800} = frame) do
    IO.inspect "--HANDBRAKE--"
    IO.inspect Frame.to_string(frame)

    handbrake_status_signal = Signal.from_frame(
      frame,
      :handbrake_engaged,
      1,
      1,
      :boolean,
      0,
      1,
      :little,
      %{
        0 => false,
        2 => true
      },
      :handbrake
      )
    IO.inspect handbrake_status_signal
    :ok
  end

  def handle_frame(_frame) do
    :ok
  end
end
