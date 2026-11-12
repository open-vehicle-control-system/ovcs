defmodule VisionCore.Detection.QnnPort do
  @moduledoc """
  What `VisionCore.Detection.Backend.Qnn` and
  `VisionCore.Segmentation.Backend.Qnn` share about their Port: the
  context binary it runs (`VisionCore.Detection.QnnContext`), the program
  started with QNN's environment, and the wait before it is reopened.
  """

  alias VisionCore.Detection.QnnContext

  @doc """
  The context binary of `dlc_path` for the program `executable`, generated
  when missing: `{:error, {:missing_binary, executable}}` without the
  program. `context_opts` are `VisionCore.Detection.QnnContext.ensure/2`'s.
  """
  @spec context(Path.t(), Path.t(), QnnContext.opts()) :: {:ok, Path.t()} | {:error, term()}
  def context(dlc_path, executable, context_opts) do
    if File.exists?(executable),
      do: QnnContext.ensure(dlc_path, context_opts),
      else: {:error, {:missing_binary, executable}}
  end

  @doc """
  Starts `executable` with `args` as a Port of 4-byte framed binary
  packets reporting its exit status, in QNN's environment
  (`VisionCore.Detection.QnnContext.env/2`).
  """
  @spec open(Path.t(), [String.t()], Path.t(), Path.t()) :: {:ok, port()} | {:error, term()}
  def open(executable, args, qairt_dir, dsp_library_path) do
    env =
      for {name, value} <- QnnContext.env(qairt_dir, dsp_library_path),
          do: {String.to_charlist(name), String.to_charlist(value)}

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        {:packet, 4},
        {:env, env},
        {:args, args}
      ])

    {:ok, port}
  rescue
    error -> {:error, error}
  end

  @doc """
  The wait before reopening a Port that failed `failures` times in a row:
  that entry of `reopen_delays_ms`, its last one past its end.
  """
  @spec reopen_delay_ms([non_neg_integer()], non_neg_integer()) :: non_neg_integer()
  def reopen_delay_ms(reopen_delays_ms, failures),
    do: Enum.at(reopen_delays_ms, failures, List.last(reopen_delays_ms))
end
