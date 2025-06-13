defmodule Ros2.StdMsgs.Msg.Header do
  @moduledoc false
  use Ros2.Common

  defstruct stamp: nil, frame_id: ""

  def parse(payload) do
    with {:ok, stamp, payload} <- Ros2.BuiltinIterfaces.Msg.Time.parse(payload),
         {:ok, frame_id, payload} <- parse_string(payload)
    do
      {:ok,
        %__MODULE__{
          stamp: stamp,
          frame_id: frame_id
        },
        payload
      }
    else
      error -> error
    end
  end
end
