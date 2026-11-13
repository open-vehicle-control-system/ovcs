defmodule VisionCore.Segmentation do
  @moduledoc """
  Road segmentation pipelines: each `:segmenter` component
  (`VisionCore.Components`) starts one under its own
  `VisionCore.Segmentation.Supervisor`, which classes each cell of a band
  of a camera's image among the Cityscapes classes and sorts the stereo
  points seen in that band into road and off-road
  (`VisionCore.Segmentation.Pipeline`).

  A segmentation pipeline is always named, by its `:name` option. Its
  name follows the rule of the detection pipelines' and shares their
  namespace and the cameras' (`VisionCore.Pipelines`): it keys the
  pipeline's processes (`VisionCore.Pipelines.server/2`), its
  `VisionCore.Outputs` key, its parameter groups (`<name>.*`), its
  exporters' output (`output/1`) and its ROS 2 topics.
  """

  @cityscapes_labels ~w(road sidewalk building wall fence pole traffic_light traffic_sign
                        vegetation terrain sky person rider car truck bus train motorcycle
                        bicycle)

  @doc "The 19 Cityscapes class names, indexed by class id: `road` is 0."
  @spec labels() :: [String.t()]
  def labels, do: @cityscapes_labels

  @doc "The classes that are road unless a pipeline's `:road_classes` says otherwise."
  @spec road_classes() :: [String.t()]
  def road_classes, do: ["road"]

  @doc """
  The name a segmenter's `opts` give, valid as a pipeline name
  (`VisionCore.Pipelines.name!/2`). Raises `ArgumentError` without one,
  or with one that breaks the rule.
  """
  @spec name!(keyword()) :: atom()
  def name!(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> VisionCore.Pipelines.name!(name, "a segmentation pipeline")
      :error -> raise ArgumentError, "a segmenter needs a :name, its pipeline's"
    end
  end

  @doc "The `VisionCore.Exporter` output of the segmentation pipeline `name`."
  @spec output(atom()) :: {:segmentation, atom()}
  def output(name), do: {:segmentation, name}

  @doc """
  The inference step of the segmentation pipeline `pipeline`,
  `<pipeline>.inference`, between its input and its classes, which its
  backend declares.
  """
  @spec inference_group(atom(), map()) :: VisionCore.Parameters.group_declaration()
  def inference_group(pipeline, fields),
    do: VisionCore.Parameters.step(pipeline, "inference", "Inference", 102, fields)
end
