defmodule Mjolnir.Aie.OfferTest do
  use ExUnit.Case, async: false

  alias Mjolnir.Aie.{Allowlist, Offer}
  alias Mjolnir.Biscuit
  alias Mjolnir.SecretStore
  alias Mjolnir.Sites.IdentiKey

  setup do
    tmp =
      System.tmp_dir!()
      |> Path.join("mjolnir-aie-offer-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    original_root = Application.get_env(:mjolnir, :secret_store_root)
    original_ids = Application.get_env(:mjolnir, :aie_offering_vm_ids)
    original_fps = Application.get_env(:mjolnir, :aie_vm_identikeys)

    Application.put_env(:mjolnir, :secret_store_root, tmp)

    on_exit(fn ->
      Application.put_env(:mjolnir, :secret_store_root, original_root)
      put_env(:aie_offering_vm_ids, original_ids)
      put_env(:aie_vm_identikeys, original_fps)
      File.rm_rf!(tmp)
    end)

    keypair = IdentiKey.gen_keypair()
    fp = IdentiKey.fingerprint(keypair)
    :ok = SecretStore.put(fp, "identity/pubkey", identity_record(keypair))

    vm_id = "vm-offer-#{System.unique_integer([:positive])}"
    Application.put_env(:mjolnir, :aie_offering_vm_ids, [vm_id])
    Application.put_env(:mjolnir, :aie_vm_identikeys, %{vm_id => fp})

    {:ok, keypair: keypair, fp: fp, vm_id: vm_id, tmp: tmp}
  end

  defp put_env(key, nil), do: Application.delete_env(:mjolnir, key)
  defp put_env(key, value), do: Application.put_env(:mjolnir, key, value)

  defp identity_record(keypair) do
    Jason.encode!(%{"pubkey" => Base.encode64(keypair.ed25519_public)})
  end

  defp sample_offer(fp, vm_id, keypair, attrs \\ []) do
    %Offer{
      version: 1,
      owner_fp: fp,
      offer_id: Keyword.get(attrs, :offer_id, "npu"),
      vm_id: Keyword.get(attrs, :vm_id, vm_id),
      being_pubkey: Keyword.get(attrs, :being_pubkey, keypair.ed25519_public),
      sequence: Keyword.get(attrs, :sequence, 1),
      guild: Keyword.get(attrs, :guild, nil),
      design_ids: Keyword.get(attrs, :design_ids, ["npu2-vector-add"]),
      max_wall_time: Keyword.get(attrs, :max_wall_time, 30),
      tombstone: Keyword.get(attrs, :tombstone, false),
      signature: nil
    }
  end

  test "canonical bytes include owner, offer, vm, being, sequence, optional guild, design ids, wall time",
       %{keypair: kp, fp: fp, vm_id: vm_id} do
    offer = sample_offer(fp, vm_id, kp, guild: "guild-1")
    bytes = Offer.canonical_signing_bytes(offer)
    raw = Jason.decode!(bytes)

    assert raw["owner_fp"] == fp
    assert raw["offer_id"] == "npu"
    assert raw["vm_id"] == vm_id
    assert raw["being_pubkey"] == Base.encode64(kp.ed25519_public)
    assert raw["sequence"] == 1
    assert raw["guild"] == "guild-1"
    assert raw["design_ids"] == ["npu2-vector-add"]
    assert raw["max_wall_time"] == 30
    assert raw["tombstone"] == false
    assert raw["signature"] == nil
  end

  test "stores owner_fp keyspace fingerprint and being Ed25519 pubkey as distinct namespaces",
       %{keypair: kp, fp: fp, vm_id: vm_id} do
    offer = sample_offer(fp, vm_id, kp)
    assert fp == IdentiKey.fingerprint(offer.being_pubkey)
    holder = Biscuit.holder_fingerprint(offer.being_pubkey)
    refute fp == Base.encode16(holder, case: :lower)
    refute fp == Base.encode64(holder)
    assert byte_size(offer.being_pubkey) == 32
  end

  test "spawn does not mint capacity", %{fp: fp, vm_id: vm_id} do
    source = File.read!("lib/mjolnir/vm.ex")
    refute source =~ "Mjolnir.Aie"
    refute source =~ "aie/offers"

    assert :not_found = Offer.fetch(fp, "npu")
    refute Offer.exists?(fp, "npu")

    listed = SecretStore.list(fp, "aie/offers")
    refute Enum.any?(listed, &String.contains?(&1, vm_id))
  end

  test "unsigned offer is refused", %{keypair: kp, fp: fp, vm_id: vm_id} do
    offer = sample_offer(fp, vm_id, kp)
    path = Path.join([SecretStore.root(), fp, Offer.key("npu")])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Offer.serialize(offer))

    assert {:error, :missing_signature} = Offer.authorize_execute(fp, "npu", "nope")
    assert {:error, :missing_signature} = Offer.mint(fp, "npu")
  end

  test "cross-keyspace id collision does not share rights", %{keypair: kp, fp: fp, vm_id: vm_id} do
    assert :ok = Offer.publish(sample_offer(fp, vm_id, kp), kp)
    {:ok, minted} = Offer.mint(fp, "npu")

    other = IdentiKey.gen_keypair()
    other_fp = IdentiKey.fingerprint(other)
    :ok = SecretStore.put(other_fp, "identity/pubkey", identity_record(other))
    other_vm = "vm-other-#{System.unique_integer([:positive])}"
    Application.put_env(:mjolnir, :aie_offering_vm_ids, [vm_id, other_vm])

    Application.put_env(:mjolnir, :aie_vm_identikeys, %{
      vm_id => fp,
      other_vm => other_fp
    })

    assert :ok =
             Offer.publish(
               sample_offer(other_fp, other_vm, other, offer_id: "npu"),
               other
             )

    assert {:error, :incarnation_mismatch} =
             Offer.authorize_execute(other_fp, "npu", minted.incarnation)

    assert :ok = Offer.authorize_execute(fp, "npu", minted.incarnation)
  end

  test "unrelated VM in a signed leaf is refused", %{keypair: kp, fp: fp, vm_id: vm_id} do
    stranger = IdentiKey.gen_keypair()
    stranger_fp = IdentiKey.fingerprint(stranger)
    stranger_vm = "vm-stranger-#{System.unique_integer([:positive])}"

    Application.put_env(:mjolnir, :aie_offering_vm_ids, [vm_id, stranger_vm])

    Application.put_env(:mjolnir, :aie_vm_identikeys, %{
      vm_id => fp,
      stranger_vm => stranger_fp
    })

    named = sample_offer(fp, stranger_vm, kp)
    assert {:error, :unrelated_vm} = Offer.publish(named, kp)

    signed = Offer.sign(named, kp)
    assert :ok = SecretStore.put(fp, Offer.key("npu"), Offer.serialize(signed))
    assert {:error, :unrelated_vm} = Offer.mint(fp, "npu")
    assert {:error, :unrelated_vm} = Offer.authorize_execute(fp, "npu", Offer.incarnation(signed))
  end

  test "guest not on the allowlist cannot offer", %{keypair: kp, fp: fp} do
    guest_vm = "vm-guest-#{System.unique_integer([:positive])}"
    Application.put_env(:mjolnir, :aie_offering_vm_ids, [])
    Application.put_env(:mjolnir, :aie_vm_identikeys, %{guest_vm => fp})

    offer = sample_offer(fp, guest_vm, kp)
    assert {:error, :not_allowlisted} = Offer.publish(offer, kp)

    signed = Offer.sign(offer, kp)
    assert :ok = SecretStore.put(fp, Offer.key("npu"), Offer.serialize(signed))
    assert {:error, :not_allowlisted} = Offer.mint(fp, "npu")
    refute Allowlist.member?(guest_vm)
  end

  test "mint copies incarnation from the current verified leaf", %{
    keypair: kp,
    fp: fp,
    vm_id: vm_id
  } do
    offer = sample_offer(fp, vm_id, kp)
    assert :ok = Offer.publish(offer, kp)
    {:ok, bytes} = SecretStore.get(fp, Offer.key("npu"))
    {:ok, minted} = Offer.mint(fp, "npu")
    assert minted.owner_fp == fp
    assert minted.offer_id == "npu"
    assert minted.incarnation == Offer.incarnation(bytes)
    assert minted.incarnation == Offer.incarnation(Offer.sign(offer, kp))
  end

  test "replacement invalidates the old incarnation", %{keypair: kp, fp: fp, vm_id: vm_id} do
    assert :ok = Offer.publish(sample_offer(fp, vm_id, kp, sequence: 1), kp)
    {:ok, t1} = Offer.mint(fp, "npu")

    assert :ok =
             Offer.publish(
               sample_offer(fp, vm_id, kp, sequence: 2, design_ids: ["npu2-vector-add"]),
               kp
             )

    assert {:error, :incarnation_mismatch} =
             Offer.authorize_execute(fp, "npu", t1.incarnation)

    {:ok, t2} = Offer.mint(fp, "npu")
    refute t2.incarnation == t1.incarnation
    assert :ok = Offer.authorize_execute(fp, "npu", t2.incarnation)
  end

  test "personal-to-guild replacement rejects the old token", %{
    keypair: kp,
    fp: fp,
    vm_id: vm_id
  } do
    assert :ok = Offer.publish(sample_offer(fp, vm_id, kp, sequence: 1, guild: nil), kp)
    {:ok, t1} = Offer.mint(fp, "npu")

    assert :ok =
             Offer.publish(sample_offer(fp, vm_id, kp, sequence: 2, guild: "guild-1"), kp)

    assert {:error, :incarnation_mismatch} =
             Offer.authorize_execute(fp, "npu", t1.incarnation)

    {:ok, t2} = Offer.mint(fp, "npu")
    assert :ok = Offer.authorize_execute(fp, "npu", t2.incarnation)
  end

  test "tombstone recreation does not revive an old grant", %{
    keypair: kp,
    fp: fp,
    vm_id: vm_id
  } do
    assert :ok = Offer.publish(sample_offer(fp, vm_id, kp, sequence: 1), kp)
    {:ok, t1} = Offer.mint(fp, "npu")
    assert :ok = Offer.withdraw(fp, "npu", kp)

    {:ok, tomb, _} = Offer.fetch(fp, "npu")
    assert tomb.tombstone
    assert {:error, :tombstoned} = Offer.authorize_execute(fp, "npu", t1.incarnation)
    assert {:error, :tombstoned} = Offer.mint(fp, "npu")

    assert :ok = Offer.publish(sample_offer(fp, vm_id, kp, sequence: tomb.sequence + 1), kp)
    {:ok, t2} = Offer.mint(fp, "npu")
    refute t2.incarnation == t1.incarnation

    assert {:error, :incarnation_mismatch} =
             Offer.authorize_execute(fp, "npu", t1.incarnation)
  end

  test "re-put of retired bytes is refused", %{keypair: kp, fp: fp, vm_id: vm_id} do
    live = Offer.sign(sample_offer(fp, vm_id, kp, sequence: 1), kp)
    live_bytes = Offer.serialize(live)
    assert :ok = SecretStore.put(fp, Offer.key("npu"), live_bytes)
    {:ok, t1} = Offer.mint(fp, "npu")

    assert :ok = Offer.withdraw(fp, "npu", kp)
    assert {:error, :sequence_floor} = SecretStore.put(fp, Offer.key("npu"), live_bytes)
    assert {:error, :tombstoned} = Offer.authorize_execute(fp, "npu", t1.incarnation)
  end
end
