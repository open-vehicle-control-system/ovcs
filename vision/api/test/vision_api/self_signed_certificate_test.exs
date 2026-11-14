defmodule VisionApi.SelfSignedCertificateTest do
  use ExUnit.Case, async: true

  alias VisionApi.SelfSignedCertificate

  @moduletag :tmp_dir
  @hostnames ["unit-vision", "unit-vision.local"]

  setup %{tmp_dir: tmp_dir} do
    directory = Path.join(tmp_dir, "tls")

    %{
      https: [
        port: 0,
        certfile: Path.join(directory, "certificate.pem"),
        keyfile: Path.join(directory, "key.pem")
      ]
    }
  end

  describe "https_options/2" do
    test "writes a certificate for the hostnames and its key where the endpoint's https options name them",
         %{https: https} do
      assert SelfSignedCertificate.https_options(https, @hostnames) == https

      certificate = https[:certfile] |> File.read!() |> X509.Certificate.from_pem!()
      key = https[:keyfile] |> File.read!() |> X509.PrivateKey.from_pem!()

      assert subject_alt_names(certificate) == [
               dNSName: ~c"unit-vision",
               dNSName: ~c"unit-vision.local"
             ]

      assert X509.Certificate.public_key(certificate) == X509.PublicKey.derive(key)
    end

    test "makes a certificate valid whatever the clock reads, the unit's first start possibly before it is set",
         %{https: https} do
      SelfSignedCertificate.https_options(https, @hostnames)

      certificate = https[:certfile] |> File.read!() |> X509.Certificate.from_pem!()
      {:Validity, not_before, not_after} = X509.Certificate.validity(certificate)

      assert X509.DateTime.to_datetime(not_before) == ~U[2000-01-01 00:00:00Z]
      assert X509.DateTime.to_datetime(not_after) == ~U[9999-12-31 23:59:59Z]
    end

    test "keeps the key readable by its owner only", %{https: https} do
      SelfSignedCertificate.https_options(https, @hostnames)

      assert File.stat!(https[:keyfile]).mode |> Bitwise.band(0o777) == 0o600
    end

    test "serves TLS with the pair it writes", %{https: https} do
      SelfSignedCertificate.https_options(https, @hostnames)

      der =
        served(
          certfile: String.to_charlist(https[:certfile]),
          keyfile: String.to_charlist(https[:keyfile])
        )

      assert der == X509.Certificate.to_der(stored_certificate(https))
    end

    test "leaves a pair already there as it is", %{https: https} do
      SelfSignedCertificate.https_options(https, @hostnames)
      certificate = File.read!(https[:certfile])
      key = File.read!(https[:keyfile])

      assert SelfSignedCertificate.https_options(https, @hostnames) == https

      assert File.read!(https[:certfile]) == certificate
      assert File.read!(https[:keyfile]) == key
    end

    test "replaces a certificate whose key is missing", %{https: https} do
      SelfSignedCertificate.https_options(https, @hostnames)
      certificate = File.read!(https[:certfile])
      File.rm!(https[:keyfile])

      SelfSignedCertificate.https_options(https, @hostnames)

      assert File.read!(https[:certfile]) != certificate

      assert X509.Certificate.public_key(X509.Certificate.from_pem!(File.read!(https[:certfile]))) ==
               X509.PublicKey.derive(X509.PrivateKey.from_pem!(File.read!(https[:keyfile])))
    end

    test "replaces a certificate left empty, as by a power cut while it was written",
         %{https: https} do
      SelfSignedCertificate.https_options(https, @hostnames)
      File.write!(https[:certfile], "")

      assert SelfSignedCertificate.https_options(https, @hostnames) == https

      assert X509.Certificate.public_key(stored_certificate(https)) ==
               X509.PublicKey.derive(stored_key(https))
    end

    test "replaces a pair whose key is not text a key can be read from", %{https: https} do
      SelfSignedCertificate.https_options(https, @hostnames)
      File.write!(https[:keyfile], "-----BEGIN EC PRIVATE KEY-----\nAAAA")

      SelfSignedCertificate.https_options(https, @hostnames)

      assert X509.Certificate.public_key(stored_certificate(https)) ==
               X509.PublicKey.derive(stored_key(https))
    end

    test "replaces a pair whose key is not the certificate's", %{https: https} do
      SelfSignedCertificate.https_options(https, @hostnames)
      certificate = File.read!(https[:certfile])
      other = X509.PrivateKey.new_ec(:secp256r1)
      File.write!(https[:keyfile], X509.PrivateKey.to_pem(other))

      SelfSignedCertificate.https_options(https, @hostnames)

      assert File.read!(https[:certfile]) != certificate
      assert stored_key(https) != other

      assert X509.Certificate.public_key(stored_certificate(https)) ==
               X509.PublicKey.derive(stored_key(https))
    end

    test "replaces a pair made for other names", %{https: https} do
      SelfSignedCertificate.https_options(https, ["other-vision", "other-vision.local"])

      SelfSignedCertificate.https_options(https, @hostnames)

      assert subject_alt_names(stored_certificate(https)) == [
               dNSName: ~c"unit-vision",
               dNSName: ~c"unit-vision.local"
             ]
    end

    test "leaves no temporary file beside the pair", %{https: https} do
      SelfSignedCertificate.https_options(https, @hostnames)

      assert https[:certfile] |> Path.dirname() |> File.ls!() |> Enum.sort() ==
               ["certificate.pem", "key.pem"]
    end

    @tag :capture_log
    test "serves TLS with a pair held in memory when the files cannot be written",
         %{https: https, tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "tls"), "a file where the directory goes")

      options = SelfSignedCertificate.https_options(https, @hostnames)

      assert options[:port] == https[:port]
      refute Keyword.has_key?(options, :certfile)
      refute Keyword.has_key?(options, :keyfile)

      transport = options[:thousand_island_options][:transport_options]
      certificate = X509.Certificate.from_der!(served(transport))

      assert subject_alt_names(certificate) == [
               dNSName: ~c"unit-vision",
               dNSName: ~c"unit-vision.local"
             ]
    end

    @tag :capture_log
    test "an HTTPS listener starts on the pair held in memory", %{https: https, tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "tls"), "a file where the directory goes")
      options = SelfSignedCertificate.https_options(https, @hostnames)

      listener =
        start_supervised!(
          {Bandit,
           [
             plug: {VisionApiWeb.HttpsRedirect, https_port: 443},
             scheme: :https,
             startup_log: false
           ] ++
             options}
        )

      {:ok, {_address, port}} = ThousandIsland.listener_info(listener)

      assert {:ok, client} = :ssl.connect(~c"localhost", port, [verify: :verify_none], 5_000)
      :ssl.close(client)
    end

    @tag :capture_log
    test "keeps the endpoint's other transport options beside a pair held in memory",
         %{https: https, tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "tls"), "a file where the directory goes")

      https =
        https ++ [thousand_island_options: [num_acceptors: 3, transport_options: [backlog: 5]]]

      options = SelfSignedCertificate.https_options(https, @hostnames)[:thousand_island_options]

      assert options[:num_acceptors] == 3
      assert options[:transport_options][:backlog] == 5
      assert Keyword.has_key?(options[:transport_options], :cert)
    end

    test "does nothing for an endpoint without https", %{https: https} do
      assert SelfSignedCertificate.https_options(nil, @hostnames) == nil

      refute File.exists?(https[:certfile])
    end
  end

  defp stored_certificate(https),
    do: https[:certfile] |> File.read!() |> X509.Certificate.from_pem!()

  defp stored_key(https), do: https[:keyfile] |> File.read!() |> X509.PrivateKey.from_pem!()

  # The certificate, as DER, a TLS server with `options` hands a client.
  defp served(options) do
    {:ok, listen_socket} = :ssl.listen(0, [reuseaddr: true] ++ options)
    {:ok, {_address, port}} = :ssl.sockname(listen_socket)
    server = Task.async(fn -> accept(listen_socket) end)

    assert {:ok, client} = :ssl.connect(~c"localhost", port, [verify: :verify_none], 5_000)
    assert {:ok, der} = :ssl.peercert(client)

    :ssl.close(client)
    Task.await(server)
    der
  end

  defp accept(listen_socket) do
    {:ok, socket} = :ssl.transport_accept(listen_socket, 5_000)
    {:ok, socket} = :ssl.handshake(socket, 5_000)
    :ssl.close(socket)
  end

  defp subject_alt_names(certificate) do
    {:Extension, _id, _critical, names} =
      X509.Certificate.extension(certificate, :subject_alt_name)

    names
  end
end
