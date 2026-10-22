defmodule Mjolnir.SecretEscrowTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias Mjolnir.SecretEscrow

  setup do
    dir =
      Path.join(System.tmp_dir!(), "mjolnir-escrow-test-#{System.unique_integer([:positive])}")

    prev = Application.get_env(:mjolnir, :secret_escrow_dir)
    Application.put_env(:mjolnir, :secret_escrow_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)

      if prev,
        do: Application.put_env(:mjolnir, :secret_escrow_dir, prev),
        else: Application.delete_env(:mjolnir, :secret_escrow_dir)
    end)

    %{dir: dir, vm_id: "11111111-2222-3333-4444-555555555555"}
  end

  test "gen_passphrase returns a fresh 256-bit base64url string each call" do
    a = SecretEscrow.gen_passphrase()
    b = SecretEscrow.gen_passphrase()

    assert a != b
    # 32 bytes base64url unpadded = 43 chars
    assert String.length(a) == 43
    assert a =~ ~r/^[A-Za-z0-9_-]+$/
  end

  test "put/get roundtrips a passphrase", %{vm_id: vm_id} do
    assert :not_found == SecretEscrow.get(vm_id)
    assert :ok == SecretEscrow.put(vm_id, "hunter2")
    assert {:ok, "hunter2"} == SecretEscrow.get(vm_id)
    assert SecretEscrow.exists?(vm_id)
  end

  test "the escrow file is mode 0600", %{dir: dir, vm_id: vm_id} do
    :ok = SecretEscrow.put(vm_id, "s3cret")
    %File.Stat{mode: mode} = File.stat!(Path.join(dir, Mjolnir.VmId.storage_id(vm_id)))
    assert (mode &&& 0o777) == 0o600
  end

  test "get_or_create creates then returns the same passphrase", %{vm_id: vm_id} do
    assert {:ok, pass, :created} = SecretEscrow.get_or_create(vm_id)
    assert {:ok, ^pass, :existing} = SecretEscrow.get_or_create(vm_id)
  end

  test "put overwrites an existing entry", %{vm_id: vm_id} do
    :ok = SecretEscrow.put(vm_id, "old")
    :ok = SecretEscrow.put(vm_id, "new")
    assert {:ok, "new"} == SecretEscrow.get(vm_id)
  end

  test "delete is idempotent", %{vm_id: vm_id} do
    :ok = SecretEscrow.put(vm_id, "x")
    assert :ok == SecretEscrow.delete(vm_id)
    refute SecretEscrow.exists?(vm_id)
    # deleting again is still :ok
    assert :ok == SecretEscrow.delete(vm_id)
  end

  test "rejects ids that would escape the escrow dir" do
    for bad <- ["../etc/passwd", "a/b", "..", "", "with\0null"] do
      assert {:error, :invalid_vm_id} = SecretEscrow.put(bad, "x")
      assert {:error, :invalid_vm_id} = SecretEscrow.get(bad)
      refute SecretEscrow.exists?(bad)
    end
  end
end
