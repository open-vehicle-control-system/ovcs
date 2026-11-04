defmodule OvcsBusGateway.Http.FirmwareController do
  @moduledoc """
  The firmware the gateway runs on, read-only: the `firmwares` singleton `current`
  (`OvcsVehicle.FirmwareInfo`), with `revision`, `target`, `nervesSystem` with
  `nervesSystemVersion`, `nil` on a host, and `vehicle`, `nil` without `VEHICLE`. A query
  parameter answers a 400.
  """

  use Phoenix.Controller, formats: [:json]

  alias OvcsBusGateway.Http.JsonApi
  alias OvcsVehicle.FirmwareInfo

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    with :ok <- JsonApi.check_parameters(conn, []) do
      json(conn, %{data: resource(FirmwareInfo.current())})
    end
  end

  @doc "`firmware` as the `firmwares` resource `current`."
  @spec resource(FirmwareInfo.t()) :: map()
  def resource(%FirmwareInfo{} = firmware) do
    JsonApi.resource("firmwares", "current", %{
      revision: firmware.revision,
      target: firmware.target,
      nervesSystem: firmware.nerves_system,
      nervesSystemVersion: firmware.nerves_system_version,
      vehicle: firmware.vehicle
    })
  end
end
