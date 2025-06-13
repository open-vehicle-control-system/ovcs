defmodule Ros2.StdMsgs.Msg.String do
  @moduledoc false
  use Ros2.Common

  defstruct data: ""

  def parse(<<sequence::little-unsigned-integer-32, payload::binary>>) do
    with {:ok, string, payload} <- parse_string(payload) do
      {:ok, %__MODULE__{data: string}, payload}
    else
      error -> error
    end
  end
end
