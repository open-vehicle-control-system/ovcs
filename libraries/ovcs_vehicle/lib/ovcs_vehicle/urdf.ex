defmodule OvcsVehicle.URDF do
  @moduledoc """
  A vehicle's expanded URDF, read for the dimensions its joints and
  links carry.

  The xacro is the source; `mise run urdf` (`scripts/expand_urdf.sh`)
  expands it into the `.urdf` committed beside it, and CI checks the
  two agree. Read it at compile time, so a firmware carries the values
  rather than the file:

      @urdf_path Path.expand("../description/<vehicle>.urdf", __DIR__)
      @external_resource @urdf_path
      @urdf OvcsVehicle.URDF.read!(@urdf_path)
  """

  @type vector :: {float(), float(), float()}

  @type joint :: %{
          name: String.t(),
          type: String.t(),
          parent: String.t(),
          child: String.t(),
          xyz: vector(),
          rpy: vector(),
          limit: {float(), float()} | nil
        }

  @type cylinder :: %{radius: float(), length: float()}

  @type t :: %{
          joints: %{String.t() => joint()},
          collision_cylinders: %{String.t() => cylinder()}
        }

  @spec read!(Path.t()) :: t()
  def read!(path) do
    {robot, _rest} = path |> String.to_charlist() |> :xmerl_scan.file(quiet: true)

    %{
      joints: robot |> nodes("/robot/joint") |> Map.new(&{text(&1, "@name"), joint(&1)}),
      collision_cylinders:
        robot
        |> nodes("/robot/link[collision/geometry/cylinder]")
        |> Map.new(&{text(&1, "@name"), cylinder(&1)})
    }
  end

  @spec joint!(t(), String.t()) :: joint()
  def joint!(%{joints: joints}, name), do: Map.fetch!(joints, name)

  @doc "The first cylinder among a link's collision geometry."
  @spec collision_cylinder!(t(), String.t()) :: cylinder()
  def collision_cylinder!(%{collision_cylinders: cylinders}, link),
    do: Map.fetch!(cylinders, link)

  defp joint(node) do
    %{
      name: text(node, "@name"),
      type: text(node, "@type"),
      parent: text(node, "parent/@link"),
      child: text(node, "child/@link"),
      xyz: vector(text(node, "origin/@xyz")),
      rpy: vector(text(node, "origin/@rpy")),
      limit: limit(text(node, "limit/@lower"), text(node, "limit/@upper"))
    }
  end

  defp cylinder(link) do
    %{
      radius: number(text(link, "collision/geometry/cylinder/@radius")),
      length: number(text(link, "collision/geometry/cylinder/@length"))
    }
  end

  defp limit(nil, nil), do: nil
  defp limit(lower, upper), do: {number(lower), number(upper)}

  defp vector(nil), do: {0.0, 0.0, 0.0}

  defp vector(text) do
    [x, y, z] = text |> String.split() |> Enum.map(&number/1)
    {x, y, z}
  end

  defp number(text) do
    {value, ""} = Float.parse(text)
    value
  end

  defp nodes(node, path), do: :xmerl_xpath.string(String.to_charlist(path), node)

  # The first match's value, or nil when there is none.
  defp text(node, path) do
    case :xmerl_xpath.string(String.to_charlist("string(#{path})"), node) do
      {:xmlObj, :string, []} -> nil
      {:xmlObj, :string, value} -> List.to_string(value)
    end
  end
end
