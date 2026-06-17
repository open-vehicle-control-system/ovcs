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
  Resolve a side composer for `runtime.exs`.

  Returns `{vehicle, composer}` when the vehicle is found and the env
  is bootable (i.e. not `:test`), otherwise `nil`. Use it to collapse
  the resolve + nil-check + composer-fetch shuffle each firmware's
  `runtime.exs` would otherwise duplicate.

  * `side` — `:vms` or `:infotainment`. Calls the corresponding
    callback on the vehicle module to get the composer.
  * `config_dir` / `config_env` — same as `resolve_vehicle/3`.
  * `vehicle_name` — optional override (typically the firmware's
    `Application.compile_env(...)`).
  """
  @spec resolve_side(:vms | :infotainment, Path.t(), atom(), String.t() | nil) ::
          {module(), module()} | nil
  def resolve_side(side, config_dir, config_env, vehicle_name \\ nil)
      when side in [:vms, :infotainment] do
    # Short-circuit before resolve_vehicle/3: each firmware's config.exs
    # pins a default `:vehicle` (e.g. "Ovcs1") for host builds, so test
    # runs would otherwise hit locate_vehicle_ebin!/3 even though no
    # vehicle is needed — and CI doesn't compile vehicles/<dir>/.
    cond do
      config_env == :test ->
        nil

      vehicle = resolve_vehicle(config_dir, config_env, vehicle_name) ->
        {vehicle, apply(vehicle, side, [])}

      true ->
        nil
    end
  end

  @doc """
  Resolve a bridge entry for `bridges/firmware`'s `runtime.exs`.

  Returns `{vehicle, bridge_firmware_id, entry}` when the vehicle is
  found, the env is bootable, and the requested bridge id exists in
  the vehicle's `bridge_firmwares/0`. Otherwise `nil`.
  """
  @spec resolve_bridge(Path.t(), atom(), String.t() | nil, String.t() | nil) ::
          {module(), String.t(), map()} | nil
  def resolve_bridge(config_dir, config_env, bridge_firmware_id, vehicle_name \\ nil) do
    with true <- config_env != :test,
         vehicle when not is_nil(vehicle) <-
           resolve_vehicle(config_dir, config_env, vehicle_name),
         id when is_binary(id) <- bridge_firmware_id,
         {:ok, entry} <- Map.fetch(vehicle.bridge_firmwares(), id) do
      {vehicle, id, entry}
    else
      _ -> nil
    end
  end

  @doc """
  Return the on-device path to a role's pre-generated SSH host keys,
  or `nil` if the vehicle hasn't shipped any for that role.

  The path is `Application.app_dir(vehicle, "priv/host_keys/<role>")`.
  Roles match the CLI's firmware role names: `"vms"`, `"infotainment"`,
  or `"bridges/<bridge_firmware_id>"`. When the directory exists and
  contains at least one `ssh_host_*_key` file, callers can plug it
  into `:nerves_ssh, :system_dir` so the firmware boots with stable
  host keys regardless of how many times the SD card has been burned.

  Returns `nil` when the vehicle hasn't run `./ovcs host-keys`,
  letting the firmware fall back to NervesSSH's default `/data/nerves_ssh`
  (regenerated each fresh burn — the legacy behaviour).
  """
  @spec ssh_system_dir(module(), String.t()) :: Path.t() | nil
  def ssh_system_dir(vehicle, role) when is_atom(vehicle) and is_binary(role) do
    app = vehicle.can_config_otp_app()
    path = Application.app_dir(app, Path.join("priv/host_keys", role))

    cond do
      not File.dir?(path) -> nil
      Path.wildcard(Path.join(path, "ssh_host_*_key")) == [] -> nil
      true -> path
    end
  end

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

      load_vehicle_modules!(dir)
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

  # Releases run BEAM in embedded mode: modules don't auto-load on
  # first reference, and `:code.ensure_loaded/1` refuses to load them
  # (`{:error, :embedded}`). The vehicle isn't in the release's boot
  # script either — it's added at runtime via `Code.prepend_path` —
  # so modules in its ebin stay unloaded until something forces them.
  # Walk the vehicle's `.app` `:modules` list (populated by Mix at
  # compile time) and `:code.load_file/1` each one. `load_file/1`
  # works in embedded mode (unlike `ensure_loaded`). Reading the
  # module list from the loaded app, rather than globbing the ebin,
  # avoids the silent miss case where a vehicle module's name doesn't
  # start with the top-level prefix.
  defp load_vehicle_modules!(dir) do
    app = String.to_atom(dir)

    case :application.get_key(app, :modules) do
      {:ok, []} ->
        raise """
        Vehicle app #{inspect(app)} has no modules in its .app.

        On host: did you run `mix compile` in vehicles/#{dir}/?
        On firmware: did the build's `copy_vehicle_app/1` release step
        copy the vehicle into the release's lib?
        """

      {:ok, modules} ->
        Enum.each(modules, &:code.load_file/1)

      :undefined ->
        raise "vehicle app #{inspect(app)} not loaded; " <>
                "resolve_vehicle/3 should have :application.load/1'd it"
    end
  end
end
