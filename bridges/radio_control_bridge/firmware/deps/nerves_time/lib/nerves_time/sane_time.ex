defmodule NervesTime.SaneTime do
  @moduledoc false

  # One of the ways that nerves_time determines whether a particular time is
  # possible is whether it's in a known good range.
  @default_earliest_time ~N[2020-07-25 00:00:00]
  @default_latest_time %{@default_earliest_time | year: @default_earliest_time.year + 20}

  @doc """
  Figure out a guess of the real time based on the current system clock (possible_time)
  and the latest timestamp from the RTC.
  """
  @spec derive_time(NaiveDateTime.t(), NaiveDateTime.t()) :: NaiveDateTime.t()
  def derive_time(possible_time, rtc_time) do
    # First normalize the input times so that they're in a reasonable time interval
    sane_rtc_time = make_sane(rtc_time)
    sane_possible_time = make_sane(possible_time)

    # Pick the latest
    if NaiveDateTime.compare(sane_possible_time, sane_rtc_time) == :gt do
      sane_possible_time
    else
      sane_rtc_time
    end
  end

  @doc """
  This function takes a guess at the current time and tries to adjust it so
  that it's not obviously wrong. Obviously wrong means that it is outside
  of the configured valid time range.

  If the time doesn't look right, set it to the earliest time. Why not set it
  to the latest allowed time if the time is in the future? The reason is
  that a cause of future times is RTC corruption. The logic is that the earliest
  allowed time is likely much closer to the actual time than the latest one.
  """
  @spec make_sane(NaiveDateTime.t()) :: NaiveDateTime.t()
  def make_sane(%NaiveDateTime{} = time) do
    earliest_time = Application.get_env(:nerves_time, :earliest_time, @default_earliest_time)
    latest_time = Application.get_env(:nerves_time, :latest_time, @default_latest_time)

    if within_interval(time, earliest_time, latest_time) do
      time
    else
      earliest_time
    end
  end

  # Fix anything bogus that's passed in. This does not feel very Erlang, but
  # crashing nerves_time causes more pain than it's worth for purity.
  def make_sane(_other),
    do: Application.get_env(:nerves_time, :earliest_time, @default_earliest_time)

  defp within_interval(time, earliest_time, latest_time) do
    NaiveDateTime.compare(time, earliest_time) == :gt and
      NaiveDateTime.compare(time, latest_time) == :lt
  end
end
