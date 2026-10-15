defmodule Mjolnir.Auth.JwksHTTP do
  @moduledoc false

  # JokenJwks.HttpFetcher only treats `{:error, :econnrefused}` as a soft
  # failure. Any other `{:error, _}` misses its `with` and raises
  # WithClauseError. With `first_fetch_sync: true` that raise aborts
  # Application.start. The production issuer is a VM on this host, so a
  # restart cannot fetch keys until that VM is back — the fetch must fail
  # soft or the orchestrator crash-loops and never resumes the VM.

  require Logger

  @timeout 5_000

  def call(env, opts) do
    opts = Keyword.put_new(opts, :timeout, @timeout)
    soften(Tesla.Adapter.Mint.call(env, opts), env.url)
  end

  def soften({:ok, env}, _url), do: {:ok, env}

  def soften({:error, reason}, url) do
    Logger.warning("JWKS fetch #{url} failed: #{inspect(reason)}")
    {:error, :econnrefused}
  end
end
