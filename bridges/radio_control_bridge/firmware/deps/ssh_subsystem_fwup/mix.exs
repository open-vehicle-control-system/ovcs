defmodule SSHSubsystemFwup.MixProject do
  use Mix.Project

  @version "0.6.2"
  @source_url "https://github.com/nerves-project/ssh_subsystem_fwup"

  with {:ok, path} <- File.cwd(),
       true <- String.ends_with?(path, "deps/ssh_subsystem_fwup"),
       root <- String.replace(path, "deps/ssh_subsystem_fwup", ""),
       script_path <- Path.join(root, "upload.sh"),
       true <- File.exists?(script_path),
       {line, line_num} <-
         File.stream!(script_path)
         |> Stream.with_index(1)
         |> Enum.find(fn {line, _i} -> line =~ ~r/-p 8989.*nerves_firmware_ssh/ end) do
    msg = """
    You have an incompatible version of the upload.sh script which will attempt
    to update using SSH subsystem nerves_firmware_ssh on port 8989

    Please update the script by regenerating with:

      #{IO.ANSI.cyan()}mix firmware.gen.script#{IO.ANSI.default_color()}

    Or manually update by changing #{script_path}:#{line_num} ¬

      #{IO.ANSI.red()}- #{String.trim(line)}
      #{IO.ANSI.green()}+ cat "$FILENAME" | ssh -s $SSH_OPTIONS $DESTINATION fwup#{IO.ANSI.default_color()}

    NOTE: If you plan to do an over the air update of your system (as explained
    at https://github.com/nerves-project/nerves_ssh#upgrade-from-nervesfirmwaressh)
    Then you should not update your upload.sh script until after you send an
    updated firmware image to your device.
    """

    :elixir_errors.io_warn(line_num, script_path, msg, msg)
  end

  def project do
    [
      app: :ssh_subsystem_fwup,
      version: @version,
      elixir: "~> 1.10",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),
      docs: docs(),
      package: package(),
      description: description(),
      preferred_cli_env: %{
        docs: :docs,
        "hex.publish": :docs,
        "hex.build": :docs,
        credo: :test
      }
    ]
  end

  def application do
    [extra_applications: [:logger, :ssh]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp description do
    "Over-the-air updates to Nerves devices via an ssh subsystem"
  end

  defp package do
    %{
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    }
  end

  defp deps do
    [
      {:ex_doc, "~> 0.22", only: :docs, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:credo, "~> 1.2", only: :test, runtime: false}
    ]
  end

  defp dialyzer() do
    [
      flags: [:missing_return, :extra_return, :unmatched_returns, :error_handling, :underspecs],
      plt_add_apps: [:mix]
    ]
  end

  defp docs do
    [
      extras: ["README.md", "CHANGELOG.md"],
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end
end
