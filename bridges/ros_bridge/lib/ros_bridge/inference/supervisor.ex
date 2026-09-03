defmodule RosBridge.Inference.Supervisor do
  @moduledoc """
  Supervises the detection unit: an inference backend followed by the
  publisher that fuses its boxes with stereo depth.

  Which backend is `:backend`, defaulting to
  `RosBridge.Inference.Hailo` so the vehicle's wiring is unchanged.
  See `RosBridge.Inference` for the alternatives — `Dnn` for CPU or
  OpenCL on a workstation, `Stub` for plumbing only.

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

  `:rest_for_one` because a backend restart strands the publisher:
  `Detections` holds the `Result` whose frame is at the accelerator
  and waits for a reply keyed on its sequence number. That reply is
  never coming, and nothing times it out on the publisher's side, so
  it would sit holding a stale depth map and submitting frames whose
  answers it then discards as stale. Restarting it alongside clears
  that. Not the reverse: a backend is told where to reply on every
  call and holds nothing across one.
  """
  use Supervisor

  alias RosBridge.Publishers.Detections

  @default_backend RosBridge.Inference.Hailo

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    {backend, backend_opts} = backend(opts)

    children = [
      {backend, backend_opts},
      # The backend module is also its registered name, so the
      # publisher needs nothing but the module to reach it.
      {Detections, opts |> Keyword.drop(backend_keys()) |> Keyword.put(:inference, backend)}
    ]

    Supervisor.init(children,
      strategy: :rest_for_one,
      max_restarts: 10,
      max_seconds: 60
    )
  end

  # Backend-specific opts are passed through rather than enumerated, so
  # adding a backend does not mean editing this list. Only the keys the
  # publisher must not see are named.
  defp backend(opts) do
    backend = Keyword.get(opts, :backend, @default_backend)
    {backend, Keyword.take(opts, backend_keys())}
  end

  defp backend_keys do
    [:hef_path, :model_path, :target, :score_threshold, :nms_threshold, :input_size, :boxes]
  end
end
