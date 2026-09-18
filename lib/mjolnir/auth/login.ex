defmodule Mjolnir.Auth.Login do
  @moduledoc """
  In-flight authorization-code + PKCE logins for the browser `/term` page.

  One row per attempt, keyed by an unguessable `state`. `/auth/callback`
  redeems the code and sets `mj_term`.
  """

  use GenServer

  @ttl_ms 10 * 60 * 1000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    table = :ets.new(__MODULE__, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @doc """
  Start an authorization-code login that will land on `next` (already sanitized).
  """
  @spec begin(String.t()) :: {:ok, String.t()} | {:error, term()}
  def begin(next) when is_binary(next) do
    {verifier, challenge} = oidc().pkce()
    state = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    redirect = oidc().redirect_uri()

    case oidc().authorize_url(state, challenge, redirect) do
      {:ok, url} ->
        now = System.monotonic_time(:millisecond)

        :ets.insert(__MODULE__, {
          state,
          %{
            code_verifier: verifier,
            redirect_uri: redirect,
            next: next,
            expires_at: now + @ttl_ms
          }
        })

        {:ok, url}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Exchange `code` for a token using the PKCE verifier stored under `state`.
  """
  @spec complete(String.t(), String.t()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def complete(code, state) when is_binary(code) and is_binary(state) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(__MODULE__, state) do
      [] ->
        {:error, :not_found}

      [{^state, rec}] ->
        :ets.delete(__MODULE__, state)

        cond do
          now >= rec.expires_at ->
            {:error, :expired}

          true ->
            case oidc().exchange_code(code, rec.code_verifier, rec.redirect_uri) do
              {:ok, token} -> {:ok, token, rec.next}
              {:error, reason} -> {:error, reason}
            end
        end
    end
  end

  @doc """
  A `/term/...` return path. Anything else becomes `/` so an open redirect
  cannot bounce the browser off-origin after login.
  """
  @spec safe_next(term()) :: String.t()
  def safe_next(next) when is_binary(next) do
    if Regex.match?(~r/\A\/term\/[0-9a-f-]{36}(?:\?session=[A-Za-z0-9_-]{1,64})?\z/, next) do
      next
    else
      "/"
    end
  end

  def safe_next(_), do: "/"

  defp oidc do
    Application.get_env(:mjolnir, :auth, [])
    |> Keyword.get(:oidc_mod, Mjolnir.Auth.Oidc)
  end
end
