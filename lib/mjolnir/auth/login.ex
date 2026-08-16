defmodule Mjolnir.Auth.Login do
  @moduledoc """
  In-flight IdentiKey Connect device-code logins for the browser `/term` page.

  One row per attempt, keyed by an unguessable id. The wait-tab polls
  `poll/1`; we ask Keycloak at most once per `interval` seconds.
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
  Start a device-code login that will land on `next` (already sanitized).
  """
  @spec begin(String.t()) :: {:ok, map()} | {:error, term()}
  def begin(next) when is_binary(next) do
    {verifier, challenge} = Mjolnir.Auth.Oidc.pkce()
    oidc = oidc()

    case oidc.start_device(challenge) do
      {:ok, device} ->
        id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
        now = System.monotonic_time(:millisecond)

        :ets.insert(__MODULE__, {
          id,
          %{
            oidc: oidc,
            device_code: device.device_code,
            code_verifier: verifier,
            next: next,
            interval_ms: device.interval * 1000,
            expires_at: now + @ttl_ms,
            last_poll: nil,
            token: nil
          }
        })

        {:ok,
         %{
           id: id,
           user_code: device.user_code,
           verification_uri: device.verification_uri_complete
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Ask Keycloak whether this login has completed.

  Returns `{:ok, token, next}`, `:pending`, or `{:error, reason}`.
  """
  @spec poll(String.t()) :: {:ok, String.t(), String.t()} | :pending | {:error, term()}
  def poll(id) when is_binary(id) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(__MODULE__, id) do
      [] ->
        {:error, :not_found}

      [{^id, %{token: token, next: next}}] when is_binary(token) ->
        {:ok, token, next}

      [{^id, rec}] ->
        cond do
          now >= rec.expires_at ->
            :ets.delete(__MODULE__, id)
            {:error, :expired}

          is_integer(rec.last_poll) and now - rec.last_poll < rec.interval_ms ->
            :pending

          true ->
            do_poll(id, rec, now)
        end
    end
  end

  @doc """
  A `/term/...` return path. Anything else becomes `/` so an open redirect
  cannot be smuggled through `?next=`.
  """
  @spec safe_next(nil | String.t()) :: String.t()
  def safe_next(nil), do: "/"

  def safe_next(next) when is_binary(next) do
    if Regex.match?(~r/\A\/term\/[0-9a-f-]{36}(?:\?session=[A-Za-z0-9_-]{1,64})?\z/, next) do
      next
    else
      "/"
    end
  end

  defp do_poll(id, rec, now) do
    :ets.insert(__MODULE__, {id, %{rec | last_poll: now}})

    case rec.oidc.poll_token(rec.device_code, rec.code_verifier) do
      {:ok, token} ->
        :ets.insert(__MODULE__, {id, %{rec | token: token, last_poll: now}})
        {:ok, token, rec.next}

      :pending ->
        :pending

      :slow_down ->
        :ets.insert(
          __MODULE__,
          {id, %{rec | last_poll: now, interval_ms: rec.interval_ms + 5_000}}
        )

        :pending

      {:error, reason} ->
        :ets.delete(__MODULE__, id)
        {:error, reason}
    end
  end

  defp oidc do
    Application.get_env(:mjolnir, :auth, [])
    |> Keyword.get(:oidc_mod, Mjolnir.Auth.Oidc)
  end
end
