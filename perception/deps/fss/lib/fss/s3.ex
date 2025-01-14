defmodule FSS.S3 do
  @moduledoc """
  Specification for accessing AWS S3 resources.
  """

  defmodule Config do
    @moduledoc """
    Represents the configuration needed for accessing an S3 resource.
    """

    @derive {Inspect, only: [:bucket, :region, :endpoint]}
    defstruct [
      :access_key_id,
      :bucket,
      :region,
      :secret_access_key,
      :endpoint,
      :token
    ]

    @typedoc """
    The configuration struct for S3.

    The attributes are:

    * `:access_key_id` - This attribute is required.

    * `:secret_access_key` - This attribute is required.

    * `:bucket` - A valid bucket name. This attribute is optional,
      but if is not provided, then the `:endpoint` must include the bucket name
      either in the host, as a virtual host, or in the path. In other words:
      if the bucket is not given, then `:endpoint` must be configured.

      This attribute is going to be set to `nil` if the endpoint was
      not provided, unless the bucket name contain dots in it.

    * `:region` - This attribute is optional. It's normally required when working
      with the official AWS S3 API.

    * `:endpoint` - If specified, then `:region` is ignored.
      This attribute is required to be configured if you are using a service that
      is compatible with the AWS S3 API.

      In case only a "bucket URL" - without discrimination of the bucket name - is provided
      then the `:bucket` attribute can be nil just like the `:region`.

      In case the endpoint is not provided, we compute a valid one for the AWS S3 API.
      This endpoint is going to follow the virtual-host style most of the time, with
      the only exception being when the bucket name has dots. In that case we build
      the AWS S3 endpoint without the bucket name in it.

    * `:token` - This attribute is optional.
    """
    @type t :: %__MODULE__{
            access_key_id: String.t(),
            secret_access_key: String.t(),
            endpoint: String.t(),
            bucket: String.t() | nil,
            region: String.t() | nil,
            token: String.t() | nil
          }
  end

  defmodule Entry do
    @moduledoc """
    Represents the S3 resource itself.
    """

    defstruct [:key, :config]

    @typedoc """
    The entry struct for S3.

    The attributes are:

    * `:key` - A valid key for the resource. This attribute is required.
    * `:config` - A valid S3 config from the type `Config.t()`. This attribute is required.
    """
    @type t :: %__MODULE__{
            key: String.t(),
            config: Config.t()
          }
  end

  @doc """
  Parses a URL in the format `s3://bucket/resource-key`.

  ## Options

    * `:config` - It expects a `Config.t()` or a `Keyword.t()` with the keys
      representing the attributes of the `Config.t()`. By default it is `nil`,
      which means that we are going to try to fetch the credentials and configuration
      from the system's environment variables.

      The following env vars are read:

      - `AWS_ACCESS_KEY_ID`
      - `AWS_SECRET_ACCESS_KEY`
      - `AWS_REGION` or `AWS_DEFAULT_REGION`
      - `AWS_SESSION_TOKEN`

      In case the endpoint is not provided, we compute a valid one for the AWS S3 API,
      That is going to follow the path style. The endpoint is not going to include the
      `:bucket` in it, being necessary to do that when using this FSS entry.

      See https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-bucket-intro.html
      for more details.
  """
  @spec parse(String.t(), Keyword.t()) :: {:ok, Entry.t()} | {:error, Exception.t()}
  def parse(url, opts \\ []) do
    opts = Keyword.validate!(opts, config: nil)

    uri = URI.parse(url)

    case uri do
      %{scheme: "s3", host: bucket, path: "/" <> key} when is_binary(bucket) ->
        bucket = if bucket != "", do: bucket

        config =
          opts
          |> Keyword.fetch!(:config)
          |> normalize_config!()
          |> validate_config!()
          |> then(fn %Config{} = config ->
            config = %Config{config | bucket: bucket}

            if is_nil(config.endpoint) and not is_nil(bucket) do
              s3_host_suffix = "s3." <> config.region <> ".amazonaws.com"

              # We consume the bucket name in the endpoint if there is no dots in it.
              {endpoint, bucket} =
                if String.contains?(bucket, ".") do
                  {"https://" <> s3_host_suffix, bucket}
                else
                  {"https://" <> bucket <> "." <> s3_host_suffix, nil}
                end

              %Config{config | endpoint: endpoint, bucket: bucket}
            else
              config
            end
          end)

        if is_nil(config.endpoint) do
          {:error, ArgumentError.exception("endpoint is required when bucket is nil")}
        else
          {:ok, %Entry{key: key, config: config}}
        end

      _ ->
        {:error,
         ArgumentError.exception(
           "expected s3://<bucket>/<key> URL, got: " <>
             URI.to_string(uri)
         )}
    end
  end

  defp validate_config!(%Config{} = config) do
    check!(config, :access_key_id, "AWS_ACCESS_KEY_ID")
    check!(config, :secret_access_key, "AWS_SECRET_ACCESS_KEY")
    check!(config, :region, "AWS_REGION")

    config
  end

  defp normalize_config!(nil), do: config_from_system_env()
  defp normalize_config!(%Config{} = config), do: config

  defp normalize_config!(config) when is_list(config) or is_map(config) do
    struct!(config_from_system_env(), config)
  end

  defp normalize_config!(other) do
    raise ArgumentError,
          "expect configuration to be a %FSS.S3.Config{} struct, a keyword list or a map. Instead got #{inspect(other)}"
  end

  defp check!(config, key, env) do
    if Map.fetch!(config, key) in ["", nil] do
      raise ArgumentError,
            "missing #{inspect(key)} for FSS.S3 (set the key or the #{env} env var)"
    end
  end

  @doc """
  Builds a `Config.t()` reading from the system env.
  """
  @spec config_from_system_env :: Config.t()
  def config_from_system_env() do
    %Config{
      access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
      secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
      region: System.get_env("AWS_REGION", System.get_env("AWS_DEFAULT_REGION")),
      token: System.get_env("AWS_SESSION_TOKEN")
    }
  end
end
