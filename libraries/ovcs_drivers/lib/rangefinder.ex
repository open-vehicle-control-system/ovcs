defmodule OvcsDrivers.Rangefinder do
  @moduledoc """
  Contract every single-beam rangefinder driver in `ovcs_drivers`
  implements (ultrasonic, time of flight).

  A vehicle usually carries several of the same model, so a driver is
  a `GenServer` named by its `:name` option rather than by its module,
  and these callbacks take that server:

    * `register_listener/2` at any time; listeners receive
      `{:range_sample, %OvcsDrivers.Rangefinder.Sample{}}` casts for
      each measurement.
  """

  @callback register_listener(GenServer.server(), pid()) :: :ok
end
