defmodule Mjolnir.GuestFence.HostTest do
  use ExUnit.Case, async: true
  alias Mjolnir.GuestFence.Host

  setup do
    directory = Path.join(System.tmp_dir!(), "guest-fence-#{System.unique_integer([:positive])}")

    opts = [
      directory: directory,
      effect_contracts: ["policy-effect"],
      reconcile_authorizer: fn instance, _, _ -> instance == "reconciler" end
    ]

    host = start_supervised!({Host, opts})
    {:ok, channel} = Host.connect(host)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{host: host, channel: channel, directory: directory, opts: opts}
  end

  defp adopt(host, channel, receipts \\ []) do
    {:ok, c} = Host.classify(host, channel, receipts)
    {:ok, g} = Host.begin_adoption(host, channel, c)
    {:ok, adopted} = Host.commit(host, channel, %{op: :adopt, grant: g, classification: c})
    {:ok, confirmed} = Host.confirm(host, channel, adopted)
    {c, confirmed}
  end

  defp mutation(c, g, key \\ "key") do
    %{
      op: :admit,
      classification: c,
      grant: g,
      scope: "scope",
      key: key,
      digest: "digest-#{key}",
      effect_contract: "policy-effect"
    }
  end

  test "identity is host channel metadata, and undesignated instances cannot elect or borrow grants",
       ctx do
    {:ok, identity} = Host.identity(ctx.host, ctx.channel)
    assert Map.keys(identity) |> Enum.sort() == [:instance, :journal]
    {:ok, other} = Host.connect(ctx.host, "copied-disk-instance")
    {:ok, other_c} = Host.classify(ctx.host, other, [])
    assert {:error, :not_designated} = Host.begin_adoption(ctx.host, other, other_c)
    {:ok, c} = Host.classify(ctx.host, ctx.channel, [])
    {:ok, g} = Host.begin_adoption(ctx.host, ctx.channel, c)
    assert g.generation == 1
    assert {:error, :not_owner} = Host.confirm(ctx.host, other, g)
    assert {:error, :foreign_classification} = Host.begin_adoption(ctx.host, other, c)
    assert {:error, :foreign_classification} = Host.commit(ctx.host, other, mutation(c, g))
    assert {:error, :unauthenticated} = Host.identity(ctx.host, "guest-disk-token")
  end

  test "begin, adopt, and confirm recover the same pending and confirmed grant", ctx do
    {:ok, c} = Host.classify(ctx.host, ctx.channel, [])
    {:ok, g} = Host.begin_adoption(ctx.host, ctx.channel, c)
    assert g.state == :pending
    {:ok, c2} = Host.classify(ctx.host, ctx.channel, [])
    assert {:ok, ^g} = Host.begin_adoption(ctx.host, ctx.channel, c2)
    assert {:error, :not_adopted} = Host.confirm(ctx.host, ctx.channel, g)
    assert {:error, :unconfirmed} = Host.commit(ctx.host, ctx.channel, mutation(c, g))

    assert {:error, :unconfirmed} =
             Host.commit(ctx.host, ctx.channel, %{mutation(c, g) | op: :lease})

    {:ok, a} = Host.commit(ctx.host, ctx.channel, %{op: :adopt, classification: c2, grant: g})
    assert a.id == g.id
    {:ok, confirmed} = Host.confirm(ctx.host, ctx.channel, g)
    {:ok, c3} = Host.classify(ctx.host, ctx.channel, [])
    assert {:ok, ^confirmed} = Host.begin_adoption(ctx.host, ctx.channel, c3)

    assert {:ok, ^confirmed} =
             Host.commit(ctx.host, ctx.channel, %{op: :adopt, classification: c3, grant: g})

    assert {:ok, ^confirmed} = Host.confirm(ctx.host, ctx.channel, g)
    assert confirmed.generation == 1
  end

  test "owner coverage advances only on the issued id and copied ids work", ctx do
    {:ok, old} = Host.classify(ctx.host, ctx.channel, [])
    {c, g} = adopt(ctx.host, ctx.channel)
    copied = :erlang.binary_to_term(:erlang.term_to_binary(c))
    {:ok, r1} = Host.commit(ctx.host, ctx.channel, mutation(copied, g, "first"))
    assert {:error, :stale_classification} = Host.begin_adoption(ctx.host, ctx.channel, old)
    assert {:error, :stale_classification} = Host.commit(ctx.host, ctx.channel, mutation(old, g))
    assert {:error, :stale_classification} = Host.transfer(ctx.host, ctx.channel, old)
    {:ok, r2} = Host.commit(ctx.host, ctx.channel, mutation(c, g, "second"))
    assert r1.generation == r2.generation
    assert {:ok, _} = Host.classify(ctx.host, ctx.channel, [r1, r2])
  end

  test "classify covers all retained keys and rejects uncertain, conflicting, foreign, and legacy receipts",
       ctx do
    {c, g} = adopt(ctx.host, ctx.channel)
    {:ok, r} = Host.commit(ctx.host, ctx.channel, mutation(c, g))
    assert {:error, :incomplete_classification} = Host.classify(ctx.host, ctx.channel, [])

    assert {:error, :incomplete_classification} =
             Host.classify(ctx.host, ctx.channel, [%{r | claim_state: :uncertain}])

    assert {:error, :digest_mismatch} =
             Host.classify(ctx.host, ctx.channel, [%{r | digest: "different"}])

    assert {:error, :generation_mismatch} =
             Host.classify(ctx.host, ctx.channel, [%{r | generation: 2}])

    assert {:error, :legacy_receipt} =
             Host.classify(ctx.host, ctx.channel, [%{r | generation: 0}])

    assert {:error, :unknown_receipt} =
             Host.classify(ctx.host, ctx.channel, [%{r | key: "unknown"}])

    assert {:error, :duplicate_receipt} = Host.classify(ctx.host, ctx.channel, [r, r])

    assert {:error, :invalid_receipt} =
             Host.classify(ctx.host, ctx.channel, [Map.put(r, :secret, "no")])

    assert {:ok, _} = Host.classify(ctx.host, ctx.channel, [r])
  end

  test "retry returns observation only and digest and policy conflicts do not write", ctx do
    {c, g} = adopt(ctx.host, ctx.channel)
    parent = self()
    write = fn r -> send(parent, {:write, r}) end
    {:ok, r} = Host.commit(ctx.host, ctx.channel, mutation(c, g), write)
    assert_receive {:write, ^r}
    assert {:ok, ^r} = Host.commit(ctx.host, ctx.channel, mutation(c, g), write)
    refute_receive {:write, _}
    assert Enum.sort(Map.keys(r)) == [:claim_state, :digest, :generation, :key, :scope]

    assert {:error, :digest_conflict} =
             Host.commit(ctx.host, ctx.channel, %{mutation(c, g) | digest: "other"}, write)

    assert {:error, :unknown_effect_contract} =
             Host.commit(
               ctx.host,
               ctx.channel,
               %{mutation(c, g, "new") | effect_contract: "guest-owned"},
               write
             )

    assert {:error, :invalid_mutation} =
             Host.commit(
               ctx.host,
               ctx.channel,
               Map.put(mutation(c, g), :response_body, "secret"),
               write
             )

    assert {:error, :invalid_mutation} = Host.commit(ctx.host, ctx.channel, r, write)
    refute_receive {:write, _}
  end

  test "guest write failure retains admission and never retries the write", ctx do
    {c, g} = adopt(ctx.host, ctx.channel)

    assert {:error, {:guest_write_failed, receipt}} =
             Host.commit(ctx.host, ctx.channel, mutation(c, g), fn _ -> raise "lost" end)

    assert {:ok, ^receipt} =
             Host.commit(ctx.host, ctx.channel, mutation(c, g), fn _ -> flunk("resent") end)

    assert {:ok, _} = Host.classify(ctx.host, ctx.channel, [receipt])
  end

  test "transfer revokes during stalled callback, admission stays, and lost caller is not replayed",
       ctx do
    {c, g} = adopt(ctx.host, ctx.channel)
    parent = self()

    writer =
      spawn(fn ->
        {:ok, channel} = Host.connect(ctx.host, g.instance)

        Host.commit(ctx.host, channel, mutation(c, g), fn r ->
          send(parent, {:durable, r, channel})

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive {:durable, receipt, writer_channel}
    assert {:ok, _} = Host.classify(ctx.host, ctx.channel, [receipt])
    assert {:ok, new_identity} = Host.transfer(ctx.host, ctx.channel, c)
    assert new_identity.instance != g.instance
    assert {:error, :not_owner} = Host.confirm(ctx.host, ctx.channel, g)
    Process.exit(writer, :kill)
    # The write was accepted before the caller died, and transfer already ran.
    {:ok, new_channel} = Host.connect(ctx.host)
    {new_c, new_g} = adopt(ctx.host, new_channel, [receipt])
    assert new_g.generation > g.generation

    assert {:ok, ^receipt} =
             Host.commit(ctx.host, new_channel, mutation(new_c, new_g), fn _ ->
               flunk("resent")
             end)

    assert {:error, :unauthenticated} = Host.identity(ctx.host, writer_channel)
  end

  test "explicit disconnect and revocation drop authority without deleting retained rows", ctx do
    {c, g} = adopt(ctx.host, ctx.channel)
    assert :ok = Host.commit(ctx.host, ctx.channel, %{mutation(c, g) | op: :lease})
    {:ok, r} = Host.commit(ctx.host, ctx.channel, mutation(c, g))
    assert :ok = Host.disconnect(ctx.host, ctx.channel)

    assert {:error, :unauthenticated} =
             Host.commit(ctx.host, ctx.channel, mutation(c, g, "later"))

    {:ok, channel} = Host.connect(ctx.host)
    assert :ok = Host.revoke(ctx.host)
    assert {:error, :not_owner} = Host.commit(ctx.host, channel, mutation(c, g, "later"))
    assert {:ok, _} = Host.classify(ctx.host, channel, [r])
  end

  test "reconcile needs separate authority, permits revoked recorded grant, preserves digest",
       ctx do
    {c, g} = adopt(ctx.host, ctx.channel)
    {:ok, r} = Host.commit(ctx.host, ctx.channel, mutation(c, g))
    :ok = Host.revoke(ctx.host)
    m = %{op: :reconcile, scope: r.scope, key: r.key, grant: g}
    assert {:error, :unauthorized_reconcile} = Host.commit(ctx.host, ctx.channel, m)
    {:ok, reconciler} = Host.connect(ctx.host, "reconciler")
    assert {:ok, ^r} = Host.commit(ctx.host, reconciler, m, fn _ -> flunk("reconcile wrote") end)
    assert {:error, :unknown_key} = Host.commit(ctx.host, reconciler, %{m | key: "missing"})

    assert {:error, :unauthorized_reconcile} =
             Host.commit(ctx.host, reconciler, Map.put(m, :digest, "changed"))

    assert {:error, :invalid_grant} =
             Host.commit(ctx.host, reconciler, %{m | grant: %{g | generation: 99}})

    assert {:ok, _} = Host.classify(ctx.host, reconciler, [r])
  end

  test "restore and clone advance generation and keep historical admission generations", ctx do
    {c, g} = adopt(ctx.host, ctx.channel)
    {:ok, r} = Host.commit(ctx.host, ctx.channel, mutation(c, g))
    {:ok, identity} = Host.restore(ctx.host)
    assert identity.instance != g.instance
    {:ok, channel} = Host.connect(ctx.host)
    assert {:error, :unknown_classification} = Host.commit(ctx.host, ctx.channel, mutation(c, g))
    {new_c, new_g} = adopt(ctx.host, channel, [r])
    assert new_g.generation > g.generation
    {:ok, r2} = Host.commit(ctx.host, channel, mutation(new_c, new_g, "second"))
    assert r2.generation == new_g.generation
    assert {:ok, _} = Host.classify(ctx.host, channel, [r, r2])
    assert {:ok, _} = Host.clone(ctx.host)
  end

  test "pending grant, confirmed grant, coverage and admissions survive host restart", ctx do
    {:ok, c} = Host.classify(ctx.host, ctx.channel, [])
    {:ok, pending} = Host.begin_adoption(ctx.host, ctx.channel, c)
    :ok = stop_supervised(Host)
    host = start_supervised!({Host, ctx.opts})
    {:ok, channel} = Host.connect(host)
    {:ok, fresh} = Host.classify(host, channel, [])
    assert {:ok, ^pending} = Host.begin_adoption(host, channel, fresh)
    {:ok, _} = Host.commit(host, channel, %{op: :adopt, grant: pending, classification: fresh})
    {:ok, g} = Host.confirm(host, channel, pending)
    {:ok, r} = Host.commit(host, channel, mutation(fresh, g))
    :ok = stop_supervised(Host)
    host = start_supervised!({Host, ctx.opts})
    {:ok, channel} = Host.connect(host)
    assert {:ok, ^g} = Host.begin_adoption(host, channel, fresh)

    assert {:ok, ^r} =
             Host.commit(host, channel, mutation(fresh, g), fn _ ->
               flunk("resent after restart")
             end)
  end

  test "new OS process recovers pending and confirmed ownership plus accepted keys", ctx do
    {:ok, c} = Host.classify(ctx.host, ctx.channel, [])
    {:ok, pending} = Host.begin_adoption(ctx.host, ctx.channel, c)
    :ok = stop_supervised(Host)
    root = File.cwd!()

    script = """
    Code.require_file(#{inspect(Path.join(root, "lib/mjolnir/guest_fence/store.ex"))})
    Code.require_file(#{inspect(Path.join(root, "lib/mjolnir/guest_fence/host.ex"))})
    alias Mjolnir.GuestFence.Host
    {:ok, h} = Host.start_link(directory: #{inspect(ctx.directory)}, effect_contracts: ["policy-effect"])
    {:ok, ch} = Host.connect(h)
    {:ok, c} = Host.classify(h, ch, [])
    {:ok, g} = Host.begin_adoption(h, ch, c)
    true = g.id == #{inspect(pending.id)} and g.generation == 1
    {:ok, _} = Host.commit(h, ch, %{op: :adopt, grant: g, classification: c})
    {:ok, g} = Host.confirm(h, ch, g)
    Host.commit(h, ch, %{op: :admit, grant: g, classification: c,
      scope: "scope", key: "key", digest: "digest-key", effect_contract: "policy-effect"}, fn r ->
        true = r.generation == 1
        IO.puts("RECOVERED")
        :erlang.halt(0)
      end)
    raise "callback returned"
    """

    {output, status} =
      System.cmd("elixir", ["-e", script], env: [{"ERL_FLAGS", "+S 2:2"}], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "RECOVERED"
    host = start_supervised!({Host, ctx.opts})
    {:ok, channel} = Host.connect(host)
    r = %{scope: "scope", key: "key", digest: "digest-key", claim_state: :admitted, generation: 1}
    {fresh, g} = adopt(host, channel, [r])
    assert g.id == pending.id and g.generation == 1
    assert {:ok, ^r} = Host.commit(host, channel, mutation(fresh, g), fn _ -> flunk("resent") end)
  end

  test "partial or corrupted storage fails closed instead of forgetting grants", ctx do
    {:ok, c} = Host.classify(ctx.host, ctx.channel, [])
    {:ok, _} = Host.begin_adoption(ctx.host, ctx.channel, c)
    :ok = stop_supervised(Host)
    File.write!(Path.join(ctx.directory, "host.journal"), <<0, 1, 2>>, [:append])
    assert {:error, _} = start_supervised({Host, ctx.opts})
  end

  test "another host cannot open the same store in this runtime", ctx do
    assert {:error, _} = start_supervised({Host, ctx.opts}, id: :second_host)
  end

  test "missing journal never resets retained generation", ctx do
    {:ok, c} = Host.classify(ctx.host, ctx.channel, [])
    {:ok, _} = Host.begin_adoption(ctx.host, ctx.channel, c)
    :ok = stop_supervised(Host)
    File.rm!(Path.join(ctx.directory, "host.journal"))
    assert {:error, _} = start_supervised({Host, ctx.opts})
  end

  test "checksum damage fails closed", ctx do
    {:ok, c} = Host.classify(ctx.host, ctx.channel, [])
    {:ok, _} = Host.begin_adoption(ctx.host, ctx.channel, c)
    :ok = stop_supervised(Host)
    path = Path.join(ctx.directory, "host.journal")
    bytes = File.read!(path)
    last = :binary.last(bytes)
    damaged = binary_part(bytes, 0, byte_size(bytes) - 1) <> <<Bitwise.bxor(last, 1)>>
    File.write!(path, damaged)
    assert {:error, _} = start_supervised({Host, ctx.opts})
  end

  test "crash immediately after begin preserves the pending grant", ctx do
    :ok = stop_supervised(Host)
    root = File.cwd!()

    script = """
    Code.require_file(#{inspect(Path.join(root, "lib/mjolnir/guest_fence/store.ex"))})
    Code.require_file(#{inspect(Path.join(root, "lib/mjolnir/guest_fence/host.ex"))})
    alias Mjolnir.GuestFence.Host
    {:ok, h} = Host.start_link(directory: #{inspect(ctx.directory)})
    {:ok, ch} = Host.connect(h)
    {:ok, c} = Host.classify(h, ch, [])
    {:ok, g} = Host.begin_adoption(h, ch, c)
    IO.puts("PENDING=" <> g.id)
    :erlang.halt(0)
    """

    {output, status} =
      System.cmd("elixir", ["-e", script], env: [{"ERL_FLAGS", "+S 2:2"}], stderr_to_stdout: true)

    assert status == 0, output
    [_, grant_id] = Regex.run(~r/PENDING=([A-Za-z0-9_-]+)/, output)
    host = start_supervised!({Host, ctx.opts})
    {:ok, channel} = Host.connect(host)
    {:ok, c} = Host.classify(host, channel, [])
    {:ok, grant} = Host.begin_adoption(host, channel, c)
    assert grant.id == grant_id and grant.generation == 1 and grant.state == :pending
  end
end
