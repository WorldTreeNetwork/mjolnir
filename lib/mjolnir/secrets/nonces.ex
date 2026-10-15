defmodule Mjolnir.Secrets.Nonces do
  @moduledoc """
  Single-use nonces for holder-bound secret redeem.

  A nonce is 32 random bytes, hex-encoded, and lives for 60 seconds.
  `consume/1` succeeds once. A second consume, or an unknown nonce, is
  an error. The store is memory only: a restart invalidates outstanding
  challenges, which fails closed.
  """

  use GenServer

  @ttl_seconds 60

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec issue() :: String.t()
  def issue, do: GenServer.call(__MODULE__, :issue)

  @spec consume(String.t()) :: :ok | :error
  def consume(nonce) when is_binary(nonce), do: GenServer.call(__MODULE__, {:consume, nonce})

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call(:issue, _from, state) do
    nonce = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    exp = now() + @ttl_seconds
    {:reply, nonce, Map.put(sweep(state), nonce, exp)}
  end

  def handle_call({:consume, nonce}, _from, state) do
    state = sweep(state)

    case Map.pop(state, nonce) do
      {nil, state} -> {:reply, :error, state}
      {_exp, state} -> {:reply, :ok, state}
    end
  end

  defp now, do: System.monotonic_time(:second)

  defp sweep(state) do
    t = now()
    Map.filter(state, fn {_nonce, exp} -> exp > t end)
  end
end
