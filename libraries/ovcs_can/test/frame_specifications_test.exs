defmodule OvcsCan.FrameSpecificationsTest do
  @moduledoc """
  Every component frame loads through Cantastic, in both directions, as
  a firmware loads its topology at boot: a frame Cantastic rejects
  stops the firmware that imports it.
  """
  use ExUnit.Case, async: true

  @components Path.expand("../priv/can/components", __DIR__)

  # The `0x7X…_signals.yml` files are signal lists the vehicles' generic controller frames import.
  for path <- Path.wildcard(Path.join(@components, "**/0x*.yml")),
      not String.ends_with?(path, "_signals.yml") do
    relative = Path.relative_to(path, @components)

    test "#{relative} loads as a received and an emitted frame" do
      frame = read!(unquote(path))

      for direction <- [:received, :emitted] do
        assert {:ok, _} = Cantastic.FrameSpecification.from_yaml(:test, frame, direction)
      end
    end
  end

  defp read!(path) do
    {:ok, yaml} = YamlElixir.read_from_file(path, atoms: true, merge_anchors: true)
    yaml |> Jason.encode!() |> Jason.decode!(keys: :atoms) |> resolve(Path.dirname(path))
  end

  defp resolve(node, base) when is_map(node),
    do: Map.new(node, fn {k, v} -> {k, resolve(v, base)} end)

  defp resolve(node, base) when is_list(node), do: Enum.map(node, &resolve(&1, base))

  defp resolve("import!:@ovcs_can:" <> relative, _base),
    do: read!(Path.expand("../priv/" <> relative, __DIR__))

  defp resolve("import!:" <> relative, base), do: read!(Path.join(base, relative))
  defp resolve(node, _base), do: node
end
