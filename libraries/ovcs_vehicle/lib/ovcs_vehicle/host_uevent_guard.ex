defmodule OvcsVehicle.HostUEventGuard do
  @moduledoc """
  Stops `:nerves_uevent` on host firmware boots (`./ovcs run`).

  nerves_uevent opens a Linux netlink port framed with `{:packet, 2}`.
  On a Nerves target the coldplug uevent stream fits that 64 KB frame,
  but a dev host enumerates far more devices, overflowing it and
  crash-looping `NervesUEvent.UEvent` on `binary_to_term`. The uevent
  feed is only consumed on target (SPI CAN discovery in each firmware's
  `NetworkMapper`); on host the CAN mappings are explicit vcan names, so
  the feed is unused. Stopping the app silences the crash loop.

  Wired in as a `Task` child so `Application.stop/1` runs in its own
  process *after* boot — calling it from inside an `Application.start/2`
  callback would deadlock the application controller. Include it only on
  host, e.g.:

      children =
        if Nerves.Runtime.mix_target() == :host,
          do: [OvcsVehicle.HostUEventGuard | children],
          else: children
  """

  @doc "Child spec that stops `:nerves_uevent` once, then exits normally."
  def child_spec(_opts \\ []) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [&stop_uevent/0]},
      restart: :transient
    }
  end

  defp stop_uevent do
    _ = Application.stop(:nerves_uevent)
    :ok
  end
end
