defmodule Mjolnir.IdentityInjectTest do
  @moduledoc """
  mjolnir-1pe: nsec is stored in SecretStore, injected over vsock, and
  appears in no host-side artifact (VM record, API bodies, Inspect, logs).
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Bitwise

  alias Mjolnir.{Identity, VM}
  alias Mjolnir.API.Views
  alias Mjolnir.Vsock.Protocol

  @nsec "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq6x0x0x"
  @relay "wss://relay.example.test"

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "mjolnir-identity-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    original = Application.get_env(:mjolnir, :secret_store_root)
    Application.put_env(:mjolnir, :secret_store_root, tmp)

    on_exit(fn ->
      Application.put_env(:mjolnir, :secret_store_root, original)
      File.rm_rf!(tmp)
    end)

    vm_id = "11111111-2222-3333-4444-555555555555"
    identity = %{private_key_nsec: @nsec, relay_url: @relay}
    {:ok, tmp: tmp, vm_id: vm_id, identity: identity}
  end

  test "put/get/delete round-trips without interpreting the nsec", ctx do
    assert :not_found = Identity.get(ctx.vm_id)
    assert :ok = Identity.put(ctx.vm_id, ctx.identity)
    assert {:ok, stored} = Identity.get(ctx.vm_id)
    assert stored.private_key_nsec == @nsec
    assert stored.relay_url == @relay
    assert :ok = Identity.delete(ctx.vm_id)
    assert :not_found = Identity.get(ctx.vm_id)
  end

  test "opaque file is mode 0600 and lives under SecretStore", ctx do
    :ok = Identity.put(ctx.vm_id, ctx.identity)
    path = Path.join([ctx.tmp, "_opaque", "vms", ctx.vm_id, "identity"])
    assert File.exists?(path)
    %File.Stat{mode: mode} = File.stat!(path)
    assert (mode &&& 0o777) == 0o600
  end

  test "parse_params rejects control characters and missing fields" do
    assert :absent = Identity.parse_params(nil)

    assert {:error, _} = Identity.parse_params(%{})

    assert {:error, _} =
             Identity.parse_params(%{
               "private_key_nsec" => "nsec1ok",
               "relay_url" => "wss://x\nEXTRA"
             })

    assert {:ok, %{private_key_nsec: "nsec1ok", relay_url: "wss://x"}} =
             Identity.parse_params(%{
               "private_key_nsec" => "nsec1ok",
               "relay_url" => "wss://x"
             })
  end

  test "parse_params keeps auth_tag and extra env for buzz.env" do
    assert {:ok, id} =
             Identity.parse_params(%{
               "private_key_nsec" => "nsec1ok",
               "relay_url" => "wss://x",
               "auth_tag" => "[\"auth\",\"abc\"]",
               "env" => %{
                 "OPENAI_COMPAT_BASE_URL" => "http://10.200.0.1:8020/v1",
                 "BUZZ_PRIVATE_KEY" => "nsec1attacker"
               }
             })

    entries = Identity.env_entries(id)
    assert entries["BUZZ_AUTH_TAG"] == "[\"auth\",\"abc\"]"
    assert entries["OPENAI_COMPAT_BASE_URL"] == "http://10.200.0.1:8020/v1"
    assert entries["NOSTR_PRIVATE_KEY"] == "nsec1ok"
    assert entries["BUZZ_PRIVATE_KEY"] == "nsec1ok"
  end

  test "vsock request carries identity entries and is not a host artifact", ctx do
    msg = Protocol.inject_identity_request(ctx.identity, request_id: "req-id")
    assert msg["type"] == "inject_identity"
    assert msg["id"] == "req-id"
    assert msg["entries"]["BUZZ_PRIVATE_KEY"] == @nsec
    assert msg["entries"]["BUZZ_RELAY_URL"] == @relay

    encoded = Protocol.encode(msg, 0)
    <<0::8, length::big-32, payload::binary>> = encoded
    assert byte_size(payload) == length
    assert Jason.decode!(payload) == msg
  end

  test "negative: nsec is absent from VM record, API bodies, Inspect, and logs", ctx do
    log =
      capture_log(fn ->
        assert :ok = Identity.put(ctx.vm_id, ctx.identity)
        _ = Identity.entry_keys(ctx.identity)
        _ = Protocol.inject_identity_request(ctx.identity, request_id: "neg")
      end)

    vm = %VM{
      id: ctx.vm_id,
      state: :running,
      config: %{vcpu_count: 1, mem_size_mib: 256, base_image: "ubuntu-24.04", snapshot: nil},
      enable_iroh: false,
      owner_id: "owner-1",
      ssh_public_key: nil,
      secrets_mode: :none,
      secrets_payload: %{"BUZZ_PRIVATE_KEY" => @nsec},
      restart_policy: :never,
      metadata: %{"app" => "buzz"},
      secrets_unlock_failure: nil
    }

    record = VM.build_running_record(vm)
    info = Views.render_vm(vm)
    summary = Views.render_vm_summary(vm)

    artifacts = [
      inspect(record),
      inspect(info),
      inspect(summary),
      Jason.encode!(info),
      Jason.encode!(summary),
      inspect(vm),
      inspect(vm.config),
      log
    ]

    Enum.each(artifacts, fn blob ->
      refute Identity.leaked_in?(@nsec, blob),
             "nsec leaked in host artifact: #{String.slice(to_string(blob), 0, 200)}"
    end)

    # SecretStore is the allowed home — the negative is host artifacts, not the store.
    assert {:ok, stored} = Identity.get(ctx.vm_id)
    assert stored.private_key_nsec == @nsec
  end

  test "Inspect of a VM redacts secrets_payload", ctx do
    vm = %VM{
      id: ctx.vm_id,
      state: :running,
      secrets_payload: %{"BUZZ_PRIVATE_KEY" => @nsec}
    }

    text = inspect(vm)
    refute String.contains?(text, @nsec)
    assert String.contains?(text, "redacted")
  end
end
