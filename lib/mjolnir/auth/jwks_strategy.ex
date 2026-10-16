defmodule Mjolnir.Auth.JwksStrategy do
  @moduledoc """
  JokenJWKS strategy for the configured OIDC issuer.

  Started when `:issuer` is set. The default document is
  `{issuer}/.well-known/jwks.json` (IdentiKey at `auth.identikey.me`).

  A deprecated Keycloak issuer (`connect.identikey.io`) still uses
  `{issuer}/protocol/openid-connect/certs`. Do not point new
  deployments there.

  ## Why the adapter is pinned here

  `JokenJwks.HttpFetcher` defaults to `Tesla.Adapter.Hackney`, and hackney's
  only CVE-free line (4.x) is forbidden by joken_jwks 1.7's own optional
  `~> 1.18` constraint — so hackney was dropped from the project entirely
  (mjolnir-ctv). This is the caller that made hackney reachable at all: it is
  not called from Mjolnir code, so a grep for "hackney" finds nothing and the
  breakage only shows up as a supervisor crash at boot.

  `Tesla.Adapter.Mint` replaces it. Mint is already in the tree under Req, and
  it verifies certificates by default via CAStore — which is the property
  joken_jwks's docs cite as the reason they chose hackney, so it must not be
  traded away for an adapter (e.g. `:httpc`) that defaults to not verifying.
  """

  use GenServer
  @behaviour JokenJwks.SignerMatchStrategy
  require Logger
  alias Mjolnir.Auth.JwksCache

  def start_link(opts) do
    GenServer.start_link(__MODULE__, init_opts(opts), name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def match_signer_for_kid(kid, opts) do
    table = Keyword.get(opts, :name, __MODULE__)

    case :ets.lookup(table, :signers) do
      [{:signers, signers}] -> Map.fetch(signers, kid) |> signer_result()
      [] -> {:error, :no_signers_fetched}
    end
  rescue
    ArgumentError -> {:error, :no_signers_fetched}
  end

  defp signer_result({:ok, signer}), do: {:ok, signer}
  defp signer_result(:error), do: {:error, :kid_does_not_match}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    table =
      :ets.new(Keyword.get(opts, :name, __MODULE__), [
        :named_table,
        :protected,
        read_concurrency: true
      ])

    signers =
      case JwksCache.load(opts) do
        {:ok, signers} ->
          signers

        {:error, reason} ->
          Logger.warning("JWKS cache unavailable: #{inspect(reason)}")
          %{}
      end

    :ets.insert(table, {:signers, signers})
    send(self(), :refresh)
    {:ok, %{opts: opts, table: table, worker: nil}}
  end

  @impl true
  def handle_info(:refresh, %{worker: nil} = state) do
    parent = self()
    opts = state.opts

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          result =
            try do
              case JokenJwks.HttpFetcher.fetch_signers(opts[:jwks_url], opts) do
                {:ok, keys} -> {:ok, %{"keys" => keys}}
                {:error, _} = error -> error
              end
            rescue
              _ -> {:error, :invalid_jwks_response}
            catch
              _, _ -> {:error, :jwks_fetch_failed}
            end

          send(parent, {:refreshed, self(), result})
        end,
        [:link, :monitor]
      )

    timer =
      Process.send_after(self(), {:fetch_timeout, ref}, Keyword.get(opts, :fetch_timeout, 15_000))

    {:noreply, %{state | worker: {pid, ref, timer}}}
  end

  def handle_info(:refresh, state), do: {:noreply, state}

  def handle_info({:refreshed, pid, result}, %{worker: {pid, ref, timer}} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(timer)

    publication =
      case result do
        {:ok, document} -> JwksCache.persist(document, state.opts)
        error -> error
      end

    case publication do
      {:ok, signers} -> :ets.insert(state.table, {:signers, signers})
      {:error, reason} -> Logger.warning("JWKS refresh kept last good set: #{inspect(reason)}")
    end

    {:noreply, schedule_refresh(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{worker: {_pid2, ref, timer}} = state) do
    Process.cancel_timer(timer)
    {:noreply, schedule_refresh(state)}
  end

  def handle_info({:fetch_timeout, ref}, %{worker: {pid, ref, _timer}} = state) do
    Process.exit(pid, :kill)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{worker: {pid, _, _}}), do: Process.exit(pid, :kill)
  def terminate(_reason, _state), do: :ok

  defp schedule_refresh(state) do
    Process.send_after(self(), :refresh, Keyword.get(state.opts, :time_interval, 60_000))
    %{state | worker: nil}
  end

  def init_opts(opts) do
    issuer = Keyword.fetch!(opts, :issuer) |> String.trim_trailing("/")

    jwks_url =
      Keyword.get(opts, :jwks_url) ||
        if keycloak_issuer?(issuer) do
          issuer <> "/protocol/openid-connect/certs"
        else
          issuer <> "/.well-known/jwks.json"
        end

    opts
    |> Keyword.put(:issuer, issuer)
    |> Keyword.put(:jwks_url, String.trim_trailing(jwks_url, "/"))
    |> Keyword.put_new(:http_adapter, Mjolnir.Auth.JwksHTTP)
    |> Keyword.put_new(:http_max_retries_per_fetch, 1)
    |> Keyword.put_new(:http_delay_per_retry, 200)
  end

  # Keycloak's realm certs URL is not the OIDC well-known path. Kept so an
  # explicit MJOLNIR_AUTH_ISSUER of the old realm still verifies.
  defp keycloak_issuer?(issuer) do
    String.contains?(issuer, "connect.identikey.io")
  end
end
