defmodule InfotainmentFirmware do
  @moduledoc """
  Documentation for InfotainmentFirmware.
  """

  # NOTE: this firmware intentionally declares no `dev_addons/0`. The
  # infotainment dashboard (`infotainment/dashboard`) is a Flutter app, and
  # Flutter's hot reload is driven by keypresses on its stdin — which the
  # multiplexed `./ovcs run` can't provide. So instead of auto-launching it
  # as a dev add-on (where it'd run without hot reload), it's started on its
  # own with a real TTY via `mise run infotainment-dashboard`. See
  # `VmsFirmware.dev_addons/0` for an example firmware that does declare one.
end
