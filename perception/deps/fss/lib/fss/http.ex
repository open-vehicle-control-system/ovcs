defmodule FSS.HTTP do
  @moduledoc """
  Specification for accessing HTTP(s) resources.
  """

  defmodule Config do
    @moduledoc """
    Represents the configuration for an HTTP resource.
    """
    defstruct [:headers]

    @typedoc """
    Only `:headers` are configurable now.

    They are a list of `{String.t(), String.t()}`
    """
    @type t :: %__MODULE__{headers: [{String.t(), String.t()}]}
  end

  defmodule Entry do
    @moduledoc """
    Represents the actual HTTP resource.
    """
    defstruct [:url, :config]

    @typedoc """
    The entry type of an HTTP resource.

    The `:url` is expected to be a valid HTTP or HTTPS URL,
    and `:config` is expected to be a `Config.t()`.
    """
    @type t :: %__MODULE__{url: String.t(), config: Config.t()}
  end

  @doc """
  Parses an HTTP or HTTPs url.

  ## Options

    * `:config` - A `Config.t()`. This is optional and by default it's `nil`.
  """
  @spec parse(String.t(), Keyword.t()) :: {:ok, Entry.t()} | {:error, Exception.t()}
  def parse(url, opts \\ []) do
    opts = Keyword.validate!(opts, config: nil)

    with {:ok, config} <- build_config(opts[:config]) do
      {:ok, %Entry{url: url, config: config}}
    end
  end

  defp build_config(nil), do: {:ok, %Config{headers: []}}
  defp build_config(%Config{} = config), do: {:ok, config}

  defp build_config(config) when is_list(config) do
    case Keyword.validate(config, headers: []) do
      {:ok, opts} ->
        callback = fn pair ->
          match?({key, value} when is_binary(key) and is_binary(value), pair)
        end

        if Enum.all?(opts[:headers], callback) do
          {:ok, %Config{headers: opts[:headers]}}
        else
          {:error,
           ArgumentError.exception(
             "one of the headers is invalid. Expecting a list of `{\"key\", \"value\"}`, but got: #{inspect(opts[:headers])}"
           )}
        end

      {:error, key} ->
        {:error,
         ArgumentError.exception(
           "the keys #{inspect(key)} are not valid keys for the HTTP configuration"
         )}
    end
  end

  defp build_config(other) do
    {:error,
     ArgumentError.exception(
       "config for HTTP entry is invalid. Expecting `:headers`, but got #{inspect(other)}"
     )}
  end
end
