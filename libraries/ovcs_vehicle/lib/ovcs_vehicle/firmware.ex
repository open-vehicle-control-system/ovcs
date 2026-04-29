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
      app = String.to_atom(dir)

      ebin = locate_vehicle_ebin!(dir, config_env, config_dir)
      Code.prepend_path(ebin)

      # Register the vehicle as a loaded OTP application so callers like
      # Cantastic can do `Application.app_dir(:<dir>, "priv")` (which
      # otherwise returns `{:error, :bad_name}`). Idempotent — re-loading
      # a loaded app returns `{:error, {:already_loaded, _}}`, which we
      # treat as success.
      case :application.load(app) do
        :ok -> :ok
        {:error, {:already_loaded, ^app}} -> :ok
        {:error, reason} -> raise "could not load vehicle app #{inspect(app)}: #{inspect(reason)}"
      end

      load_vehicle_modules!(name, dir, ebin)
      Module.concat([name])
    end
  end

  # The vehicle's ebin lives in different places on host vs firmware:
  #   * host (`./ovcs run`): `vehicles/<dir>/_build/<env>/lib/<dir>/ebin`
  #   * firmware release: `<release>/lib/<dir>-<vsn>/ebin`, copied in by
  #     each firmware's `mix.exs` `copy_vehicle_app/1` release step.
  # Try both, prefer the host path when present (it's the live one
  # during `./ovcs run`).
  defp locate_vehicle_ebin!(dir, config_env, config_dir) do
    host_ebin =
      Path.expand(
        "../../../vehicles/#{dir}/_build/#{config_env}/lib/#{dir}/ebin",
        config_dir
      )

    cond do
      File.dir?(host_ebin) ->
        host_ebin

      release_ebin = find_release_ebin(dir, config_dir) ->
        release_ebin

      true ->
        raise """
        Could not find vehicle ebin for #{inspect(dir)}.

        Looked in:
          - host  : #{host_ebin}
          - release: <release>/lib/#{dir}-*/ebin (relative to #{config_dir})

        On host: run `mix compile` in vehicles/#{dir}/.
        On firmware: ensure the build's `copy_vehicle_app/1` release step
        ran and copied the vehicle into the release's lib.
        """
    end
  end

  defp find_release_ebin(dir, config_dir) do
    # `runtime.exs` runs from `<release>/releases/<vsn>/`, so
    # `../../lib/<dir>-*/ebin` resolves to the bundled vehicle app.
    pattern = Path.expand("../../lib/#{dir}-*/ebin", config_dir)

    case Path.wildcard(pattern) do
      [ebin | _] -> ebin
      [] -> nil
    end
  end

  # Releases run BEAM in embedded mode: modules not declared in any
  # app's `.app` `modules:` list are NOT loaded automatically on
  # reference, and `code:ensure_loaded/1` refuses to load them
  # (`{:error, :embedded}`). The vehicle's `.app` does declare its
  # modules — but `:application.load/1` only registers the app spec,
  # it doesn't preload modules. To survive the embedded-mode wall in
  # `runtime.exs` (which references composer / sub-modules right after
  # the top-level resolve), we walk the vehicle's ebin and explicitly
  # `code:load_file/1` every `Elixir.<Name>*.beam`. `:code.load_file/1`
  # works in embedded mode (unlike `ensure_loaded`).
  defp load_vehicle_modules!(name, dir, ebin) do
    prefix = "Elixir.#{name}"

    matches =
      Path.wildcard(Path.join(ebin, "#{prefix}*.beam"))
      |> Enum.map(&(&1 |> Path.basename(".beam") |> String.to_atom()))

    if matches == [] do
      raise """
      No vehicle modules found in #{ebin} matching #{prefix}*.beam.

      On host: did you run `mix compile` in vehicles/#{dir}/?
      On firmware: did the build's `copy_vehicle_app/1` release step
      copy the vehicle into the release's lib?
      """
    end

    Enum.each(matches, &:code.load_file/1)
  end
end
