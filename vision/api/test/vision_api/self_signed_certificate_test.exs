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

  describe "ensure!/2" do
    test "writes a certificate for the hostnames and its key where the endpoint's https options name them",
         %{https: https} do
      assert :ok = SelfSignedCertificate.ensure!(https, @hostnames)

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
      SelfSignedCertificate.ensure!(https, @hostnames)

      certificate = https[:certfile] |> File.read!() |> X509.Certificate.from_pem!()
      {:Validity, not_before, not_after} = X509.Certificate.validity(certificate)

      assert X509.DateTime.to_datetime(not_before) == ~U[2000-01-01 00:00:00Z]
      assert X509.DateTime.to_datetime(not_after) == ~U[9999-12-31 23:59:59Z]
    end

    test "keeps the key readable by its owner only", %{https: https} do
      SelfSignedCertificate.ensure!(https, @hostnames)

      assert File.stat!(https[:keyfile]).mode |> Bitwise.band(0o777) == 0o600
    end

    test "serves TLS with the pair it writes", %{https: https} do
      SelfSignedCertificate.ensure!(https, @hostnames)

      {:ok, listen_socket} =
        :ssl.listen(0,
          certfile: String.to_charlist(https[:certfile]),
          keyfile: String.to_charlist(https[:keyfile]),
          reuseaddr: true
        )

      {:ok, {_address, port}} = :ssl.sockname(listen_socket)
      server = Task.async(fn -> accept(listen_socket) end)

      assert {:ok, client} = :ssl.connect(~c"localhost", port, [verify: :verify_none], 5_000)
      assert {:ok, der} = :ssl.peercert(client)

      assert der ==
               https[:certfile]
               |> File.read!()
               |> X509.Certificate.from_pem!()
               |> X509.Certificate.to_der()

      :ssl.close(client)
      Task.await(server)
    end

    test "leaves a pair already there as it is", %{https: https} do
      SelfSignedCertificate.ensure!(https, @hostnames)
      certificate = File.read!(https[:certfile])
      key = File.read!(https[:keyfile])

      assert :ok = SelfSignedCertificate.ensure!(https, @hostnames)

      assert File.read!(https[:certfile]) == certificate
      assert File.read!(https[:keyfile]) == key
    end

    test "replaces a certificate whose key is missing", %{https: https} do
      SelfSignedCertificate.ensure!(https, @hostnames)
      certificate = File.read!(https[:certfile])
      File.rm!(https[:keyfile])

      SelfSignedCertificate.ensure!(https, @hostnames)

      assert File.read!(https[:certfile]) != certificate

      assert X509.Certificate.public_key(X509.Certificate.from_pem!(File.read!(https[:certfile]))) ==
               X509.PublicKey.derive(X509.PrivateKey.from_pem!(File.read!(https[:keyfile])))
    end

    test "does nothing for an endpoint without https", %{https: https} do
      assert :ok = SelfSignedCertificate.ensure!(nil, @hostnames)

      refute File.exists?(https[:certfile])
    end
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
