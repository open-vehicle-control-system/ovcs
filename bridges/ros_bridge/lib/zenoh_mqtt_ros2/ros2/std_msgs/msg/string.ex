defmodule Ros2.StdMsgs.Msg.String do
  @moduledoc false
  use Ros2.Common

  defstruct data: ""

  def parse(<<_sequence::little-unsigned-integer-32, payload::binary>>) do
    case parse_string(payload) do
      {:ok, string, payload} -> {:ok, %__MODULE__{data: string}, payload}
      error -> error
    end
  end
end
