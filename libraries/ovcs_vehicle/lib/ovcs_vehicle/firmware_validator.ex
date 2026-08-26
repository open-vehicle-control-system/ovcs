defmodule OvcsVehicle.FirmwareValidator do
  @moduledoc """
  Marks the running firmware as good, so an A/B update sticks.

  The Nerves systems in this fleet are built on the v2.0 line, whose
  MicroSD/eMMC layout has two firmware slots and reverts to the previous
  slot on the next boot unless the new firmware marks itself valid.
  Nothing else in the tree calls `Nerves.Runtime.validate_firmware/0`,
  so without this every OTA update — `./ovcs upload` and NervesHub alike
  — would appear to succeed, run once, and then silently roll back.

  Reaching this child means the release booted far enough to start its
  application, which is the signal we have available. It is a weaker
  claim than "the vehicle works": a firmware that boots but cannot talk
  CAN still validates itself. Tightening that would mean waiting on a
  real health check (say, the first successful frame on each configured
  bus) before validating, at the cost of reverting on any transient
  startup failure. Worth revisiting once there is a health signal worth
  gating on.

  Wired in as a `Task` child for the same reason as
  `OvcsVehicle.HostUEventGuard`: it runs after boot in its own process,
  rather than from inside an `Application.start/2` callback. Include it
  only on target, e.g.:

      children =
        if Nerves.Runtime.mix_target() == :host,
          do: children,
          else: [OvcsVehicle.FirmwareValidator | children]
  """

  require Logger

  @doc "Child spec that validates the running firmware once, then exits."
  def child_spec(_opts \\ []) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [&validate/0]},
      restart: :transient
    }
  end

  # `nerves_runtime` is deliberately not a dependency of this library:
  # it carries a C NIF (needing libmnl at build time) and this package
  # stays dependency-free, so CI can compile it without system packages.
  # The module is resolved at runtime instead — this child is only wired
  # in on target, where the firmware always brings nerves_runtime along.
  #
  # Built with `Module.concat/1` rather than written literally on purpose:
  # any form the compiler can resolve to `Nerves.Runtime` — a literal
  # call, a module attribute, or a variable bound to one — raises an
  # "undefined" warning here and so fails `--warnings-as-errors`.
  @nerves_runtime_parts [:Nerves, :Runtime]

  @doc """
  Validate the running firmware, logging the outcome.

  Never raises: a failure here must not take the supervision tree down
  with it. The consequence of failing is a revert on next boot, which is
  precisely the behaviour the A/B layout exists to provide.
  """
  def validate do
    case do_validate() do
      :ok ->
        Logger.info("#{__MODULE__}: firmware marked valid")
        :ok

      other ->
        Logger.error(
          "#{__MODULE__}: could not validate firmware (#{inspect(other)}) — " <>
            "this boot will revert to the previous slot"
        )

        :ok
    end
  rescue
    error ->
      Logger.error(
        "#{__MODULE__}: validate_firmware/0 raised #{inspect(error)} — " <>
          "this boot will revert to the previous slot"
      )

      :ok
  end

  defp do_validate do
    module = Module.concat(@nerves_runtime_parts)

    if Code.ensure_loaded?(module) and function_exported?(module, :validate_firmware, 0) do
      module.validate_firmware()
    else
      {:error, :nerves_runtime_unavailable}
    end
  end
end
