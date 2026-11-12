defmodule VisionCore.Segmentation.Backend.Stub do
  @moduledoc """
  A segmentation backend that runs no model and answers every band with
  the same label image, for proving the plumbing without an accelerator.
  As `VisionCore.Detection.Backend.Stub`, it is never the default and
  says so in its log on every start: classes on a screen look as
  convincing whether or not a model found them.

  ## Options

    * `:name` (the module) — the name it registers under.
    * `:pipeline` — the segmentation pipeline whose inference step it
      declares.
    * `:classes` — unused: its label image is fixed.
    * `:label_image` — the `%{width:, height:, data:}` it answers with.
      Defaults to a 4 × 2 grid, its top row `sky` (10) and its bottom
      row `road` (0).
  """
  use GenServer

  @behaviour VisionCore.Segmentation.Backend

  require Logger

  @default_label_image %{width: 4, height: 2, data: <<10, 10, 10, 10, 0, 0, 0, 0>>}
  @explanation "Returns the same classes for every image without running any model, to test " <>
                 "segmentation's plumbing without an accelerator. Its classes are not a " <>
                 "segmentation: never use it on a vehicle. It has no settings."

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl VisionCore.Segmentation.Backend
  def segment(server \\ __MODULE__, sequence, band),
    do: GenServer.call(server, {:segment, sequence, band, self()})

  @impl VisionCore.Segmentation.Backend
  def available?(_server \\ __MODULE__), do: true

  @impl VisionCore.Segmentation.Backend
  def options, do: [:label_image]

  @impl VisionCore.Segmentation.Backend
  def npu_kind, do: nil

  @doc "Always `nil`: it runs no model."
  @impl VisionCore.Segmentation.Backend
  def inference_times(_server \\ __MODULE__), do: nil

  @impl GenServer
  def init(opts) do
    label_image = Keyword.get(opts, :label_image, @default_label_image)

    Logger.warning(
      "#{__MODULE__}: fabricating a #{label_image.width}x#{label_image.height} label image " <>
        "per frame — no model is running. Never enable this on a vehicle."
    )

    if Process.whereis(VisionCore.Parameters) do
      :ok =
        VisionCore.Parameters.declare([
          VisionCore.Segmentation.inference_group(Keyword.fetch!(opts, :pipeline), %{
            summary: "Returns fixed classes, without a model, to test the plumbing.",
            explanation: @explanation,
            compute: %{runs_on: :cpu, implementation: :elixir, backend: nil},
            parameters: []
          })
        ])
    end

    {:ok, %{label_image: label_image}}
  end

  @impl GenServer
  def handle_call({:segment, sequence, _band, reply_to}, _from, state) do
    send(reply_to, {:inference_labels, sequence, state.label_image})
    {:reply, :ok, state}
  end
end
