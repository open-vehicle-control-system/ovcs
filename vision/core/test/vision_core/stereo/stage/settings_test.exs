defmodule VisionCore.Stereo.Stage.SettingsTest do
  # Every stage the framework provides takes what its option_specs/0
  # declare, and nothing else.
  use ExUnit.Case, async: true

  import VisionCore.Stereo.TestHelpers, only: [context: 3]

  alias VisionCore.Stereo.Stage

  @stages for module <- Application.spec(:vision_core, :modules),
              match?(["VisionCore", "Stereo", "Stage", _name], Module.split(module)),
              do: module

  setup_all do
    %{context: context(:identity, 64, 48)}
  end

  test "finds the stages the framework provides" do
    assert Stage.Decode in @stages
    assert Stage.Disparity in @stages
    assert Stage.Quality in @stages
  end

  for stage <- @stages do
    Code.ensure_loaded!(stage)
    specs = if function_exported?(stage, :option_specs, 0), do: stage.option_specs(), else: []
    live = for {key, spec} <- specs, Map.get(spec, :applies, :live) == :live, do: key

    describe inspect(stage) do
      @describetag stage: stage

      test "starts on its defaults, listing every setting within its spec",
           %{stage: stage, context: context} do
        assert {:ok, state} = stage.init([], context)
        values = options(stage, state)
        specs = specs(stage)

        assert Enum.sort(Map.keys(values)) == Enum.sort(Keyword.keys(specs))

        for {key, spec} <- specs do
          assert within?(spec, values[key]), "#{key}'s default #{inspect(values[key])}"
        end

        for {key, %{greater_than: other}} <- specs, do: assert(values[key] > values[other])
      end

      test "refuses an option it does not declare", %{stage: stage, context: context} do
        assert stage.init([not_a_setting: 1], context) ==
                 {:error, "not_a_setting is not a setting"}
      end

      if specs != [] do
        test "takes each bound of its settings and refuses the values just outside",
             %{stage: stage, context: context} do
          specs = specs(stage)

          for {key, spec} <- specs do
            {inside, outside} = bounds(spec)
            related = related(specs, key)

            for value <- inside do
              assert {:ok, state} = stage.init(related ++ [{key, value}], context),
                     "#{key}: #{inspect(value)} refused"

              assert options(stage, state)[key] == value
            end

            for value <- outside do
              assert {:error, message} = stage.init(related ++ [{key, value}], context)
              assert message =~ ~r/^#{key} must be /
            end

            if live?(spec) do
              {:ok, state} = stage.init(related, context)

              for value <- inside do
                assert {:ok, changed} = stage.set_option(state, key, value)
                assert options(stage, changed)[key] == value
              end

              for value <- outside do
                assert {:error, message} = stage.set_option(state, key, value)
                assert message =~ ~r/^#{key} must be /
              end
            end
          end
        end
      end

      if live != [] do
        test "set_option/3 refuses what it cannot change, without raising",
             %{stage: stage, context: context} do
          {:ok, state} = stage.init([], context)
          specs = specs(stage)
          values = options(stage, state)
          [first | _keys] = Keyword.keys(specs)

          for key <- [:not_a_setting, Atom.to_string(first), {first}] do
            assert {:error, message} = stage.set_option(state, key, values[first])
            assert message =~ ~r/ is not a setting$/
          end

          for {key, spec} <- specs, not live?(spec) do
            assert stage.set_option(state, key, values[key]) ==
                     {:error, "#{key} is fixed when the stage starts"}
          end

          for {key, spec} <- specs, live?(spec), value <- [{1, 2}, nil, %{}] do
            assert {:error, message} = stage.set_option(state, key, value)
            assert message =~ ~r/^#{key} must be /
          end
        end

        test "each live setting changes its params, the compiled function's inputs",
             %{stage: stage, context: context} do
          {:ok, state} = stage.init([], context)
          values = options(stage, state)

          for {key, spec} <- specs(stage), live?(spec) do
            {inside, _outside} = bounds(spec)

            changes =
              for value <- inside,
                  value != values[key],
                  {:ok, changed} <- [stage.set_option(state, key, value)],
                  do: changed

            assert [changed | _] = changes, "no other value of #{key} taken"

            refute comparable(stage.params(changed, context)) ==
                     comparable(stage.params(state, context)),
                   "#{key} does not reach the params"
          end
        end
      end
    end
  end

  defp specs(stage) do
    if function_exported?(stage, :option_specs, 0), do: stage.option_specs(), else: []
  end

  defp options(stage, state) do
    if function_exported?(stage, :options, 1), do: stage.options(state), else: %{}
  end

  defp live?(spec), do: Map.get(spec, :applies, :live) == :live

  # A spec's lowest and highest values, and those just outside its range.
  defp bounds(%{type: :string, values: values}), do: {values, ["not_a_choice", 1]}
  defp bounds(%{values: values}), do: {values, [Enum.min(values) - 1, Enum.max(values) + 1]}

  defp bounds(%{type: :integer, range: {min, max}} = spec),
    do: {[min, highest(spec)], [min - 1, max + 1]}

  defp bounds(%{type: :double, range: {min, max}} = spec),
    do: {[min * 1.0, highest(spec) * 1.0], [min - 1.0e-6, max + 1.0e-6]}

  defp bounds(%{type: :bool}), do: {[false, true], [nil, 1]}

  # A range's highest value on its step, which counts from its minimum.
  defp highest(%{range: {min, max}, step: step}) when is_number(step),
    do: min + trunc((max - min) / step) * step

  defp highest(%{range: {_min, max}}), do: max

  # The settings ordered against `key`, where they leave it free to reach both of its bounds.
  # Other settings a value of `key` is only taken with: Disparity searches coarse to fine
  # over 128 disparities.
  @needs %{search: [num_disparities: 128]}

  defp related(specs, key) do
    lower = for {^key, %{greater_than: other}} <- specs, do: {other, lowest(specs[other])}
    higher = for {other, %{greater_than: ^key}} <- specs, do: {other, highest(specs[other])}
    lower ++ higher ++ Map.get(@needs, key, [])
  end

  defp lowest(%{range: {min, _max}}), do: min

  defp within?(%{type: :integer} = spec, value) when is_integer(value), do: accepts?(spec, value)
  defp within?(%{type: :double} = spec, value) when is_float(value), do: accepts?(spec, value)
  defp within?(%{type: :bool}, value), do: is_boolean(value)
  defp within?(%{type: :string} = spec, value) when is_binary(value), do: accepts?(spec, value)
  defp within?(_spec, _value), do: false

  defp accepts?(%{values: values}, value), do: value in values

  defp accepts?(%{range: {min, max}} = spec, value),
    do: value >= min and value <= max and on_step?(spec, value)

  defp accepts?(_spec, _value), do: true

  defp on_step?(%{range: {min, _max}, step: step}, value) when is_number(step) do
    steps = (value - min) / step
    abs(steps - round(steps)) < 1.0e-9
  end

  defp on_step?(_spec, _value), do: true

  defp comparable(%Nx.Tensor{} = tensor), do: Nx.to_flat_list(tensor)
  defp comparable(%{} = map), do: Map.new(map, fn {key, value} -> {key, comparable(value)} end)
  defp comparable(value), do: value
end
