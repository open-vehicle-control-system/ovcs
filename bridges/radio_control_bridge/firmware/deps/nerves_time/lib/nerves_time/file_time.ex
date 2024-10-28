defmodule NervesTime.FileTime do
  @moduledoc """
  FileTime simulates a real-time clock using a file's mtime

  The way it works is that a file is touched each time nerves_time
  wants to update the RTC. When nerves_time shuts down, the file is
  again touched. The next boot then reads the last modified time of
  the file so that nerves_time can set the clock to that value. It
  will certainly be off, but not absurdly so unless the device has
  been powered off for a really long time.

  While this doesn't sound ideal at all, knowing the time within
  minutes, hours, or days can get the clock to within time ranges
  needed for X.509 certificate validation.
  """
  @behaviour NervesTime.RealTimeClock

  @default_path ".nerves_time"

  @doc false
  @impl NervesTime.RealTimeClock
  @spec init(args :: any()) :: {:ok, Path.t()}
  def init(_args), do: {:ok, time_file()}

  @doc """
  Update the timestamp one final time
  """
  @impl NervesTime.RealTimeClock
  def terminate(path) do
    _ = File.touch(path)
    :ok
  end

  @doc """
  Update the file holding a stamp of the current time.
  """
  @impl NervesTime.RealTimeClock
  def set_time(path, _naive_date_time) do
    _ = File.touch(path)
    path
  end

  @doc """
  Return the timestamp of when update was last called or
  the Unix epoch time (1970-01-01) should that not work.
  """
  @impl NervesTime.RealTimeClock
  def get_time(path) do
    with {:ok, stat} <- File.stat(path),
         {:ok, %NaiveDateTime{} = mtime} <- NaiveDateTime.from_erl(stat.mtime) do
      {:ok, mtime, path}
    else
      _ -> {:unset, path}
    end
  end

  @doc """
  Return the path to the file that keeps track of the time
  """
  @spec time_file() :: Path.t()
  def time_file() do
    Application.get_env(:nerves_time, :time_file, @default_path)
    |> Path.expand(System.user_home())
  end
end
