defmodule Mix.Tasks.VisionCore.CompareExports do
  @shortdoc "Compares two vision debug exports"

  @moduledoc """
  Compares two zips of the vision unit's debug exporter, to see what a
  change did and whether it exceeds the noise:

      mix vision_core.compare_exports A.zip B.zip [--out DIR]

  Prints, B read against A: which export is which, with the hostname,
  time, firmware, change age, changes during the burst and status
  availability its manifest gives; the parameters whose value differs; the
  figures both exports measured, with their change and whether it stays
  within the spread; the stages' timings; and how the last pairs' pixels
  differ. A figure or a stage only one export has is named below its
  table. It writes the difference images of the last pairs,
  `disparity-diff.png` and `depth-diff.png`, to `DIR`, `compare-out` by
  default. See `VisionCore.Debug.Compare` for what each holds.

  Read a figure's change as noise when it is within the spread. A figure
  measured on fewer than 3 samples in either export, such as the status
  snapshots' figures, has no spread to judge by and reads `too few samples`.
  """
  use Mix.Task

  alias VisionCore.Debug.Compare

  @usage "mix vision_core.compare_exports A.zip B.zip [--out DIR]"
  @minimum_samples Compare.minimum_samples()

  @impl Mix.Task
  def run(args) do
    {options, paths} = OptionParser.parse!(args, strict: [out: :string])

    case paths do
      [path_a, path_b] -> compare(path_a, path_b, Keyword.get(options, :out, "compare-out"))
      _paths -> Mix.raise("usage: #{@usage}")
    end
  end

  defp compare(path_a, path_b, out) do
    Mix.Task.run("compile")
    report = report(read!(path_a), read!(path_b))

    File.mkdir_p!(out)

    written =
      for {name, png} <- Enum.sort(report.images) do
        path = Path.join(out, name)
        File.write!(path, png)
        path
      end

    Mix.shell().info(
      Enum.join(
        [
          export_table(report.exports, path_a, path_b),
          parameter_table(report.parameters),
          figure_table(report.figures, report.figures_only_in),
          timing_table(report.timings, report.timings_only_in),
          pixel_table(report.pixels),
          "Difference images:\n" <> Enum.map_join(written, "\n", &("  " <> &1))
        ],
        "\n\n"
      )
    )
  end

  defp read!(path) do
    case File.read(path) do
      {:ok, zip} -> zip
      {:error, reason} -> Mix.raise("cannot read #{path}: #{:file.format_error(reason)}")
    end
  end

  defp report(zip_a, zip_b) do
    Compare.compare(zip_a, zip_b)
  rescue
    error in ArgumentError -> Mix.raise(Exception.message(error))
  end

  defp export_table(exports, path_a, path_b) do
    "Exports\n" <>
      table(
        [
          "export",
          "hostname",
          "time",
          "firmware",
          "last change before the burst",
          "changes during the burst",
          "status",
          "file"
        ],
        for {label, path, info} <- [{"A", path_a, exports.a}, {"B", path_b, exports.b}] do
          [
            label,
            text(info.hostname),
            text(info.time),
            text(info.firmware),
            change_age(info.change_age_ms),
            text(info.changes_during_burst),
            status(info.status_available),
            path
          ]
        end
      )
  end

  defp text(nil), do: "-"
  defp text(value), do: to_string(value)

  defp change_age(nil), do: "none recorded"
  defp change_age(age_ms), do: "#{round(age_ms)} ms"

  defp status(true), do: "available"
  defp status(false), do: "unavailable"
  defp status(nil), do: "-"

  defp parameter_table([]), do: "Parameters: none differ"

  defp parameter_table(parameters) do
    "Parameters that differ\n" <>
      table(
        ["parameter", "A", "B"],
        for({id, a, b} <- parameters, do: [id, parameter_value(a), parameter_value(b)])
      )
  end

  defp parameter_value(nil), do: "-"
  defp parameter_value(value) when is_binary(value), do: value
  defp parameter_value(value) when is_number(value), do: number(value)
  defp parameter_value(value), do: inspect(value)

  defp figure_table(figures, only_in) do
    "Figures, change is B - A\n" <>
      table(
        [
          "figure",
          "A mean",
          "A std",
          "A n",
          "B mean",
          "B std",
          "B n",
          "change",
          "against spread"
        ],
        for figure <- figures do
          [
            figure.name,
            number(figure.a.mean),
            number(figure.a.std),
            number(figure.a.n),
            number(figure.b.mean),
            number(figure.b.std),
            number(figure.b.n),
            number(figure.delta),
            against_spread(figure)
          ]
        end
      ) <> only_in_lines("Figures", only_in)
  end

  defp against_spread(%{a: %{n: n_a}, b: %{n: n_b}}) when min(n_a, n_b) < @minimum_samples,
    do: "too few samples"

  defp against_spread(%{within_spread: true}), do: "within spread"
  defp against_spread(%{within_spread: false}), do: "beyond spread"

  defp timing_table(timings, only_in) do
    "Timings, in milliseconds\n" <>
      table(
        ["stage", "A median", "B median", "A p95", "B p95"],
        for timing <- timings do
          [
            timing.stage,
            number(timing.a_median),
            number(timing.b_median),
            number(timing.a_p95),
            number(timing.b_p95)
          ]
        end
      ) <> only_in_lines("Stages", only_in)
  end

  defp only_in_lines(subject, only_in) do
    for {label, names} <- [{"A", only_in.a}, {"B", only_in.b}], names != [], into: "" do
      "\n#{subject} only in #{label}: #{Enum.join(names, ", ")}"
    end
  end

  defp pixel_table(pixels) do
    "Last pairs' pixels\n" <>
      table([
        ["matched in both", number(pixels.both)],
        ["matched in A only", number(pixels.a_only)],
        ["matched in B only", number(pixels.b_only)],
        ["mean absolute disparity difference, px", number(pixels.mean_abs_disparity_px)],
        ["mean absolute depth difference, mm", number(pixels.mean_abs_depth_mm)]
      ])
  end

  defp number(nil), do: "-"
  defp number(count) when is_integer(count), do: Integer.to_string(count)
  defp number(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)

  defp table(header, rows), do: table([header | rows])

  defp table(rows) do
    widths =
      Enum.zip_with(rows, fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)

    Enum.map_join(rows, "\n", fn row ->
      row
      |> Enum.zip_with(widths, &String.pad_trailing/2)
      |> Enum.join("  ")
      |> String.trim_trailing()
    end)
  end
end
