defmodule VisionCore.Segmentation.Backend.Hailo do
  @moduledoc """
  Segmentation on the Hailo-8: the lane of `VisionCore.Hailo` named
  after the pipeline, the one Port that runs the unit's networks on the
  accelerator. A segmentation unit with this
  backend starts no backend of its own: the vision core starts
  `VisionCore.Hailo` from the unit's options
  (`VisionCore.Components.hailo_children/1`), and the unit restarts
  with it (`VisionCore.Inference.Watch`).

  The model is a HEF whose argmax is in-graph, scoring the Cityscapes
  classes: `hailo` resizes the band to its input and answers a class id
  for each `:cell_pixels` square cell of it, as
  `VisionCore.Segmentation.Backend` describes the labels.

  ## Options

  The unit's, which `VisionCore.Hailo` takes as the pipeline's network:

    * `:hef_path` — the model (required).
    * `:cell_pixels` (`8`) — the side of the cells a label stands for,
      in the model's input pixels.

  and the Port's: `:executable`, `:working_directory`, `:library_path`,
  `:infer_timeout_ms` and `:reopen_delays_ms` (`VisionCore.Hailo`).
  """
  @behaviour VisionCore.Segmentation.Backend

  alias VisionCore.Inference.PortBackend
  alias VisionCore.Stereo.Parameters

  @explanation "Classes each part of the image on the Hailo-8 among the 19 Cityscapes " <>
                 "classes: road, sidewalk, buildings, vegetation, sky, people, vehicles and " <>
                 "the others. The model sees the band of the image the input step picks, " <>
                 "resized to its input, and gives a class for each square cell of it. The " <>
                 "model and the cell size are fixed in the build. The accelerator runs its " <>
                 "networks in turn."

  @doc "The process every unit with this backend shares: `VisionCore.Hailo`."
  @spec shared_process() :: module()
  def shared_process, do: VisionCore.Hailo

  @doc "The server the unit `name` submits to: its pipeline's lane of `VisionCore.Hailo`."
  @spec shared_server(atom()) :: {module(), atom()}
  def shared_server(name), do: {VisionCore.Hailo, name}

  @impl VisionCore.Segmentation.Backend
  def segment({process, lane}, sequence, band),
    do: PortBackend.submit(process, lane, sequence, band)

  @doc "True: `hailo` decodes a JPEG frame itself, so only the JPEG crosses its Port."
  @impl VisionCore.Segmentation.Backend
  def decodes_jpeg?, do: true

  @impl VisionCore.Segmentation.Backend
  def available?({process, _lane}), do: PortBackend.available?(process)

  @impl VisionCore.Segmentation.Backend
  def state({process, _lane}), do: PortBackend.state(process)

  @impl VisionCore.Segmentation.Backend
  def options,
    do:
      [:hef_path, :cell_pixels, :executable, :working_directory, :library_path] ++
        PortBackend.options()

  @impl VisionCore.Segmentation.Backend
  def npu_kind, do: "Hailo-8"

  @impl VisionCore.Segmentation.Backend
  def inference_times({process, lane}),
    do: PortBackend.inference_times(process, lane)

  @doc """
  The inference step of the segmentation pipeline `settings.pipeline`,
  which `VisionCore.Hailo` declares: its model, classes and cell size.
  """
  @spec inference_group(%{
          :pipeline => atom(),
          :hef_path => Path.t(),
          :classes => pos_integer(),
          :cell_pixels => pos_integer(),
          optional(atom()) => term()
        }) :: VisionCore.Parameters.group_declaration()
  def inference_group(settings) do
    VisionCore.Segmentation.inference_group(settings.pipeline, %{
      summary: "Classes each part of the image on the Hailo-8.",
      explanation: @explanation,
      compute: %{runs_on: :npu, implementation: :rust, backend: nil},
      parameters: [
        Parameters.build_parameter(
          {:model, Path.basename(settings.hef_path)},
          "The compiled model the accelerator runs"
        ),
        Parameters.build_parameter(
          {:classes, settings.classes},
          "Classes the model scores, as many as the pipeline names"
        ),
        Parameters.build_parameter(
          {:cell_pixels, settings.cell_pixels},
          "Side of the cells a class stands for, in the model's pixels"
        )
      ]
    })
  end
end
