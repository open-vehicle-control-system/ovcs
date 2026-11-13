defmodule VisionApi.SelfSignedCertificate do
  @moduledoc """
  The certificate the endpoint serves HTTPS with on the unit: self-signed,
  generated on the unit the first time it starts, and reused afterwards so a
  browser's exception for it holds. The browser needs HTTPS for the
  dashboard's video decoder (WebCodecs).
  """

  require Logger

  # A unit may start before its clock is set, so the validity does not depend on it; 9999-12-31 is RFC 5280's "no expiry".
  @not_before ~U[2000-01-01 00:00:00Z]
  @not_after ~U[9999-12-31 23:59:59Z]

  @doc """
  Writes a self-signed certificate for `hostnames` and its private key to
  the `certfile` and `keyfile` of the endpoint's `https` options, unless
  both files are already there. Does nothing for an endpoint without
  `https`. Raises when it cannot write them: the endpoint cannot start
  without them.
  """
  def ensure!(nil, _hostnames), do: :ok

  def ensure!(https, hostnames) do
    certfile = Keyword.fetch!(https, :certfile)
    keyfile = Keyword.fetch!(https, :keyfile)

    if File.exists?(certfile) and File.exists?(keyfile) do
      :ok
    else
      write!(certfile, keyfile, hostnames)
    end
  end

  # The key is written first: a certificate without its key is replaced at the next start.
  defp write!(certfile, keyfile, [hostname | _] = hostnames) do
    key = X509.PrivateKey.new_ec(:secp256r1)

    certificate =
      X509.Certificate.self_signed(key, "/CN=#{hostname}",
        template: :server,
        validity: X509.Certificate.Validity.new(@not_before, @not_after),
        extensions: [subject_alt_name: X509.Certificate.Extension.subject_alt_name(hostnames)]
      )

    File.mkdir_p!(Path.dirname(keyfile))
    File.write!(keyfile, "")
    File.chmod!(keyfile, 0o600)
    File.write!(keyfile, X509.PrivateKey.to_pem(key))
    File.mkdir_p!(Path.dirname(certfile))
    File.write!(certfile, X509.Certificate.to_pem(certificate))

    Logger.info(
      "Generated a self-signed certificate for #{Enum.join(hostnames, ", ")} at #{certfile}"
    )
  end
end
