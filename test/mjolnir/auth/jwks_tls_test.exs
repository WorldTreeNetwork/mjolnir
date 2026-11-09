defmodule Mjolnir.Auth.JwksTLSTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  test "JWKS transport rejects an untrusted TLS certificate" do
    root = Path.join(System.tmp_dir!(), "jwks-tls-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    cert = Path.join(root, "cert.pem")
    key = Path.join(root, "key.pem")
    on_exit(fn -> File.rm_rf!(root) end)

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-days",
          "1",
          "-subj",
          "/CN=127.0.0.1",
          "-addext",
          "subjectAltName=IP:127.0.0.1",
          "-keyout",
          key,
          "-out",
          cert
        ],
        stderr_to_stdout: true
      )

    {:ok, listener} =
      :ssl.listen(0,
        certfile: String.to_charlist(cert),
        keyfile: String.to_charlist(key),
        ip: {127, 0, 0, 1},
        active: false,
        reuseaddr: true
      )

    on_exit(fn -> :ssl.close(listener) end)
    {:ok, {_address, port}} = :ssl.sockname(listener)
    parent = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :ssl.transport_accept(listener, 5_000)
        send(parent, :tls_connection_accepted)
        :ssl.handshake(socket, 5_000)
      end)

    log =
      capture_log(fn ->
        assert {:error, :econnrefused} =
                 Mjolnir.Auth.JwksHTTP.call(
                   %Tesla.Env{method: :get, url: "https://127.0.0.1:#{port}/jwks"},
                   []
                 )
      end)

    assert_receive :tls_connection_accepted
    assert {:error, {:tls_alert, {alert, _}}} = Task.await(server, 6_000)
    assert alert in [:unknown_ca, :bad_certificate]
    assert log =~ "unknown_ca" or log =~ "bad_certificate" or log =~ "selfsigned_peer"
  end
end
