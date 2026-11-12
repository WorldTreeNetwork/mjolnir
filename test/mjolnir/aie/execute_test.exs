defmodule Mjolnir.Aie.ExecuteTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  alias Mjolnir.Aie.{Execute, Offer}
  alias Mjolnir.AIE.{Pending, Occupancy, Admit}
  alias Mjolnir.{Biscuit, SecretStore}
  alias Mjolnir.Sites.IdentiKey

  defmodule Being do
    use GenServer
    def start_link(id), do: GenServer.start_link(__MODULE__, id)

    def init(id) do
      Registry.register(Mjolnir.VMRegistry, id, nil)
      {:ok, %{id: id, state: :running}}
    end

    def handle_call(:get_state, _from, state), do: {:reply, state, state}
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "aie-execute-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    keys = [:secret_store_root, :aie_offering_vm_ids, :aie_vm_identikeys, :aie_max_queue_age_ms]
    old = Enum.map(keys, &{&1, Application.get_env(:mjolnir, &1)})
    Application.put_env(:mjolnir, :secret_store_root, tmp)
    owner = IdentiKey.gen_keypair()
    fp = IdentiKey.fingerprint(owner)
    vm = "aie-being-#{System.unique_integer([:positive])}"
    being = start_supervised!({Being, vm})

    :ok =
      SecretStore.put(
        fp,
        "identity/pubkey",
        Jason.encode!(%{pubkey: Base.encode64(owner.ed25519_public)})
      )

    Application.put_env(:mjolnir, :aie_offering_vm_ids, [vm])
    Application.put_env(:mjolnir, :aie_vm_identikeys, %{vm => fp})

    offer = %Offer{
      owner_fp: fp,
      offer_id: "npu",
      vm_id: vm,
      being_pubkey: owner.ed25519_public,
      sequence: 1,
      design_ids: ["vector-add"],
      max_wall_time: 10,
      tombstone: false
    }

    :ok = Offer.publish(offer, owner)
    pending = :"execute_pending_#{System.unique_integer([:positive])}"
    start_supervised!({Pending, name: pending})
    occupancy = start_supervised!({Occupancy, []})

    on_exit(fn ->
      for {key, value} <- old do
        if is_nil(value),
          do: Application.delete_env(:mjolnir, key),
          else: Application.put_env(:mjolnir, key, value)
      end

      File.rm_rf!(tmp)
    end)

    %{
      owner: owner,
      fp: fp,
      vm: vm,
      being: being,
      offer: offer,
      pending: pending,
      occupancy: occupancy
    }
  end

  defp sign(p, key) do
    Map.put(p, "signature", Base.encode64(IdentiKey.sign(key, Execute.signing_message(p))))
  end

  defp mint_proof(ctx, caller, target, grant \\ "") do
    {:ok, current} = Execute.share(ctx.fp, "npu")
    challenge = Execute.challenge()

    %{
      "method" => "MINT",
      "resource" => current.resource,
      "nonce" => challenge.nonce,
      "audience" => challenge.audience,
      "idempotency_key" => "mint-1",
      "biscuit" => grant,
      "public_key" => Base.encode64(caller.ed25519_public),
      "holder_public_key" => Base.encode64(target.ed25519_public)
    }
    |> sign(caller)
  end

  defp token(ctx, holder) do
    {:ok, minted} = Execute.mint(mint_proof(ctx, ctx.owner, holder))
    minted.biscuit
  end

  defp proof(ctx, holder, token) do
    {:ok, current} = Execute.share(ctx.fp, "npu")
    challenge = Execute.challenge()

    %{
      "method" => "POST",
      "resource" => current.resource,
      "nonce" => challenge.nonce,
      "audience" => challenge.audience,
      "idempotency_key" => "job-1",
      "biscuit" => token,
      "public_key" => Base.encode64(holder.ed25519_public),
      "design_id" => "vector-add",
      "input_b64" => Base.encode64("bounded input")
    }
    |> sign(holder)
  end

  defp request(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Mjolnir.API.Router.call(Mjolnir.API.Router.init([]))
  end

  test "VM being is offer principal, host process and missing being fail closed", ctx do
    {:ok, shared} = Execute.share(ctx.fp, "npu")
    assert shared.offer["being_pubkey"] == Base.encode64(ctx.owner.ed25519_public)
    process_key = IdentiKey.gen_keypair()
    assert request("/api/aie/mint", mint_proof(ctx, process_key, process_key)).status == 403
    p = mint_proof(ctx, ctx.owner, ctx.owner)
    stop_supervised!(Being)
    assert {:error, :missing_being} = Execute.share(ctx.fp, "npu")
    assert {:error, :forbidden} = Execute.mint(p)
  end

  test "mint copies incarnation and requires the holder check with inject_holder", ctx do
    holder = IdentiKey.gen_keypair()
    p = mint_proof(ctx, ctx.owner, holder)
    {:ok, minted} = Execute.mint(p)
    {:ok, current} = Offer.mint(ctx.fp, "npu")
    assert minted.resource == "#{ctx.fp}/npu/#{current.incarnation}"
    bytes = Base.decode64!(minted.biscuit)
    fp = Base.encode16(Biscuit.holder_fingerprint(holder.ed25519_public), case: :lower)
    root = Biscuit.authority().public_hex
    assert {:error, _} = Biscuit.authorize(bytes, root, fp, minted.resource, "aie-execute", false)
    assert :ok = Biscuit.authorize(bytes, root, fp, minted.resource, "aie-execute", true)
    assert {:error, :forbidden} = Execute.mint(p)
    assert {:ok, _} = Execute.mint(mint_proof(ctx, holder, holder, minted.biscuit))
    assert {:error, :forbidden} = Execute.mint(mint_proof(ctx, holder, ctx.owner, minted.biscuit))
  end

  test "second identity with grant runs and third identity gets 403", ctx do
    second = IdentiKey.gen_keypair()
    granted = token(ctx, second)
    p = proof(ctx, second, granted)
    assert request("/api/aie/prepare", p).status == 200
    assert {:ok, _} = Execute.enqueue(p, ctx.pending)
    third = IdentiKey.gen_keypair()
    assert request("/api/aie/prepare", proof(ctx, third, granted)).status == 403
    assert request("/api/aie/mint", mint_proof(ctx, third, third)).status == 403
    assert {:error, :nonce} = Execute.enqueue(p, ctx.pending)
  end

  test "stolen token, rebound input, design, audience and incarnation are refused", ctx do
    holder = IdentiKey.gen_keypair()
    p = proof(ctx, holder, token(ctx, holder))

    for changed <- [
          Map.put(p, "input_b64", Base.encode64("other")),
          Map.put(p, "design_id", "validate"),
          Map.put(p, "audience", "http://10.200.0.1:7422"),
          Map.put(p, "signature", Base.encode64(<<0::512>>))
        ] do
      assert {:error, :forbidden} = Execute.enqueue(changed, ctx.pending)
    end

    oversized =
      Map.put(p, "input_b64", Base.encode64(:binary.copy("x", Execute.max_input() + 1)))
      |> sign(holder)

    assert {:error, :forbidden} = Execute.enqueue(oversized, ctx.pending)
    assert :ok = Offer.publish(%{ctx.offer | sequence: 2}, ctx.owner)
    assert {:error, _} = Execute.enqueue(p, ctx.pending)
  end

  test "guest retries live pending_id without refreshing enqueue time or loading twice", ctx do
    holder = IdentiKey.gen_keypair()
    p = proof(ctx, holder, token(ctx, holder))
    {:ok, queued} = Execute.enqueue(p, ctx.pending)
    {:ok, before} = Pending.fetch(ctx.pending, queued.pending_id)
    {:ok, %{attempt_id: attempt}} = Occupancy.try_lock(ctx.occupancy)
    check = %{"proof" => p, "pending_id" => queued.pending_id, "attempt_id" => attempt}
    {:ok, checked} = Execute.check(check, ctx.pending)
    assert checked.input == :binary.bin_to_list("bounded input")

    body = %{
      "pending_id" => queued.pending_id,
      "attempt_id" => attempt,
      "resource" => checked.resource,
      "job_digest" => checked.job_digest
    }

    admit = fn ->
      conn(:post, "/admission", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_private(:aie_pending, ctx.pending)
      |> Admit.call(Admit.init([]))
    end

    assert Jason.decode!(admit.().resp_body)["kind"] == "live"
    assert :ok = Occupancy.mark_live_success(ctx.occupancy, attempt, queued.pending_id)
    assert :ok = Occupancy.authorize_load(ctx.occupancy, queued.pending_id, attempt)
    assert {:ok, _} = Execute.check(check, ctx.pending)
    assert Jason.decode!(admit.().resp_body)["kind"] == "historical"
    assert {:error, _} = Occupancy.authorize_load(ctx.occupancy, queued.pending_id, attempt)
    {:ok, after_retry} = Pending.fetch(ctx.pending, queued.pending_id)
    assert after_retry.enqueue_mono_ms == before.enqueue_mono_ms
    assert :ok = Occupancy.abandon(ctx.occupancy, attempt)

    assert {:error, :forbidden} =
             Execute.check(%{check | "attempt_id" => "new-attempt"}, ctx.pending)

    assert {:error, _} = Execute.enqueue(p, ctx.pending)
    assert {:ok, fresh} = Execute.enqueue(proof(ctx, holder, p["biscuit"]), ctx.pending)
    refute fresh.pending_id == queued.pending_id
  end

  test "cancel, queue age and restart require a fresh nonce and pending id", ctx do
    holder = IdentiKey.gen_keypair()
    grant = token(ctx, holder)

    for ending <- [:cancel, :expire, :restart] do
      p = proof(ctx, holder, grant)
      {:ok, q} = Execute.enqueue(p, ctx.pending)

      case ending do
        :cancel -> Pending.cancel(ctx.pending, q.pending_id)
        :expire -> Application.put_env(:mjolnir, :aie_max_queue_age_ms, -1)
        :restart -> Pending.reset(ctx.pending)
      end

      check = %{"proof" => p, "pending_id" => q.pending_id, "attempt_id" => "live-attempt"}
      assert {:error, :forbidden} = Execute.check(check, ctx.pending)
      assert {:error, _} = Execute.enqueue(p, ctx.pending)
      Application.put_env(:mjolnir, :aie_max_queue_age_ms, 60_000)
    end
  end

  test "offer withdrawal after enqueue refuses admission; pending proof cannot change", ctx do
    holder = IdentiKey.gen_keypair()
    p = proof(ctx, holder, token(ctx, holder))
    {:ok, q} = Execute.enqueue(p, ctx.pending)
    changed = Map.put(p, "input_b64", Base.encode64("rebound")) |> sign(holder)

    assert {:error, :forbidden} =
             Execute.check(
               %{"proof" => changed, "pending_id" => q.pending_id, "attempt_id" => "a"},
               ctx.pending
             )

    assert :ok = Offer.withdraw(ctx.fp, "npu", ctx.owner)

    assert {:error, :forbidden} =
             Execute.check(
               %{"proof" => p, "pending_id" => q.pending_id, "attempt_id" => "a"},
               ctx.pending
             )
  end

  @tag timeout: 600_000
  test "native clients agree on proof bytes and sidecar live retry dispatches once", ctx do
    holder = IdentiKey.gen_keypair()
    p = proof(ctx, holder, token(ctx, holder))
    vector = Path.join(System.tmp_dir!(), "aie-vector-#{System.unique_integer([:positive])}.json")

    File.write!(
      vector,
      Jason.encode!(%{
        proof: p,
        message_hex: Base.encode16(Execute.signing_message(p), case: :lower)
      })
    )

    on_exit(fn -> File.rm(vector) end)

    # Snapshot native/ so this test never rewrites the repo Cargo.lock.
    workspace = vector <> ".native"
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    File.write!(Path.join(workspace, "Cargo.toml"), """
    [workspace]
    members = ["mjolnir_protocol", "mjolnir_api", "mjolnir_client", "mjolnir_aie_sidecar"]
    resolver = "2"
    """)

    for name <- [
          "Cargo.lock",
          "mjolnir_protocol",
          "mjolnir_api",
          "mjolnir_client",
          "mjolnir_aie_sidecar"
        ] do
      File.cp_r!(Path.join("native", name), Path.join(workspace, name))
    end

    results =
      for {package, filter} <- [
            {"mjolnir-client", "compute::tests"},
            {"mjolnir-aie-sidecar", "guest_contract_tests"}
          ] do
        {output, code} =
          System.cmd("cargo", ["test", "--offline", "-p", package, filter],
            cd: workspace,
            env: [
              {"AIE_PROOF_VECTOR", vector},
              {"CARGO_TARGET_DIR", Path.expand("native/target")}
            ],
            stderr_to_stdout: true
          )

        {package, output, code}
      end

    assert Enum.all?(results, fn {_, _, code} -> code == 0 end),
           Enum.map_join(results, "\n", fn {package, output, code} ->
             "#{package}: exit #{code}\n#{output}"
           end)
  end
end
