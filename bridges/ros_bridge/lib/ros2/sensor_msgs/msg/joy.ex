defmodule Ros2.SensorMsgs.Msg.Joy do
  @moduledoc false
  use Ros2.Common

  defstruct header: nil, axes: [], buttons: []

  def parse(payload) do
    with {:ok, header, payload} <- Ros2.StdMsgs.Msg.Header.parse(payload),
         {:ok, axes, payload} <- parse_float32_array(payload),
         {:ok, buttons, payload} <- parse_int32_array(payload)
    do
      {:ok, %__MODULE__{
        header: header,
        axes: axes,
        buttons: buttons
      }, payload}
    else
      error -> error
    end
  end
end
