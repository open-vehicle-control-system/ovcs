defmodule RosBridge.Inference.Supervisor do
  @moduledoc """
  Supervises the detection unit: the `hailo_detect` Port owner
  followed by the publisher that fuses its boxes with stereo depth.

  Exists to contain failure rather than to organise code. The bridge's
  own supervisor is `:one_for_one` with the default restart intensity
  (3 in 5 seconds), and `RosBridge.Publishers.Detections` handles a
  cast at the stereo frame rate — so a bug that raises on every frame
  would exhaust that budget in about 200 ms and take the *whole*
  bridge down, cameras and depth included. The one thing the detector
  must never do.

  Under this supervisor the same bug restarts the detector up to ten
  times a minute and stops there, leaving the stereo pipeline
  untouched. Detections go away; depth does not.

  `:rest_for_one` because the publisher registers with the Port owner's
  process at `init/1` — if `Hailo` restarts, the publisher's inflight
  sequence and reply routing refer to a process that no longer exists,
  so it has to come back too. Not the reverse: `Hailo` knows nothing
  about who submits to it.
  """
  use Supervisor

  alias RosBridge.Inference.Hailo
  alias RosBridge.Publishers.Detections

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    children = [
      {Hailo,
       hef_path: Keyword.fetch!(opts, :hef_path),
       score_threshold: Keyword.get(opts, :score_threshold, 0.4)},
      {Detections, Keyword.drop(opts, [:hef_path, :score_threshold])}
    ]

    Supervisor.init(children,
      strategy: :rest_for_one,
      max_restarts: 10,
      max_seconds: 60
    )
  end
end
