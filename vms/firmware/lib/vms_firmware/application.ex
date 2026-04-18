defmodule VmsFirmware.Application do
  @moduledoc false
  use Application

  # The real supervision tree lives in `VmsCore.Application` (started
  # via OTP transitive deps) and `VmsApi.Application`. This module is
  # the release entry point — it only exists so the firmware has an
  # Application module to mount.
  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: VmsFirmware.Supervisor)
  end
end
