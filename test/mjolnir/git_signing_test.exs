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

  test "mint does not copy opaque across vm_ids", %{vm_id: vm_id} do
    other = "fedcba98-7654-3210-fedc-ba9876543210"
    assert {:ok, pub1} = GitSigning.mint(vm_id)
    assert {:ok, pub2} = GitSigning.mint(other)
    assert pub1 != pub2
    assert {:ok, pem1} = GitSigning.get(vm_id)
    assert {:ok, pem2} = GitSigning.get(other)
    assert pem1 != pem2
    assert {:ok, meta} = GitSigning.get_device(vm_id)
    refute is_map_key(meta, "private_key")
    refute inspect(meta) =~ "PRIVATE KEY"
  end

  test "put_device refuses private key material", %{vm_id: vm_id} do
    pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----\n"

    assert {:error, :private_key_not_on_device_meta} =
             GitSigning.put_device(vm_id, %{private_key: pem})

    assert :not_found = GitSigning.get_device(vm_id)
  end

  test "respawn mints a new key and refuses same-id copy", %{vm_id: vm_id} do
    other = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    assert {:ok, pub1} = GitSigning.mint(vm_id)
    assert {:ok, pem1} = GitSigning.get(vm_id)
    assert {:ok, pub2} = GitSigning.respawn(vm_id, other)
    assert pub1 != pub2
    assert :not_found = GitSigning.get(vm_id)
    assert {:ok, pem2} = GitSigning.get(other)
    assert pem1 != pem2
    assert {:error, :cannot_copy_git_signing} = GitSigning.respawn(other, other)
  end

  test "revoke order is Forgejo then revoke_device then opaque", %{vm_id: vm_id} do
    assert {:ok, _pub} = GitSigning.mint(vm_id)

    :ok =
      GitSigning.put_device(vm_id, %{
        public_key: "ssh-ed25519 AAAA",
        xid: "aa",
        credential_id: "11111111-1111-1111-1111-111111111111"
      })

    {:ok, order} = Agent.start_link(fn -> [] end)

    on_exit(fn ->
      Application.delete_env(:mjolnir, :git_signing_forgejo_revoke)
      Application.delete_env(:mjolnir, :git_signing_revoke_device)
    end)

    Application.put_env(:mjolnir, :git_signing_forgejo_revoke, fn _meta ->
      Agent.update(order, &(&1 ++ [:forgejo]))
      :not_wired
    end)

    Application.put_env(:mjolnir, :git_signing_revoke_device, fn meta ->
      Agent.update(order, &(&1 ++ [:revoke_device]))
      assert meta.xid == "aa"
      assert meta.credential_id == "11111111-1111-1111-1111-111111111111"
      :ok
    end)

    assert :ok = GitSigning.revoke(vm_id)
    assert Agent.get(order, & &1) == [:forgejo, :revoke_device]
    assert :not_found = GitSigning.get(vm_id)
    assert :not_found = GitSigning.get_device(vm_id)
  end

  test "revoke_device failure keeps the opaque live", %{vm_id: vm_id} do
    pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nlive\n-----END OPENSSH PRIVATE KEY-----\n"
    assert :ok = GitSigning.put(vm_id, pem)

    :ok =
      GitSigning.put_device(vm_id, %{
        xid: "bb",
        credential_id: "22222222-2222-2222-2222-222222222222"
      })

    on_exit(fn ->
      Application.delete_env(:mjolnir, :git_signing_forgejo_revoke)
      Application.delete_env(:mjolnir, :git_signing_revoke_device)
    end)

    Application.put_env(:mjolnir, :git_signing_forgejo_revoke, fn _ -> :not_wired end)

    Application.put_env(:mjolnir, :git_signing_revoke_device, fn _ ->
      {:error, :identikey_down}
    end)

    assert {:error, {:revoke_device, :identikey_down}} = GitSigning.revoke(vm_id)
    assert {:ok, ^pem} = GitSigning.get(vm_id)
  end
end
