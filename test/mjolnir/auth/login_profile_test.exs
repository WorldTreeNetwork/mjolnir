defmodule Mjolnir.Auth.LoginProfileTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Auth.LoginProfile
  alias Mjolnir.Sites.IdentiKey

  @now 1_800_000_000
  @edge String.duplicate("a", 64)
  @other_edge String.duplicate("b", 64)
  @holder_rights [{"vms:read", "vm-a"}, {"vms:read", "vm-b"}]

  setup do
    root = Mjolnir.Biscuit.keypair()
    session = IdentiKey.gen_keypair()
    nonce = :binary.copy(<<0x42>>, 32)

    claims = %{
      subject_xid: "did:xid:alice",
      edge_xid: @edge,
      rights: @holder_rights,
      exp: @now + 300,
      session_public: session.ed25519_public
    }

    {:ok, token} = LoginProfile.mint(root.private_hex, claims, now: @now)

    request = %{
      edge_xid: @edge,
      operation: "vms:read",
      resource: "vm-a",
      method: "GET",
      request_target: "/api/vms/vm-a?session=main",
      body: <<>>
    }

    %{root: root, session: session, nonce: nonce, token: token, request: request, claims: claims}
  end

  test "holder-bound authorization requires a valid request signature", ctx do
    assert {:deny, :invalid_holder_proof} = authorize(ctx, ctx.request)

    request = put_proof(ctx, ctx.request, ctx.session)

    assert {:allow, %{login_mode: :holder, subject_xid: "did:xid:alice"}} =
             authorize(ctx, request)
  end

  test "a stolen token and a proof from the wrong key fail", ctx do
    thief = IdentiKey.gen_keypair()
    request = put_proof(ctx, ctx.request, thief)

    assert {:deny, :invalid_holder_proof} = authorize(ctx, request)
  end

  test "proof is bound to exact token, method, target including query, and body", ctx do
    request = put_proof(ctx, ctx.request, ctx.session)

    assert {:deny, :invalid_holder_proof} =
             authorize(ctx, %{request | request_target: "/api/vms/vm-a?session=other"})

    assert {:deny, :invalid_holder_proof} = authorize(ctx, %{request | body: "changed"})
    assert {:deny, :invalid_holder_proof} = authorize(ctx, %{request | method: "POST"})
  end

  test "nonce consumption is atomic and replay or unknown nonce fails closed", ctx do
    request = put_proof(ctx, ctx.request, ctx.session)
    {:ok, store} = Agent.start_link(fn -> %{ctx.nonce => @now + 100} end)
    consume = nonce_store(store)

    assert {:allow, _} = authorize(ctx, request, nonce_store: consume)
    assert {:deny, :unknown_nonce} = authorize(ctx, request, nonce_store: consume)

    unknown = :binary.copy(<<0x99>>, 32)
    request = put_proof(%{ctx | nonce: unknown}, ctx.request, ctx.session)
    assert {:deny, :unknown_nonce} = authorize(ctx, request, nonce_store: consume)
  end

  test "edge audience and resource attenuation are request-bound", ctx do
    request = put_proof(ctx, ctx.request, ctx.session)

    assert {:deny, :wrong_audience} =
             LoginProfile.authorize(
               ctx.token,
               request,
               %{root_public_hex: ctx.root.public_hex, edge_xid: @other_edge},
               now: @now,
               nonce_store: nonce_store(ctx.nonce)
             )

    assert {:deny, :forbidden} = authorize(ctx, %{request | resource: "vm-c"})
  end

  test "explicit bearer is shorter and narrower, needs no proof, and overbroad mint fails", ctx do
    bearer_claims = %{
      subject_xid: ctx.claims.subject_xid,
      edge_xid: @edge,
      rights: [{"vms:read", "vm-a"}],
      exp: @now + 100
    }

    policy = %{rights: @holder_rights, exp: @now + 300}

    assert {:ok, bearer} =
             LoginProfile.mint_bearer(ctx.root.private_hex, bearer_claims, policy, now: @now)

    trusted = %{root_public_hex: ctx.root.public_hex, edge_xid: @edge}

    assert {:allow, %{login_mode: :bearer}} =
             LoginProfile.authorize(bearer, ctx.request, trusted, now: @now)

    assert {:error, :overbroad_bearer} =
             LoginProfile.mint_bearer(
               ctx.root.private_hex,
               %{bearer_claims | rights: @holder_rights},
               policy,
               now: @now
             )
  end

  test "expiry and a foreign mint root deny", ctx do
    request = put_proof(ctx, ctx.request, ctx.session, @now + 400)
    assert {:deny, :invalid_holder_proof} = authorize(ctx, request)

    request = put_proof(ctx, ctx.request, ctx.session)

    assert {:deny, :expired} =
             LoginProfile.authorize(
               ctx.token,
               request,
               %{root_public_hex: ctx.root.public_hex, edge_xid: @edge},
               now: @now + 301,
               nonce_store: nonce_store(ctx.nonce)
             )

    foreign = Mjolnir.Biscuit.keypair()

    assert {:deny, :invalid_capability} =
             LoginProfile.authorize(
               ctx.token,
               request,
               %{root_public_hex: foreign.public_hex, edge_xid: @edge},
               now: @now,
               nonce_store: nonce_store(ctx.nonce)
             )
  end

  test "authority-bound mode cannot be downgraded by changing holder to bearer", ctx do
    downgraded = replace_profile_mode(ctx.token, "holder", "bearer")

    assert {:deny, :invalid_profile} =
             LoginProfile.authorize(
               downgraded,
               ctx.request,
               %{root_public_hex: ctx.root.public_hex, edge_xid: @edge},
               now: @now
             )

    # Even the intact holder token never takes the bearer path.
    assert {:deny, :invalid_holder_proof} = authorize(ctx, ctx.request)
  end

  defp authorize(ctx, request, extra \\ []) do
    opts = Keyword.merge([now: @now, nonce_store: nonce_store(ctx.nonce)], extra)

    LoginProfile.authorize(
      ctx.token,
      request,
      %{root_public_hex: ctx.root.public_hex, edge_xid: @edge},
      opts
    )
  end

  defp put_proof(ctx, request, keypair, proof_exp \\ @now + 60) do
    proof =
      LoginProfile.sign_proof(ctx.token, request, @edge, ctx.nonce, proof_exp, keypair)

    Map.put(request, :proof, proof)
  end

  defp nonce_store(agent) when is_pid(agent) do
    fn nonce, now, proof_exp ->
      Agent.get_and_update(agent, fn outstanding ->
        case Map.pop(outstanding, nonce) do
          {nonce_exp, rest}
          when is_integer(nonce_exp) and now < proof_exp and proof_exp <= nonce_exp ->
            {:ok, rest}

          _ ->
            {{:error, :unknown_nonce}, outstanding}
        end
      end)
    end
  end

  defp nonce_store(nonce) when is_binary(nonce) do
    fn presented, now, proof_exp ->
      if presented == nonce and now < proof_exp and proof_exp <= @now + 100,
        do: :ok,
        else: {:error, :unknown_nonce}
    end
  end

  defp replace_profile_mode(<<"MJLP1", size::unsigned-big-32, rest::binary>>, from, to) do
    <<profile::binary-size(^size), biscuit::binary>> = rest
    changed = String.replace(profile, ~s("#{from}"), ~s("#{to}"), global: false)
    <<"MJLP1", byte_size(changed)::unsigned-big-32, changed::binary, biscuit::binary>>
  end
end
