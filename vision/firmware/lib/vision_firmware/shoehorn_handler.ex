defmodule VisionFirmware.ShoehornHandler do
  @moduledoc """
  What the unit does when one of its applications exits: `:vision_core`,
  `:vision_api` or `:vision_firmware`. Shoehorn starts them as temporary
  applications, so one that exits, or does not start, stays down.

  Each exit restarts the firmware's applications, those that do not run,
  after a wait that doubles from a second to a minute at most, for as
  long as they exit: the unit never reboots itself, so it stays reachable
  over SSH and for firmware updates whatever the vision does. An exit
  after the applications ran for `:stable_ms` waits a second again.

  Any other application that exits is left alone, as by
  `Shoehorn.DefaultHandler`: SSH and the firmware updates keep running.
  So is one stopped on purpose, with `Application.stop/1`.

  ## Options

  Read from the `:shoehorn` application's configuration, for tests:

    * `:stable_ms` (five minutes) — the run after which an exit counts
      as the first.
    * `:restart` — called with the wait, in milliseconds, and the
      application to start with its dependencies.
    * `:now_ms` — the monotonic time, in milliseconds.
  """
  @behaviour Shoehorn.Handler

  require Logger

  @watched [:vision_core, :vision_api, :vision_firmware]
  @root :vision_firmware
  @first_wait_ms 1_000
  @longest_wait_ms 60_000
  @default_stable_ms 300_000

  @impl Shoehorn.Handler
  def init(options) do
    {:ok,
     %{
       failures: 0,
       running_since_ms: nil,
       stable_ms: Keyword.get(options, :stable_ms, @default_stable_ms),
       restart: Keyword.get(options, :restart, &restart_after/2),
       now_ms: Keyword.get(options, :now_ms, fn -> System.monotonic_time(:millisecond) end)
     }}
  end

  @impl Shoehorn.Handler
  def application_started(_application, state), do: {:continue, state}

  # `Application.stop/1` reports `:stopped`: the application was stopped on purpose.
  @impl Shoehorn.Handler
  def application_exited(_application, :stopped, state), do: {:continue, state}

  def application_exited(application, reason, state) when application in @watched do
    now_ms = state.now_ms.()
    failures = if stable?(state, now_ms), do: 1, else: state.failures + 1

    wait_ms = (@first_wait_ms * Integer.pow(2, min(failures - 1, 6))) |> min(@longest_wait_ms)
    Logger.error("#{application} exited (#{inspect(reason)}): restarting in #{wait_ms} ms")
    state.restart.(wait_ms, @root)
    {:continue, %{state | failures: failures, running_since_ms: now_ms + wait_ms}}
  end

  def application_exited(_application, _reason, state), do: {:continue, state}

  defp stable?(%{running_since_ms: nil}, _now_ms), do: false

  defp stable?(%{running_since_ms: since_ms, stable_ms: stable_ms}, now_ms),
    do: now_ms - since_ms > stable_ms

  defp restart_after(wait_ms, application) do
    {:ok, _timer} = :timer.apply_after(wait_ms, Application, :ensure_all_started, [application])
    :ok
  end
end
