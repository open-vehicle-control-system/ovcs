defmodule VisionApiWeb.CalibrationActionJSON do
  @moduledoc """
  A created calibration action (session, cancel, solve, apply or reset) as
  a JSON:API resource of `type`, carrying the session as it is after it,
  related to the `calibration` the session works on.
  """
  alias VisionApiWeb.{CalibrationJSON, JsonApi}

  @doc "The action resource of `type` and `id`, with the `session` state."
  @spec show(%{type: String.t(), id: String.t(), session: VisionCore.Calibration.Session.state()}) ::
          map()
  def show(%{type: type, id: id, session: session}) do
    relationships = %{
      calibration: JsonApi.to_one("calibrations", session.target && session.target.id)
    }

    %{data: JsonApi.resource(type, id, CalibrationJSON.session(session), relationships)}
  end
end
