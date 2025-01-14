defmodule Complex.Mixfile do
  use Mix.Project

  def project do
    [
      app: :complex,
      version: "0.6.0",
      description: description(),
      package: package(),
      elixir: "~> 1.16",
      deps: deps(),
      build_embedded: Mix.env() == :prod,
      preferred_cli_env: [
        docs: :docs,
        "hex.publish": :docs
      ],
      docs: [
        main: "Complex",
        authors: package()[:maintainers],
        extras: [],
        before_closing_body_tag: &before_closing_body_tag/1
      ]
    ]
  end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.36.1", only: :docs}
    ]
  end

  defp description do
    """
    Complex is a library for types and mathematical functions for complex
    numbers.
    """
  end

  defp package do
    [
      maintainers: ["Tom Krauss", "Paulo Valente", "José Valim"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/elixir-nx/complex.git",
        "Docs" => "http://hexdocs.pm/complex"
      }
    ]
  end

  defp before_closing_body_tag(:html) do
    """
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.13.0/dist/katex.min.css" integrity="sha384-t5CR+zwDAROtph0PXGte6ia8heboACF9R5l/DiY+WZ3P2lxNgvJkQk5n7GPvLMYw" crossorigin="anonymous">
    <script defer src="https://cdn.jsdelivr.net/npm/katex@0.13.0/dist/katex.min.js" integrity="sha384-FaFLTlohFghEIZkw6VGwmf9ISTubWAVYW8tG8+w2LAIftJEULZABrF9PPFv+tVkH" crossorigin="anonymous"></script>
    <script defer src="https://cdn.jsdelivr.net/npm/katex@0.13.0/dist/contrib/auto-render.min.js" integrity="sha384-bHBqxz8fokvgoJ/sc17HODNxa42TlaEhB+w8ZJXTc2nZf1VgEaFZeZvT4Mznfz0v" crossorigin="anonymous"
        onload="renderMathInElement(document.body, {delimiters: [
          {left: '$$', right: '$$', display: true},
          {left: '$', right: '$', display: false}
        ]});"></script>
    """
  end

  defp before_closing_body_tag(_), do: ""
end
