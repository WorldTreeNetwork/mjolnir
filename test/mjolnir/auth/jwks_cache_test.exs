defmodule Mjolnir.Auth.JwksCacheTest do
  use ExUnit.Case, async: false

  import Bitwise
  alias Mjolnir.Auth.{JwksCache, JwksStrategy, Token}

  @issuer "https://issuer.example"

  setup_all do
    # The application may already supervise the configured issuer strategy.
    # Give each test exclusive ownership of the hook's default strategy name.
    if Process.whereis(Mjolnir.Supervisor) && Process.whereis(JwksStrategy) do
      :ok = Supervisor.terminate_child(Mjolnir.Supervisor, JwksStrategy)
      on_exit(fn -> Supervisor.restart_child(Mjolnir.Supervisor, JwksStrategy) end)
    end

    :ok
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "jwks-#{System.unique_integer([:positive])}")
    original_auth = Application.get_env(:mjolnir, :auth)
    Application.put_env(:mjolnir, :auth, issuer: @issuer)
    opts = JwksStrategy.init_opts(issuer: @issuer, auth_dir: dir)

    on_exit(fn ->
      if original_auth,
        do: Application.put_env(:mjolnir, :auth, original_auth),
        else: Application.delete_env(:mjolnir, :auth)

      File.rm_rf!(dir)
    end)

    {:ok, opts: opts, dir: dir, a: key("A"), b: key("B")}
  end

  test "secure bound cache survives offline reboot, with normal JWT checks", ctx do
    assert {:ok, _} = JwksCache.persist(document([ctx.a]), ctx.opts)
    assert {:ok, path} = JwksCache.path(ctx.opts)
    assert band(File.stat!(ctx.dir).mode, 0o777) == 0o700
    assert band(File.stat!(path).mode, 0o777) == 0o600
    start_strategy(ctx.opts)
    assert {:ok, _} = Token.verify_token(token(ctx.a))
    stop_supervised!(JwksStrategy)
    start_strategy(ctx.opts)
    assert {:ok, _} = Token.verify_token(token(ctx.a))
    assert {:error, _} = Token.verify_token(token(ctx.b))
    assert {:error, _} = Token.verify_token(token(ctx.a, %{"iss" => "https://wrong.example"}))
    assert {:error, _} = Token.verify_token(token(ctx.a, %{"exp" => Joken.current_time() - 60}))
    assert {:error, _} = Token.verify_token(token(ctx.b, %{}, "A"))
    wrong_alg = Joken.Signer.create("HS256", "secret", %{"kid" => "A"})
    assert {:error, _} = Token.verify_token(Joken.generate_and_sign!(%{}, %{}, wrong_alg))
  end

  test "wrong issuer, source, and stale format are rejected without preventing start", ctx do
    assert {:ok, _} = JwksCache.persist(document([ctx.a]), ctx.opts)

    for changed <- [
          Keyword.put(ctx.opts, :issuer, "https://new.example"),
          Keyword.put(ctx.opts, :jwks_url, "https://other.example/jwks")
        ] do
      assert {:error, :invalid_cache_binding} = JwksCache.load(changed)
      Application.put_env(:mjolnir, :auth, issuer: changed[:issuer])
      start_strategy(changed)
      assert {:error, _} = Token.verify_token(token(ctx.a, %{"iss" => changed[:issuer]}))
      stop_supervised!(JwksStrategy)
    end

    Application.put_env(:mjolnir, :auth, issuer: @issuer)
    {:ok, path} = JwksCache.path(ctx.opts)
    File.write!(path, Jason.encode!(document([ctx.a])))
    start_strategy(ctx.opts)
    assert {:error, _} = Token.verify_token(token(ctx.a))
  end

  test "empty, corrupt, unreadable and missing caches fail closed", ctx do
    assert {:error, _} = JwksCache.persist(%{"keys" => []}, ctx.opts)
    start_strategy(ctx.opts)
    assert {:error, _} = Token.verify_token(token(ctx.a))
    stop_supervised!(JwksStrategy)
    assert {:ok, _} = JwksCache.persist(document([ctx.a]), ctx.opts)
    {:ok, path} = JwksCache.path(ctx.opts)

    for bytes <- [
          "",
          "{broken",
          Jason.encode!(%{
            "version" => 1,
            "issuer" => @issuer,
            "jwks_url" => ctx.opts[:jwks_url],
            "jwks" => %{"keys" => []}
          })
        ] do
      File.write!(path, bytes)
      start_strategy(ctx.opts)
      assert {:error, _} = Token.verify_token(token(ctx.a))
      stop_supervised!(JwksStrategy)
    end

    assert {:ok, _} = JwksCache.persist(document([ctx.a]), ctx.opts)
    File.chmod!(path, 0o644)
    start_strategy(ctx.opts)
    assert {:error, _} = Token.verify_token(token(ctx.a))
  end

  test "trailing slash bindings normalize and old keys have no invented TTL", ctx do
    assert {:ok, _} = JwksCache.persist(document([ctx.a]), ctx.opts)

    assert {:ok, _} =
             JwksCache.load(
               ctx.opts
               |> Keyword.update!(:issuer, &(&1 <> "/"))
               |> Keyword.update!(:jwks_url, &(&1 <> "/"))
             )
  end

  test "unsafe directory and symlink into btrfs are rejected; sibling is safe", ctx do
    root = Path.join(ctx.dir, "btrfs")
    File.mkdir_p!(root)
    link = Path.join(ctx.dir, "alias")
    File.ln_s!(root, link)

    for dir <- [root, Path.join(root, "auth"), Path.join(link, "auth")] do
      opts = Keyword.merge(ctx.opts, auth_dir: dir, btrfs_root: root)
      assert {:error, :unsafe_auth_path} = JwksCache.persist(document([ctx.a]), opts)
      start_strategy(opts)
      assert {:error, _} = Token.verify_token(token(ctx.a))
      stop_supervised!(JwksStrategy)
    end

    opts = Keyword.merge(ctx.opts, auth_dir: root <> "-auth", btrfs_root: root)
    assert {:ok, _} = JwksCache.persist(document([ctx.a]), opts)
    File.rm_rf!(root <> "-auth")
  end

  test "validated documents replace A then A,B then B, including offline restart", ctx do
    {:ok, source} = Agent.start_link(fn -> document([ctx.a]) end)
    on_exit(fn -> if Process.alive?(source), do: Agent.stop(source) end)
    start_strategy(ctx.opts, adapter(source))
    await_key("A")
    Agent.update(source, fn _ -> document([ctx.a, ctx.b]) end)
    refresh()
    await_key("B")
    assert {:ok, _} = Token.verify_token(token(ctx.a))
    assert {:ok, _} = Token.verify_token(token(ctx.b))
    Agent.update(source, fn _ -> document([ctx.b]) end)
    refresh()
    await_absent("A")
    assert {:ok, _} = Token.verify_token(token(ctx.b))
    stop_supervised!(JwksStrategy)
    start_strategy(ctx.opts)
    assert {:error, _} = Token.verify_token(token(ctx.a))
    assert {:ok, _} = Token.verify_token(token(ctx.b))
  end

  test "malformed, empty, unsupported and conflicting documents preserve last good disk", ctx do
    good = document([ctx.a])
    assert {:ok, _} = JwksCache.persist(good, ctx.opts)
    {:ok, path} = JwksCache.path(ctx.opts)
    previous = File.read!(path)

    for bad <- [
          %{},
          %{"keys" => []},
          %{"keys" => [nil]},
          %{"keys" => [%{"kid" => "bad", "kty" => "oct", "alg" => "HS256", "k" => "a2V5"}]},
          %{"keys" => [%{"kid" => "bad", "kty" => "RSA", "alg" => "RS256"}]},
          document([ctx.a, {elem(ctx.b, 0), Map.put(elem(ctx.b, 1), "kid", "A")}])
        ] do
      assert {:error, _} = JwksCache.persist(bad, ctx.opts)
      assert File.read!(path) == previous
    end

    start_strategy(ctx.opts, fn env ->
      {:ok,
       %{
         env
         | status: 200,
           headers: [{"content-type", "application/json"}],
           body: Jason.encode!(%{"keys" => []})
       }}
    end)

    wait_idle()
    assert {:ok, _} = Token.verify_token(token(ctx.a))
    assert File.read!(path) == previous
  end

  test "failed persistence of additions and retirements preserves active set and disk", ctx do
    for {old, new, accepted, rejected} <- [
          {[ctx.a], [ctx.a, ctx.b], ctx.a, ctx.b},
          {[ctx.a, ctx.b], [ctx.b], ctx.a, nil}
        ] do
      assert {:ok, _} = JwksCache.persist(document(old), ctx.opts)
      {:ok, path} = JwksCache.path(ctx.opts)
      previous = File.read!(path)
      {:ok, source} = Agent.start_link(fn -> :offline end)
      start_strategy(ctx.opts, adapter(source))
      wait_idle()
      # A permissive directory is refused even when tests run as root.
      File.chmod!(ctx.dir, 0o755)
      Agent.update(source, fn _ -> document(new) end)
      refresh()
      wait_idle()
      assert File.read!(path) == previous
      assert {:ok, _} = Token.verify_token(token(accepted))
      if rejected, do: assert({:error, _} = Token.verify_token(token(rejected)))
      File.chmod!(ctx.dir, 0o700)
      stop_supervised!(JwksStrategy)
      start_strategy(ctx.opts)
      assert {:ok, _} = Token.verify_token(token(accepted))
      if rejected, do: assert({:error, _} = Token.verify_token(token(rejected)))
      stop_supervised!(JwksStrategy)
      Agent.stop(source)
    end
  end

  test "boot and known-key verification do not wait for refresh; refresh is bounded", ctx do
    assert {:ok, _} = JwksCache.persist(document([ctx.a]), ctx.opts)
    parent = self()

    blocked = fn _env ->
      send(parent, {:fetch_started, self()})

      receive do
        :never -> {:error, :econnrefused}
      end
    end

    start_strategy(Keyword.put(ctx.opts, :fetch_timeout, 100), blocked)
    assert_receive {:fetch_started, worker}
    monitor = Process.monitor(worker)
    assert {:ok, _} = Token.verify_token(token(ctx.a))
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
    assert {:ok, _} = Token.verify_token(token(ctx.a))
  end

  test "offline empty start retries automatically and operator delete withdraws trust", ctx do
    {:ok, source} = Agent.start_link(fn -> :offline end)
    start_strategy(Keyword.put(ctx.opts, :time_interval, 50), adapter(source))
    wait_idle()
    assert {:error, _} = Token.verify_token(token(ctx.a))
    Agent.update(source, fn _ -> document([ctx.a]) end)
    await_key("A")
    stop_supervised!(JwksStrategy)
    {:ok, path} = JwksCache.path(ctx.opts)
    File.rm!(path)
    start_strategy(ctx.opts)
    assert {:error, _} = Token.verify_token(token(ctx.a))
    stop_supervised!(JwksStrategy)
    assert {:ok, _} = JwksCache.persist(document([ctx.a]), ctx.opts)
    start_strategy(ctx.opts)
    assert {:ok, _} = Token.verify_token(token(ctx.a))
    Agent.stop(source)
  end

  test "disabled issuer rejects tokens even when cache keys exist", ctx do
    assert {:ok, _} = JwksCache.persist(document([ctx.a]), ctx.opts)
    start_strategy(ctx.opts)
    Application.put_env(:mjolnir, :auth, [])
    assert {:error, :no_issuer_configured} = Token.verify_token(token(ctx.a))
  end

  test "cache writes leave the shared edge bundle untouched", ctx do
    assert {:ok, _} = JwksCache.persist(document([ctx.a]), ctx.opts)
    bundle = Path.join(ctx.dir, "bundle.json")
    File.write!(bundle, "existing edge bundle")
    assert {:ok, _} = JwksCache.persist(document([ctx.b]), ctx.opts)
    assert File.read!(bundle) == "existing edge bundle"
  end

  defp key(kid) do
    private = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_, public} = JOSE.JWK.to_public_map(private)
    {private, Map.merge(public, %{"kid" => kid, "alg" => "ES256", "use" => "sig"})}
  end

  defp document(keys), do: %{"keys" => Enum.map(keys, &elem(&1, 1))}

  defp token({private, public}, overrides \\ %{}, kid \\ nil) do
    signer =
      Joken.Signer.create("ES256", elem(JOSE.JWK.to_map(private), 1), %{
        "kid" => kid || public["kid"]
      })

    claims =
      Map.merge(
        %{"iss" => @issuer, "sub" => "user", "exp" => Joken.current_time() + 600},
        overrides
      )

    Joken.generate_and_sign!(%{}, claims, signer)
  end

  defp start_strategy(opts, adapter \\ fn _ -> {:error, :econnrefused} end) do
    start_supervised!(
      {JwksStrategy,
       opts |> Keyword.put(:http_adapter, adapter) |> Keyword.put_new(:time_interval, 60_000)}
    )
  end

  defp adapter(source) do
    fn env ->
      case Agent.get(source, & &1) do
        :offline ->
          {:error, :econnrefused}

        doc ->
          {:ok,
           %{
             env
             | status: 200,
               headers: [{"content-type", "application/json"}],
               body: Jason.encode!(doc)
           }}
      end
    end
  end

  defp refresh, do: send(Process.whereis(JwksStrategy), :refresh)
  defp wait_idle, do: eventually(fn -> :sys.get_state(JwksStrategy).worker == nil end)

  defp await_key(kid),
    do: eventually(fn -> match?({:ok, _}, JwksStrategy.match_signer_for_kid(kid, [])) end)

  defp await_absent(kid),
    do: eventually(fn -> match?({:error, _}, JwksStrategy.match_signer_for_kid(kid, [])) end)

  defp eventually(predicate, attempts \\ 100)
  defp eventually(predicate, 0), do: assert(predicate.())

  defp eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end
end
