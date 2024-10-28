defmodule NervesUEvent do
  @moduledoc """
  NervesUEvent listens for events from the Linux kernel, automatically loads
  device drivers, and forwards them to your Elixir programs.

  NervesUEvent is a very simple version of the Linux `udevd`. Just like `udevd`
  does for desktop Linux, NervesUEvent registers to receive UEvents from the Linux
  kernel. Unlike `udevd`, NervesUEvent only runs `modprobe` when needed and keeps
  track of what hardware is in the system. For most Nerves use cases, `udevd`
  isn't needed.
  """

  @doc """
  Get all reported UEvents
  """
  @spec get_all() :: [{PropertyTable.property(), PropertyTable.value()}]
  def get_all(), do: PropertyTable.get_all(NervesUEvent)

  @doc """
  Get the most recent  value of UEvent report

  For example,

  ```elixir
  > NervesUEvent.get(["devices", "platform", "leds", "leds", "red:indicator-1"])
  %{
    "of_compatible_n" => "0",
    "of_fullname" => "/leds/rgb1-blue",
    "of_name" => "rgb1-blue",
    "subsystem" => "leds"
  }}
  ```
  """
  @spec get(PropertyTable.property(), PropertyTable.value()) :: PropertyTable.value()
  def get(property, default \\ nil), do: PropertyTable.get(NervesUEvent, property, default)

  @doc """
  Run an arbitrary match against UEvents

  Use `:_` in the path to accept any value in that position
  Use `:"$"` at the end of the path to perform an exact match
  """
  @spec match(PropertyTable.pattern()) :: [{PropertyTable.property(), PropertyTable.value()}]
  def match(pattern), do: PropertyTable.match(NervesUEvent, pattern)

  @doc """
  Subscribe to uevent notifications

  Pass a pattern like one you'd pass to `match/1`. Instead of getting a
  response, you'll receive a message when a matching UEvent happens.
  """
  @spec subscribe(PropertyTable.pattern()) :: :ok
  def subscribe(property), do: PropertyTable.subscribe(NervesUEvent, property)
end
