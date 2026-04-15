defmodule OvcsCli.Prompt do
  @moduledoc """
  Small interactive selection helper. Falls back to a clear error on
  non-interactive shells (CI, pipes) so we never hang waiting for input.
  """

  @doc """
  Ask the user to pick one of `choices`. `label` is shown in the banner.

  Each choice is a string. Returns the chosen string. Exits the escript
  if stdin is not a tty or the user bails out (empty input, Ctrl-D).
  """
  @spec choose!(String.t(), [String.t()]) :: String.t()
  def choose!(_label, []) do
    IO.puts(IO.ANSI.red() <> "No options to choose from." <> IO.ANSI.reset())
    System.halt(1)
  end

  def choose!(label, choices) do
    unless interactive?() do
      IO.puts(
        IO.ANSI.red() <>
          "#{label} not provided and stdin is not interactive. " <>
          "Pass it on the command line." <> IO.ANSI.reset()
      )

      System.halt(2)
    end

    IO.puts("")
    IO.puts(IO.ANSI.bright() <> "Select #{label}:" <> IO.ANSI.reset())

    choices
    |> Enum.with_index(1)
    |> Enum.each(fn {c, i} ->
      IO.puts("  #{IO.ANSI.cyan()}#{i}#{IO.ANSI.reset()}. #{c}")
    end)

    prompt(choices, label)
  end

  defp prompt(choices, label) do
    input = IO.gets("> ") |> to_string() |> String.trim()

    cond do
      input == "" ->
        IO.puts(IO.ANSI.yellow() <> "Aborted." <> IO.ANSI.reset())
        System.halt(130)

      Enum.member?(choices, input) ->
        input

      match?({_, ""}, Integer.parse(input)) ->
        case Integer.parse(input) do
          {n, ""} when n in 1..length(choices) ->
            Enum.at(choices, n - 1)

          _ ->
            reprompt(choices, label)
        end

      true ->
        reprompt(choices, label)
    end
  end

  defp reprompt(choices, label) do
    IO.puts(IO.ANSI.red() <> "Invalid selection." <> IO.ANSI.reset())
    prompt(choices, label)
  end

  defp interactive? do
    # :stdout or :stdin can be non-tty in pipes; check both.
    case :io.getopts(:standard_io) do
      opts when is_list(opts) -> Keyword.get(opts, :terminal, false)
      _ -> false
    end
  end
end
