defmodule OvcsBusGateway.Mqtt.Handler do
  @moduledoc """
  `Tortoise311.Handler` of the gateway's MQTT connection. It logs status changes at debug
  level only: `OvcsBusGateway.Mqtt` reports a lost connection.
  """

  use Tortoise311.Handler

  require Logger

  @impl Tortoise311.Handler
  def connection(status, state) do
    Logger.debug("MQTT status #{status}")
    {:ok, state}
  end
end
