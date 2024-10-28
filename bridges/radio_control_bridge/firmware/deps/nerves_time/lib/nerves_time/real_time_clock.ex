defmodule NervesTime.RealTimeClock do
  @moduledoc """
  Behaviour for real-time clocks implementations.
  """

  @typedoc "Internal state of the hardware clock"
  @type state :: any()

  @doc """
  Initialize the clock

  This is called when `nerves_time` starts. If it fails, `nerves_time`
  won't call any of the other functions.
  """
  @callback init(args :: any()) :: {:ok, state()} | {:error, reason :: any()}

  @doc """
  Clean up the clock state

  This is called when `nerves_time` terminates. It's not guaranteed to be
  called, but if it is, it should clean up or do any final operations on
  the RTC.
  """
  @callback terminate(state()) :: :ok

  @doc """
  Get the time from the clock

  This is called after `init/1` returns successfully to see if the
  system clock should be updated.

  If the time isn't set, the implementation should return `:unset`.
  `set_time/2` will be called when the time is known.
  """
  @callback get_time(state()) ::
              {:ok, NaiveDateTime.t(), state()} | {:unset, state()}

  @doc """
  Set the clock

  This is called if `nerves_time` determines that the implementation is out
  of sync with the true time and at regular intervals (usually 11 minutes) as
  updates come in from NTP.

  If the time can't be set, the implementation can either wait to be called
  the next time or take some other action.
  """
  @callback set_time(state(), NaiveDateTime.t()) :: state()
end
