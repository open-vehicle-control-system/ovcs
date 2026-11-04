defmodule VisionApiWeb.CalibrationActionJSON do
  @moduledoc """
  A created calibration action (session, cancel, solve, apply or reset) as
  a JSON:API resource of `type`, carrying the session as it is after it.
  """
  alias VisionApiWeb.{CalibrationJSON, JsonApi}

  @doc "The action resource of `type` and `id`, with the `session` state of the unit `prefix`."
  @spec show(%{
          type: String.t(),
          id: String.t(),
          session: VisionCore.Calibration.Session.state(),
          prefix: String.t()
        }) :: map()
  def show(%{type: type, id: id, session: session, prefix: prefix}),
    do: %{data: JsonApi.resource(type, id, CalibrationJSON.session(session, prefix))}
end
