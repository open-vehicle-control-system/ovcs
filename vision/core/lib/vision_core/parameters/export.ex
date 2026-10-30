defmodule VisionCore.Parameters.Export do
  @moduledoc """
  Renders saved parameter values as the composer snippets that make them
  built-in defaults.

  A parameter's export path says where its value goes: `[field, key…]` for a
  `VisionCore.Config` field, `[:components, component, key…]` for a
  component's options. A component's `:stages` render as
  `VisionCore.Stereo.Pipeline.default_stages/1` overrides. A value without a
  path is listed as not settable in the composer; one of a parameter not
  declared now, whose path is unknown, is listed apart.
  """

  @type path :: [atom()] | nil | :not_running

  @doc """
  The snippets for `rows`, each `{path, parameter id, value}`: the export
  path, `nil` without one, or `:not_running` for a parameter not declared now.
  """
  @spec render([{path(), String.t(), term()}]) :: String.t()
  def render([]), do: "# Nothing saved.\n"

  def render(rows) do
    {not_running, rows} = Enum.split_with(rows, &match?({:not_running, _id, _value}, &1))
    {unexported, exported} = Enum.split_with(rows, fn {path, _id, _value} -> is_nil(path) end)
    {components, config} = Enum.split_with(exported, &match?({[:components | _], _, _}, &1))

    sections =
      config_section(config) ++
        component_sections(components) ++
        listed_section("Not settable in the composer", unexported) ++
        listed_section("Saved for parameters not running now", not_running)

    Enum.join(sections, "\n")
  end

  defp config_section([]), do: []

  defp config_section(rows),
    do: ["# In the composer's VisionCore.Config:\n" <> render_options(tree(rows), false)]

  defp component_sections(rows) do
    rows
    |> Enum.group_by(fn {[:components, component | _], _id, _value} -> component end)
    |> Enum.sort()
    |> Enum.map(fn {component, rows} ->
      options =
        rows
        |> Enum.map(fn {[:components, _component | path], id, value} -> {path, id, value} end)
        |> tree()

      "# In the options of the #{component} component ({#{inspect(component)}, opts}):\n" <>
        render_options(options, true)
    end)
  end

  defp listed_section(_header, []), do: []

  defp listed_section(header, rows) do
    lines =
      rows
      |> Enum.sort_by(fn {_path, id, _value} -> id end)
      |> Enum.map_join(fn {_path, id, value} -> "# #{id} = #{inspect(value)}\n" end)

    ["# #{header}:\n" <> lines]
  end

  defp tree(rows) do
    Enum.reduce(rows, %{}, fn {path, _id, value}, tree ->
      put_in(tree, Enum.map(path, &Access.key(&1, %{})), {:value, value})
    end)
  end

  defp render_options(tree, component?) do
    tree
    |> Enum.sort()
    |> Enum.map_join(",\n", fn
      {:stages, stages} when component? and is_map(stages) ->
        "stages: VisionCore.Stereo.Pipeline.default_stages(#{render_keyword(stages)})"

      {key, subtree} ->
        render_entry(key, subtree)
    end)
    |> Kernel.<>("\n")
  end

  defp render_entry(key, {:value, value}), do: "#{key}: #{inspect(value)}"
  defp render_entry(key, subtree), do: "#{key}: [#{render_keyword(subtree)}]"

  defp render_keyword(tree) do
    tree
    |> Enum.sort()
    |> Enum.map_join(", ", fn {key, subtree} -> render_entry(key, subtree) end)
  end
end
