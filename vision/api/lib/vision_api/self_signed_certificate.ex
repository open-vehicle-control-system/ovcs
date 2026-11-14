defmodule VisionApi.SelfSignedCertificate do
  @moduledoc """
  The certificate the endpoint serves HTTPS with on the unit: self-signed,
  generated on the unit the first time it starts, and reused afterwards so a
  browser's exception for it holds. The browser needs HTTPS for the
  dashboard's video decoder (WebCodecs).

  The stored pair is reused only while both files can be read, the key is
  the certificate's, and the certificate is for the unit's names; any
  other pair is replaced. Each file is written whole or not at all: to a
  temporary file, synced, then renamed. When the files cannot be written,
  the endpoint serves a pair held in memory, which lasts until it stops.
  """

  require Logger

  # A unit may start before its clock is set, so the validity does not depend on it; 9999-12-31 is RFC 5280's "no expiry".
  @not_before ~U[2000-01-01 00:00:00Z]
  @not_after ~U[9999-12-31 23:59:59Z]

  @doc """
  The endpoint's `https` options to serve with, for the unit's
  `hostnames`: `https` itself once its `certfile` and `keyfile` hold a
  pair for those names, written first when they do not; `https` with the
  pair in its transport options, in place of the files, when they cannot
  be written. `nil` for an endpoint without `https`.
  """
  @spec https_options(keyword() | nil, [String.t()]) :: keyword() | nil
  def https_options(nil, _hostnames), do: nil

  def https_options(https, hostnames) do
    certfile = Keyword.fetch!(https, :certfile)
    keyfile = Keyword.fetch!(https, :keyfile)

    if stored?(certfile, keyfile, hostnames) do
      https
    else
      key = X509.PrivateKey.new_ec(:secp256r1)
      certificate = certificate(key, hostnames)

      case write(certfile, keyfile, key, certificate) do
        :ok ->
          Logger.info(
            "Generated a self-signed certificate for #{Enum.join(hostnames, ", ")} at #{certfile}"
          )

          https

        {:error, reason} ->
          Logger.error(
            "Cannot write the certificate at #{certfile} (#{:file.format_error(reason)}): " <>
              "serving one held in memory, which a restart replaces"
          )

          in_memory(https, key, certificate)
      end
    end
  end

  defp stored?(certfile, keyfile, hostnames) do
    with {:ok, certificate_pem} <- File.read(certfile),
         {:ok, key_pem} <- File.read(keyfile),
         {:ok, certificate} <- decode(fn -> X509.Certificate.from_pem(certificate_pem) end),
         {:ok, key} <- decode(fn -> X509.PrivateKey.from_pem(key_pem) end) do
      X509.Certificate.public_key(certificate) == X509.PublicKey.derive(key) and
        names(certificate) == hostnames
    else
      _unreadable -> false
    end
  end

  # A truncated PEM makes the decoder raise rather than answer an error.
  defp decode(read) do
    read.()
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp names(certificate) do
    case X509.Certificate.extension(certificate, :subject_alt_name) do
      {:Extension, _id, _critical, names} -> for {:dNSName, name} <- names, do: to_string(name)
      nil -> []
    end
  end

  defp certificate(key, [hostname | _] = hostnames) do
    X509.Certificate.self_signed(key, "/CN=#{hostname}",
      template: :server,
      validity: X509.Certificate.Validity.new(@not_before, @not_after),
      extensions: [subject_alt_name: X509.Certificate.Extension.subject_alt_name(hostnames)]
    )
  end

  # The key is written first: a certificate without its key is replaced at the next start.
  defp write(certfile, keyfile, key, certificate) do
    with :ok <- write_file(keyfile, X509.PrivateKey.to_pem(key), 0o600),
         do: write_file(certfile, X509.Certificate.to_pem(certificate), 0o644)
  end

  defp write_file(path, contents, mode) do
    temporary = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, ""),
         :ok <- File.chmod(temporary, mode),
         :ok <- File.write(temporary, contents, [:sync]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, reason}
    end
  end

  defp in_memory(https, key, certificate) do
    pair = [
      cert: X509.Certificate.to_der(certificate),
      key: {:ECPrivateKey, X509.PrivateKey.to_der(key)}
    ]

    https
    |> Keyword.drop([:certfile, :keyfile])
    |> Keyword.update(:thousand_island_options, [transport_options: pair], fn options ->
      Keyword.update(options, :transport_options, pair, &Keyword.merge(&1, pair))
    end)
  end
end
