defmodule VmsApiWeb.RefreshInterval do
  @moduledoc "Bounds dashboard channel polling to intervals between 50 ms and one minute."

  @minimum_ms 50
  @maximum_ms 60_000

  @doc "Validates a channel join payload before any work is scheduled."
  def fetch(%{"interval" => interval})
      when is_integer(interval) and interval >= @minimum_ms and interval <= @maximum_ms,
      do: {:ok, interval}

  def fetch(_payload),
    do: {:error, %{reason: "interval must be an integer between 50 and 60000 milliseconds"}}
end
