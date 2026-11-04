defmodule VisionCore.Debug.Compare do
  @moduledoc """
  Compares two exports of `VisionCore.Debug.Export`, to tell what a change
  to the unit did and whether it exceeds the noise between exports of one
  setup. It reads each zip's `manifest.json`, `parameters.json`,
  `figures.json`, `timings.json`, `last/disparity.f32` and
  `last/depth.png`; `mix vision_core.compare_exports` prints the result.
  """

  alias VisionCore.Debug.Png

  @required_files ~w(
    manifest.json parameters.json figures.json timings.json
    last/disparity.f32 last/depth.png
  )
  @minimum_samples 3
  @disparity_grey_per_px 32
  @depth_grey_per_mm 0.25

  @type summary :: %{
          mean: number(),
          min: number(),
          max: number(),
          std: number(),
          n: non_neg_integer()
        }
  @type exporter :: %{
          hostname: String.t() | nil,
          time: String.t() | nil,
          firmware: String.t() | nil,
          change_age_ms: number() | nil,
          changes_during_burst: non_neg_integer() | nil,
          status_available: boolean() | nil
        }
  @type only_in :: %{a: [String.t()], b: [String.t()]}
  @type report :: %{
          exports: %{a: exporter(), b: exporter()},
          parameters: [{String.t(), term(), term()}],
          figures: [
            %{
              name: String.t(),
              a: summary(),
              b: summary(),
              delta: number(),
              within_spread: boolean()
            }
          ],
          timings: [
            %{
              stage: String.t(),
              a_median: number(),
              b_median: number(),
              a_p95: number(),
              b_p95: number()
            }
          ],
          pixels: %{
            both: non_neg_integer(),
            a_only: non_neg_integer(),
            b_only: non_neg_integer(),
            mean_abs_disparity_px: float() | nil,
            mean_abs_depth_mm: float() | nil
          },
          figures_only_in: only_in(),
          timings_only_in: only_in(),
          images: %{String.t() => binary()}
        }

  @doc "How many samples a figure needs in both exports for its spread to count."
  @spec minimum_samples() :: pos_integer()
  def minimum_samples, do: @minimum_samples

  @doc """
  Compares the export `zip_a` with the export `zip_b`, B read against A.
  Raises `ArgumentError`, with a message naming the export, the file and
  the problem, when a zip is not an export or a file of it is malformed,
  and when the two exports' images differ in size.

    * `:exports` — `%{a: info, b: info}`, what each export's manifest says
      of it: `hostname`, `time`, `firmware` (the revision), `change_age_ms`,
      `changes_during_burst` and `status_available`.
    * `:parameters` — `{id, a, b}` for each parameter whose value differs,
      by id. A parameter one export lacks reads `nil` in it.
    * `:figures` — for each figure both exports measured, by name,
      `%{name, a, b, delta, within_spread}`: `a` and `b` are the figure's
      summaries `%{mean, min, max, std, n}`, `delta` is `b.mean - a.mean`,
      and `within_spread` is `abs(delta) <= max(a.std, b.std)`, always
      `true` when either figure has fewer than 3 samples.
    * `:timings` — for each stage both exports timed, by name,
      `%{stage, a_median, b_median, a_p95, b_p95}`.
    * `:figures_only_in`, `:timings_only_in` — the names of the figures and
      of the stages only one export has, `%{a: names, b: names}`.
    * `:pixels` — the last pairs' pixels: `both`, `a_only` and `b_only` count
      the disparity-matched pixels (disparity above 0) in both exports and
      in one only; `mean_abs_disparity_px` is the mean absolute difference
      over `both`, and `mean_abs_depth_mm` over the pixels with a depth in
      both. A mean is `nil` where no pixel counts.
    * `:images` — `"disparity-diff.png"` and `"depth-diff.png"`, 8-bit grey
      PNGs of the image's size. A pixel is 255 where only one export has
      a value, 0 where neither has, and otherwise the absolute
      difference: `min(255, round(abs(da - db) * 32))` in pixels for the
      disparity, `min(255, round(abs(za - zb) / 4))` in millimetres for
      the depth.
  """
  @spec compare(binary(), binary()) :: report()
  def compare(zip_a, zip_b) do
    a = read_export(zip_a, "A")
    b = read_export(zip_b, "B")

    if a.size != b.size do
      raise ArgumentError,
            "the exports' images differ in size: A is #{dimensions(a.size)}, B is #{dimensions(b.size)}"
    end

    disparity = compare_samples(a.disparity, b.disparity, @disparity_grey_per_px)
    depth = compare_samples(a.depth, b.depth, @depth_grey_per_mm)
    {width, height} = a.size

    %{
      exports: %{a: a.info, b: b.info},
      parameters: parameters(a.parameters, b.parameters),
      figures: figures(a.figures, b.figures),
      figures_only_in: only_in(a.figures, b.figures),
      timings: timings(a.timings, b.timings),
      timings_only_in: only_in(a.timings, b.timings),
      pixels: %{
        both: disparity.both,
        a_only: disparity.a_only,
        b_only: disparity.b_only,
        mean_abs_disparity_px: mean(disparity),
        mean_abs_depth_mm: mean(depth)
      },
      images: %{
        "disparity-diff.png" => Png.grey(disparity.grey, width, height),
        "depth-diff.png" => Png.grey(depth.grey, width, height)
      }
    }
  end

  defp read_export(zip, label) do
    case parse_export(zip) do
      {:ok, export} -> export
      {:error, problem} -> raise ArgumentError, "export #{label}: #{problem}"
    end
  end

  defp parse_export(zip) do
    with {:ok, files} <- unzip(zip),
         :ok <- require_files(files),
         {:ok, manifest} <- read_json(files, "manifest.json", &check_manifest/1),
         {:ok, parameters} <- read_json(files, "parameters.json", &check_parameters/1),
         {:ok, figures} <- read_json(files, "figures.json", &check_figures/1),
         {:ok, timings} <- read_json(files, "timings.json", &check_timings/1),
         {:ok, disparity} <- disparity(files["last/disparity.f32"], manifest.size),
         {:ok, depth} <- depth(files["last/depth.png"], manifest.size) do
      {:ok,
       %{
         size: manifest.size,
         info: manifest.info,
         parameters: parameters,
         figures: figures,
         timings: timings,
         disparity: disparity,
         depth: depth
       }}
    end
  end

  defp unzip(zip) do
    case :zip.unzip(zip, [:memory]) do
      {:ok, entries} ->
        {:ok,
         Map.new(entries, fn {name, content} ->
           {name |> List.to_string() |> String.split("/", parts: 2) |> List.last(), content}
         end)}

      {:error, reason} ->
        {:error, "not a readable zip archive (#{inspect(reason)})"}
    end
  end

  defp require_files(files) do
    case Enum.find(@required_files, &(not is_map_key(files, &1))) do
      nil -> :ok
      missing -> {:error, "#{missing} is missing"}
    end
  end

  defp read_json(files, name, check) do
    with {:ok, decoded} <- decode_json(files[name]),
         {:ok, checked} <- check.(decoded) do
      {:ok, checked}
    else
      {:error, problem} -> {:error, "#{name} #{problem}"}
    end
  end

  defp decode_json(content) do
    case Jason.decode(content) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _error} -> {:error, "is not valid JSON"}
    end
  end

  defp check_manifest(%{"imageSize" => %{"width" => width, "height" => height}} = manifest)
       when is_integer(width) and is_integer(height) and width > 0 and height > 0 do
    firmware = with %{"revision" => revision} <- manifest["firmware"], do: revision

    info = %{
      hostname: manifest["hostname"],
      time: manifest["time"],
      firmware: if(is_binary(firmware), do: firmware),
      change_age_ms: manifest["changeAgeMs"],
      changes_during_burst: manifest["changesDuringBurst"],
      status_available: manifest["statusAvailable"]
    }

    {:ok, %{size: {width, height}, info: info}}
  end

  defp check_manifest(_manifest),
    do: {:error, "has no imageSize with a positive integer width and height"}

  defp check_parameters(parameters) when is_list(parameters) do
    if Enum.all?(parameters, &match?(%{"id" => _id}, &1)),
      do: {:ok, Map.new(parameters, &{&1["id"], &1["value"]})},
      else: {:error, "has a parameter without an id"}
  end

  defp check_parameters(_parameters), do: {:error, "is not a list of parameters"}

  defp check_figures(%{"summary" => summary}) when is_map(summary) do
    case Enum.find(summary, fn {_name, figure} -> not numbers?(figure, ~w(mean min max std n)) end) do
      nil ->
        {:ok, Map.new(summary, fn {name, figure} -> {name, summary(figure)} end)}

      {name, _figure} ->
        {:error, "summary of #{name} lacks a number for mean, min, max, std or n"}
    end
  end

  defp check_figures(_figures), do: {:error, "has no summary"}

  defp summary(%{"mean" => mean, "min" => min, "max" => max, "std" => std, "n" => n}),
    do: %{mean: mean, min: min, max: max, std: std, n: n}

  defp check_timings(timings) when is_map(timings) do
    case Enum.find(timings, fn {_stage, timing} -> not numbers?(timing, ~w(median p95)) end) do
      nil -> {:ok, timings}
      {stage, _timing} -> {:error, "stage #{stage} lacks a number for median or p95"}
    end
  end

  defp check_timings(_timings), do: {:error, "is not a map of stages"}

  defp numbers?(map, keys) when is_map(map), do: Enum.all?(keys, &is_number(map[&1]))
  defp numbers?(_other, _keys), do: false

  defp disparity(bytes, {width, height} = size) do
    if byte_size(bytes) == width * height * 4,
      do: {:ok, for(<<disparity::float-32-little <- bytes>>, do: disparity)},
      else: {:error, "last/disparity.f32 does not fill a #{dimensions(size)} image"}
  end

  defp depth(png, {width, height} = size) do
    case Png.decode(png) do
      {:ok, %{width: ^width, height: ^height, bit_depth: 16, colour: :grey, pixels: pixels}} ->
        {:ok, for(<<millimetres::16-little <- pixels>>, do: millimetres)}

      {:ok, _other} ->
        {:error, "last/depth.png is not a 16-bit grey #{dimensions(size)} image"}

      {:error, reason} ->
        {:error, "last/depth.png cannot be read (#{inspect(reason)})"}
    end
  end

  defp dimensions({width, height}), do: "#{width}x#{height}"

  defp parameters(values_a, values_b) do
    for id <- Enum.sort(Enum.uniq(Map.keys(values_a) ++ Map.keys(values_b))),
        values_a[id] != values_b[id],
        do: {id, values_a[id], values_b[id]}
  end

  defp figures(summaries_a, summaries_b) do
    for name <- common_names(summaries_a, summaries_b) do
      a = summaries_a[name]
      b = summaries_b[name]
      delta = b.mean - a.mean

      %{name: name, a: a, b: b, delta: delta, within_spread: within_spread?(a, b, delta)}
    end
  end

  defp within_spread?(%{n: n_a}, %{n: n_b}, _delta) when min(n_a, n_b) < @minimum_samples,
    do: true

  defp within_spread?(a, b, delta), do: abs(delta) <= max(a.std, b.std)

  defp timings(timings_a, timings_b) do
    for stage <- common_names(timings_a, timings_b) do
      %{
        stage: stage,
        a_median: timings_a[stage]["median"],
        b_median: timings_b[stage]["median"],
        a_p95: timings_a[stage]["p95"],
        b_p95: timings_b[stage]["p95"]
      }
    end
  end

  defp common_names(map_a, map_b),
    do: for(name <- Enum.sort(Map.keys(map_a)), is_map_key(map_b, name), do: name)

  defp only_in(map_a, map_b), do: %{a: missing_from(map_a, map_b), b: missing_from(map_b, map_a)}

  defp missing_from(map, other),
    do: for(name <- Enum.sort(Map.keys(map)), not is_map_key(other, name), do: name)

  defp compare_samples(samples_a, samples_b, grey_per_unit) do
    initial = %{grey: [], both: 0, a_only: 0, b_only: 0, difference_sum: 0}

    tally =
      Enum.zip_reduce(samples_a, samples_b, initial, fn sample_a, sample_b, tally ->
        tally_sample(sample_a, sample_b, grey_per_unit, tally)
      end)

    %{tally | grey: tally.grey |> Enum.reverse() |> :binary.list_to_bin()}
  end

  defp tally_sample(sample_a, sample_b, grey_per_unit, tally)
       when sample_a > 0 and sample_b > 0 do
    difference = abs(sample_a - sample_b)
    grey = min(255, round(difference * grey_per_unit))

    %{
      tally
      | grey: [grey | tally.grey],
        both: tally.both + 1,
        difference_sum: tally.difference_sum + difference
    }
  end

  defp tally_sample(sample_a, _sample_b, _grey_per_unit, tally) when sample_a > 0,
    do: %{tally | grey: [255 | tally.grey], a_only: tally.a_only + 1}

  defp tally_sample(_sample_a, sample_b, _grey_per_unit, tally) when sample_b > 0,
    do: %{tally | grey: [255 | tally.grey], b_only: tally.b_only + 1}

  defp tally_sample(_sample_a, _sample_b, _grey_per_unit, tally),
    do: %{tally | grey: [0 | tally.grey]}

  defp mean(%{both: 0}), do: nil
  defp mean(%{both: both, difference_sum: difference_sum}), do: difference_sum / both
end
