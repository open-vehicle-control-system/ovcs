defmodule VisionCore.Detection.Backend.Hailo.Device do
  @moduledoc """
  The claim on the unit's Hailo-8: a process registered under this
  module's name for as long as one detection pipeline runs on it.

  `hailo_detect` opens its own vdevice, and sharing the accelerator
  between two processes needs HailoRT's multi-process service, so one
  pipeline at a time runs on it. `VisionCore.Detection.Supervisor` starts
  the claim before a Hailo backend; a second Hailo unit's claim fails to
  start with `"the Hailo-8 already serves another pipeline, <holder>"`,
  which leaves that unit down. A backend restart keeps the claim.

  ## Options

    * `:pipeline` — the pipeline holding the claim (required).
  """
  use GenServer

  @doc "Claims the Hailo-8 for `:pipeline`, or fails naming the pipeline holding it."
  def start_link(opts) do
    pipeline = Keyword.fetch!(opts, :pipeline)

    case GenServer.start_link(__MODULE__, pipeline, name: __MODULE__) do
      {:error, {:already_started, holder}} ->
        {:error,
         "the Hailo-8 already serves another pipeline, #{inspect(holder_pipeline(holder))}"}

      started ->
        started
    end
  end

  defp holder_pipeline(holder) do
    GenServer.call(holder, :pipeline)
  catch
    :exit, _reason -> nil
  end

  @impl GenServer
  def init(pipeline), do: {:ok, pipeline}

  @impl GenServer
  def handle_call(:pipeline, _from, pipeline), do: {:reply, pipeline, pipeline}
end
