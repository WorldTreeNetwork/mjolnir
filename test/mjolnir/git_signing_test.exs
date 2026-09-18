defmodule Mjolnir.GitSigningTest do
  use ExUnit.Case, async: true

  alias Mjolnir.{GitSigning, SecretStore, Vsock.Protocol}

  setup do
    root = Path.join(System.tmp_dir!(), "mj-git-signing-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    original = Application.get_env(:mjolnir, :secret_store_root, nil)
    Application.put_env(:mjolnir, :secret_store_root, root)

    on_exit(fn ->
      if original, do: Application.put_env(:mjolnir, :secret_store_root, original)
      File.rm_rf(root)
    end)

    {:ok, vm_id: "01234567-89ab-cdef-0123-456789abcdef"}
  end

  test "put/get round-trip is opaque and 0600", %{vm_id: vm_id} do
    pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----\n"
    assert :ok = GitSigning.put(vm_id, pem)
    assert {:ok, ^pem} = GitSigning.get(vm_id)

    path = Path.join([SecretStore.root(), "_opaque", "vms", vm_id, "git_signing"])
    %{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "inject_request is not the Buzz env map" do
    req = GitSigning.inject_request("SECRETKEY")
    assert req["type"] == "inject_file"
    assert req["name"] == "git_signing_key"
    assert req["contents"] == "SECRETKEY"
    refute Map.has_key?(req, "entries")
  end

  test "protocol inject_file is distinct from inject_identity" do
    id_req = Protocol.inject_identity_request(%{private_key_nsec: "nsec1x", relay_url: "wss://x"})
    file_req = Protocol.inject_file_request("git_signing_key", "k")
    assert id_req["type"] == "inject_identity"
    assert file_req["type"] == "inject_file"
    refute Map.has_key?(id_req, "name")
  end
end
