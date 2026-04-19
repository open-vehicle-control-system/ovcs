defmodule OvcsVehicle.Firmware do
  @moduledoc """
  Runtime helpers for each firmware's `config/runtime.exs`.

  Every OVCS firmware image (`vms/firmware`, `infotainment/firmware`,
  `bridges/firmware`) is parameterised by the `VEHICLE` env var: the
  top-level module name of a vehicle package under `vehicles/`. The
  vehicle is NOT a Mix dep of the firmware — firmwares run from their
  own project directory, so the vehicle's compiled ebin has to be
  added to the code path at boot before the module can resolve.

  `resolve_vehicle/3` is the one-call bootstrap: read the env, prepend
  the vehicle's `_build/<env>/lib/<name>/ebin`, and return the module
  atom (or `nil` when no `VEHICLE` is set, as in `MIX_ENV=test`).
  """

  @doc """
  Resolve the configured vehicle module, if any.

  * `config_dir` — usually `__DIR__` from the calling `runtime.exs`
    (anchor for the relative ebin path under `vehicles/`).
  * `config_env` — `config_env()` from the caller; picks the right
    `_build/<env>/lib/…` tree.
  * `vehicle_name` — optional override when callers want to honour
    `Application.compile_env(...)` before falling back to `VEHICLE`.

  Returns the module atom (e.g. `Ovcs1`) or `nil`.
  """
  @spec resolve_vehicle(Path.t(), atom(), String.t() | nil) :: module() | nil
  def resolve_vehicle(config_dir, config_env, vehicle_name \\ nil) do
    name = vehicle_name || System.get_env("VEHICLE")

    if name do
      dir = Macro.underscore(name)

      ebin =
        Path.expand(
          "../../../vehicles/#{dir}/_build/#{config_env}/lib/#{dir}/ebin",
          config_dir
        )

      Code.prepend_path(ebin)
      Module.concat([name])
    end
  end
end
