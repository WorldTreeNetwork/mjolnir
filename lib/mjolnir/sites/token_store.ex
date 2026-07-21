defmodule Mjolnir.Sites.TokenStore do
  @moduledoc """
  Durable store for `Mjolnir.Sites.Token` service credentials. One JSON file per
  token at `<sites_token_dir>/<id>.json`, mirrored into an ETS table for
  lock-free reads on the request path.

  Deliberately the same shape as `Mjolnir.StateStore`: atomic write
  (tmp + fsync + rename), GenServer-serialized writes, ETS reads, and bad files
  quarantined rather than discarded.

  ## Why the filesystem and not Postgres

  Postgres in this project is a **sidecar holding derived indexes**
  (`sites.head_index`, `sites.manifest_index`) that are rebuildable from disk,
  and `:pg_enabled` is false by default. Authentication cannot be a derived
  index: if the credential store is unreadable there are only two behaviours,
  fail closed (every publish 401s until Postgres recovers) or fail open
  (catastrophic). Putting the credential check behind an optional sidecar means
  a Postgres outage takes CI publishing down with it.

  Two further reasons: this lookup runs on *every* authenticated Sites request,
  where an ETS hit beats a database round trip; and the repo's stated design
  contract is already "filesystem is the source of truth, Postgres holds derived
  indexes" (see CLAUDE.md, Postgres Sidecar).

  `Mjolnir.SecretStore` was the other candidate and was rejected on contract
  grounds: it stores *IdentiKey-signed envelopes* keyed by fingerprint, and a
  service token is neither signed by an IdentiKey nor owned by one — it is host
  state minted by an operator.

  ## Reads vs writes

  `verify/1` and `get/1` read ETS directly. `put/1`, `revoke/1` and `delete/1`
  go through the GenServer so disk and cache stay coherent.
  """

  use GenServer
  require Logger

  alias Mjolnir.Sites.Token

  @table __MODULE__

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Directory holding one JSON file per token."
  @spec root() :: String.t()
  def root do
    Application.get_env(:mjolnir, :sites_token_dir) ||
      Path.join(Application.fetch_env!(:mjolnir, :state_dir), "sites-tokens")
  end

  @doc """
  Verify a presented `mjsk_...` credential.

  Returns `{:ok, token}` only for a credential that parses, exists, matches its
  stored hash in constant time, and is neither revoked nor expired. Every
  failure returns a bare atom — callers must not surface which one to the client,
  since the distinction between "no such id" and "wrong secret" is an oracle.
  """
  @spec verify(String.t()) ::
          {:ok, Token.t()} | {:error, :malformed | :unknown | :bad_secret | :revoked | :expired}
  def verify(raw) when is_binary(raw) do
    with {:ok, {id, secret}} <- parse(raw),
         {:ok, token} <- fetch(id) do
      check_token(token, secret)
    end
  end

  def verify(_), do: {:error, :malformed}

  # Order matters only for the error atom returned; the secret is always checked,
  # so a revoked or expired id cannot be used to probe for a valid secret.
  defp check_token(token, secret) do
    cond do
      not Token.secret_valid?(token, secret) -> {:error, :bad_secret}
      Token.revoked?(token) -> {:error, :revoked}
      Token.expired?(token) -> {:error, :expired}
      true -> {:ok, token}
    end
  end

  @doc """
  Look up a token by its (non-secret) id.

  Returns `:not_found` rather than raising if the ETS table is absent — that
  happens only in the window where a crashed store is being restarted, and an
  auth check must fail closed with a clean 401 there, not a 500.
  """
  @spec get(String.t()) :: {:ok, Token.t()} | :not_found
  def get(id) when is_binary(id) do
    case :ets.lookup(@table, id) do
      [{^id, token}] -> {:ok, token}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc "All tokens, newest first."
  @spec list() :: [Token.t()]
  def list do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, token} -> token end)
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  rescue
    ArgumentError -> []
  end

  @doc """
  Mint, persist, and return `{:ok, token, plaintext}`.

  The plaintext secret is returned to the caller once and never stored — see
  `Mjolnir.Sites.Token`.
  """
  @spec create(String.t(), keyword()) :: {:ok, Token.t(), String.t()} | {:error, term()}
  def create(identikey_fp, opts \\ []) when is_binary(identikey_fp) do
    {token, plaintext} = Token.mint(identikey_fp, opts)

    case put(token) do
      :ok -> {:ok, token, plaintext}
      {:error, _} = err -> err
    end
  end

  @doc "Persist a token record (create or overwrite)."
  @spec put(Token.t()) :: :ok | {:error, term()}
  def put(%Token{} = token) do
    if valid_id?(token.id) do
      GenServer.call(__MODULE__, {:put, token})
    else
      {:error, :invalid_token_id}
    end
  end

  @doc """
  Revoke a token by id. Permanent and idempotent — re-revoking keeps the
  original timestamp so an audit trail is not rewritten.
  """
  @spec revoke(String.t()) :: :ok | :not_found | {:error, term()}
  def revoke(id) when is_binary(id), do: GenServer.call(__MODULE__, {:revoke, id})

  @doc "Remove a token record entirely. Prefer `revoke/1` — this destroys the audit trail."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(id) when is_binary(id) do
    if valid_id?(id),
      do: GenServer.call(__MODULE__, {:delete, id}),
      else: {:error, :invalid_token_id}
  end

  ## GenServer

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])

    case File.mkdir_p(root()) do
      :ok ->
        count = load_all()
        Logger.info("Sites.TokenStore: root=#{root()} loaded=#{count}")

      {:error, reason} ->
        Logger.warning(
          "Sites.TokenStore: root #{root()} not creatable (#{inspect(reason)}); " <>
            "writes will retry on demand"
        )
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, token}, _from, state) do
    case write_record(token) do
      :ok ->
        :ets.insert(@table, {token.id, token})
        {:reply, :ok, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:revoke, id}, _from, state) do
    case get(id) do
      :not_found ->
        {:reply, :not_found, state}

      {:ok, %Token{revoked_at: at}} when not is_nil(at) ->
        {:reply, :ok, state}

      {:ok, token} ->
        revoked = %{token | revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)}

        case write_record(revoked) do
          :ok ->
            :ets.insert(@table, {revoked.id, revoked})
            Logger.info("Sites.TokenStore: revoked token #{revoked.id}")
            {:reply, :ok, state}

          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end

  def handle_call({:delete, id}, _from, state) do
    _ = File.rm(record_path(id))
    :ets.delete(@table, id)
    {:reply, :ok, state}
  end

  ## Internals

  defp parse(raw) do
    case Token.parse(raw) do
      {:ok, pair} -> {:ok, pair}
      :error -> {:error, :malformed}
    end
  end

  defp fetch(id) do
    case get(id) do
      {:ok, token} -> {:ok, token}
      :not_found -> {:error, :unknown}
    end
  end

  defp record_path(id), do: Path.join(root(), "#{id}.json")

  # Ids are minted as lowercase hex, so anything else is either corruption or an
  # attempt to steer a write out of the token directory. Checked on the caller's
  # side of the GenServer so a bad id returns an error instead of taking the
  # store down and dropping the ETS cache with it.
  defp valid_id?(id) when is_binary(id), do: String.match?(id, ~r/^[a-f0-9]{4,64}$/)
  defp valid_id?(_), do: false

  defp write_record(%Token{} = token) do
    path = record_path(token.id)
    bytes = Jason.encode!(Token.to_json(token))
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, io} <- :file.open(tmp, [:raw, :write, :binary]),
         :ok <- :file.write(io, bytes),
         :ok <- :file.sync(io),
         :ok <- :file.close(io),
         :ok <- File.rename(tmp, path),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      error ->
        _ = File.rm(tmp)
        {:error, error}
    end
  end

  defp load_all do
    case File.ls(root()) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.reduce(0, fn name, acc ->
          if load_one(Path.join(root(), name)), do: acc + 1, else: acc
        end)

      {:error, _} ->
        0
    end
  end

  defp load_one(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, map} <- Jason.decode(bytes),
         {:ok, token} <- Token.from_json(map) do
      :ets.insert(@table, {token.id, token})
      true
    else
      _ ->
        Logger.warning("Sites.TokenStore: quarantining unreadable record #{path}")
        quarantine(path)
        false
    end
  end

  defp quarantine(path) do
    dir = Path.join(root(), "quarantine")
    _ = File.mkdir_p(dir)
    _ = File.rename(path, Path.join(dir, Path.basename(path) <> ".bad"))
    :ok
  end
end
