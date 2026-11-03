defmodule OvcsBusGateway.Settings do
  @moduledoc """
  What the running gateway was started with: its vehicle, its `OvcsBusGateway.Config` and its
  MQTT client id, for the API to describe it.
  """

  use Agent

  @enforce_keys [:vehicle, :config, :mqtt_client_id]
  defstruct [:vehicle, :config, :mqtt_client_id]

  @type t :: %__MODULE__{
          vehicle: module(),
          config: OvcsBusGateway.Config.t(),
          mqtt_client_id: String.t()
        }

  @spec start_link(t()) :: Agent.on_start()
  def start_link(%__MODULE__{} = settings),
    do: Agent.start_link(fn -> settings end, name: __MODULE__)

  @doc "The running gateway's settings."
  @spec get() :: t()
  def get, do: Agent.get(__MODULE__, & &1)
end
