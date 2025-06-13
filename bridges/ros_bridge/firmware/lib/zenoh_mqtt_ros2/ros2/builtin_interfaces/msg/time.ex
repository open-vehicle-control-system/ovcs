defmodule Ros2.BuiltinIterfaces.Msg.Time do
  @moduledoc false

  defstruct sec: 0, nanosec: 0

  def parse(<<_unknown::little-integer-size(32), seconds::little-integer-size(32), nanoseconds::little-unsigned-integer-size(32), payload::binary>>) do
    {:ok,
      %__MODULE__{sec: seconds, nanosec: nanoseconds},
      payload
    }
  rescue
    _ -> {:error, :malformed, __MODULE__}
  end
end
