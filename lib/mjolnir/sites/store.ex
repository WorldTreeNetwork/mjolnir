defmodule Mjolnir.Sites.Store do
  @moduledoc """
  Content-addressed chunk store for site content. Layout matches the recrypt
  `LocalFileStorage` convention:

      <sites_root>/blob/b3/<bao_hash58>          ciphertext chunk
      <sites_root>/blob/b3/<bao_hash58>.obao     Bao outboard sibling
      <sites_root>/manifests/<snapshot_hash58>    Gordian envelope
      <sites_root>/manifests/<snapshot_hash58>.ots  OpenTimestamps proof
      <sites_root>/recordings/<hash58>.json       recording wrap index

  See `docs/plans/initiatives/identikey-sites.md` §4 and §6.1.

  All chunks are referenced by their Blake3 hash (over the ciphertext bytes).
  Writes verify the supplied bao_hash matches the bytes on receive — bytes that
  fail verification never land on disk.

  This module is the Elixir-side facade. Chunk (ciphertext + outboard)
  operations are delegated to a pluggable backend that implements the
  `Mjolnir.Sites.Storage` behaviour, selected at runtime via the
  `:sites_storage_backend` config (default `Mjolnir.Sites.Storage.Local`):

    * `Mjolnir.Sites.Storage.Local` — BTRFS files, layout-compatible with
      recrypt's `LocalFileStorage`. The default; keeps the unit suite green.
    * `Mjolnir.Sites.Storage.Recrypt` — HTTP sidecar delegating to the
      `recrypt-storage` crate (real Bao outboards, S3/B2 backend). See the
      "Storage integration decision" note in the design doc.

  Manifest and OTS storage are small signed records / receipts kept on the host
  filesystem; they are not part of the recrypt blob store and stay local here.
  """

  use GenServer
  require Logger

  alias Mjolnir.Sites.Storage

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Configured BTRFS subvolume root for sites storage."
  @spec root() :: String.t()
  def root do
    Application.fetch_env!(:mjolnir, :sites_root)
  end

  @doc "Path of a chunk's ciphertext file, by bao hash."
  @spec chunk_path(String.t()) :: String.t()
  def chunk_path(bao_hash58) do
    Path.join([root(), "blob", "b3", validate_hash!(bao_hash58)])
  end

  @doc "Path of a chunk's outboard sibling, by bao hash."
  @spec outboard_path(String.t()) :: String.t()
  def outboard_path(bao_hash58) do
    chunk_path(bao_hash58) <> ".obao"
  end

  @doc "Path of a manifest envelope, by snapshot hash."
  @spec manifest_path(String.t()) :: String.t()
  def manifest_path(snapshot_hash58) do
    Path.join([root(), "manifests", validate_hash!(snapshot_hash58)])
  end

  @doc "Path of an OpenTimestamps proof sibling, by snapshot hash."
  @spec ots_path(String.t()) :: String.t()
  def ots_path(snapshot_hash58) do
    manifest_path(snapshot_hash58) <> ".ots"
  end

  @doc "True if a chunk's ciphertext is present in the configured backend."
  @spec has_chunk?(String.t()) :: boolean()
  def has_chunk?(bao_hash58) do
    Storage.backend().has_chunk?(validate_hash!(bao_hash58))
  end

  @doc """
  Write a chunk + outboard, verifying the bytes match `bao_hash`. Returns
  `{:error, {:bao_mismatch, _}}` if verification fails — nothing is left
  behind in that case. Delegates to the configured `Sites.Storage` backend.
  """
  @spec put_chunk(String.t(), binary(), binary()) :: :ok | {:error, term()}
  def put_chunk(bao_hash58, ciphertext, outboard)
      when is_binary(ciphertext) and is_binary(outboard) do
    Storage.backend().put_chunk(validate_hash!(bao_hash58), ciphertext, outboard)
  end

  @doc """
  Read a chunk's ciphertext + outboard from the configured backend. Outboard is
  `<<>>` when no `.obao` sibling exists (small-file case).
  """
  @spec get_chunk(String.t()) ::
          {:ok, %{ciphertext: binary(), outboard: binary()}} | :not_found | {:error, term()}
  def get_chunk(bao_hash58) do
    Storage.backend().get_chunk(validate_hash!(bao_hash58))
  end

  @doc "Store a manifest envelope under its snapshot hash."
  @spec put_manifest(String.t(), binary()) :: :ok | {:error, term()}
  def put_manifest(snapshot_hash58, envelope_bytes) when is_binary(envelope_bytes) do
    GenServer.call(__MODULE__, {:put_manifest, snapshot_hash58, envelope_bytes})
  end

  @doc "Read a manifest envelope."
  @spec get_manifest(String.t()) :: {:ok, binary()} | :not_found
  def get_manifest(snapshot_hash58) do
    case File.read(manifest_path(snapshot_hash58)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Store an OTS proof alongside a manifest."
  @spec put_ots(String.t(), binary()) :: :ok | {:error, term()}
  def put_ots(snapshot_hash58, ots_bytes) when is_binary(ots_bytes) do
    GenServer.call(__MODULE__, {:put_ots, snapshot_hash58, ots_bytes})
  end

  @doc "Read an OTS proof."
  @spec get_ots(String.t()) :: {:ok, binary()} | :not_found
  def get_ots(snapshot_hash58) do
    case File.read(ots_path(snapshot_hash58)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  True when `hash` is base58btc of a 32-byte Blake3, or the shorter Sites
  form that drops leading zero bytes. Rejects traversal and short garbage.
  """
  @spec valid_blob_hash?(term()) :: boolean()
  def valid_blob_hash?(hash) when is_binary(hash) and byte_size(hash) in 40..90 do
    case Mjolnir.Base58.decode(hash) do
      {:ok, bytes} when byte_size(bytes) in 28..32 ->
        hash == Mjolnir.Base58.encode(bytes)

      _ ->
        false
    end
  end

  def valid_blob_hash?(_), do: false

  @doc "True when `text` is the canonical base58btc of 32 bytes."
  @spec valid_xid?(term()) :: boolean()
  def valid_xid?(text) when is_binary(text) do
    case Mjolnir.Base58.decode(text, 32) do
      {:ok, bytes} -> Mjolnir.Base58.encode(bytes) == text
      :error -> false
    end
  end

  def valid_xid?(_), do: false

  @doc """
  True when the configured backend can see this ciphertext object.

  Local stats the file. Recrypt sends HEAD. Neither path calls `has_chunk?/1`
  or `get_chunk/1`. Call this before `GenServer.call/3`, not inside it.
  """
  @spec chunk_present?(String.t()) :: boolean()
  def chunk_present?(hash) do
    if valid_blob_hash?(hash) do
      Storage.backend().chunk_present?(hash)
    else
      false
    end
  end

  @doc """
  Compare-and-set the owner wrap for `hash`. Serialized in this process.
  Does not look at the blob bytes. The caller already probed presence.
  """
  @spec register_recording(String.t(), String.t(), String.t(), binary()) ::
          {:ok, :created | :exists} | {:error, term()}
  def register_recording(sub, hash, owner_xid, wrap)
      when is_binary(sub) and sub != "" and is_binary(hash) and is_binary(owner_xid) and
             is_binary(wrap) do
    GenServer.call(__MODULE__, {:register_recording, sub, hash, owner_xid, wrap})
  end

  @doc """
  Compare-and-set one friend wrap. Only the registering `sub` succeeds.
  Does not call IdentiKey and does not probe the blob.
  """
  @spec add_recording_friend(String.t(), String.t(), String.t(), binary()) ::
          {:ok, :created | :exists} | {:error, term()}
  def add_recording_friend(sub, hash, friend_xid, wrap)
      when is_binary(sub) and sub != "" and is_binary(hash) and is_binary(friend_xid) and
             is_binary(wrap) do
    GenServer.call(__MODULE__, {:add_recording_friend, sub, hash, friend_xid, wrap})
  end

  @doc "Read a recording index from disk. Does not consult process state."
  @spec fetch_recording(String.t()) :: {:ok, map()} | :not_found | {:error, term()}
  def fetch_recording(hash) when is_binary(hash) do
    case recording_path(hash) do
      {:ok, path} -> read_recording_file(path)
      :error -> {:error, :bad_hash}
    end
  end

  ## GenServer

  @impl true
  def init(_opts) do
    blob_dir = Path.join([root(), "blob", "b3"])
    manifests_dir = Path.join([root(), "manifests"])

    case {File.mkdir_p(blob_dir), File.mkdir_p(manifests_dir)} do
      {:ok, :ok} ->
        Logger.info("Sites.Store: root=#{root()}")

      {a, b} ->
        Logger.warning(
          "Sites.Store: root #{root()} not creatable at startup (#{inspect({a, b})}); " <>
            "writes will retry on demand"
        )
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:put_manifest, snapshot_hash58, bytes}, _from, state) do
    {:reply, write_atomic(manifest_path(snapshot_hash58), bytes), state}
  end

  def handle_call({:put_ots, snapshot_hash58, bytes}, _from, state) do
    {:reply, write_atomic(ots_path(snapshot_hash58), bytes), state}
  end

  def handle_call({:register_recording, sub, hash, owner_xid, wrap}, _from, state) do
    {:reply, write_register(sub, hash, owner_xid, wrap), state}
  end

  def handle_call({:add_recording_friend, sub, hash, friend_xid, wrap}, _from, state) do
    {:reply, write_friend(sub, hash, friend_xid, wrap), state}
  end

  ## Internals

  defp validate_hash!(hash58) when is_binary(hash58) do
    if String.match?(hash58, ~r/^[A-Za-z0-9]+$/) do
      hash58
    else
      raise ArgumentError, "invalid bao hash: #{inspect(hash58)}"
    end
  end

  defp recording_path(hash) do
    if valid_blob_hash?(hash) do
      {:ok, Path.join([root(), "recordings", hash <> ".json"])}
    else
      :error
    end
  end

  defp recording_path_ok(hash) do
    case recording_path(hash) do
      {:ok, path} -> {:ok, path}
      :error -> {:error, :bad_hash}
    end
  end

  defp write_register(sub, hash, owner_xid, wrap) do
    with {:ok, path} <- recording_path_ok(hash),
         :ok <- reject_bad_wrap(wrap) do
      case read_recording_file(path) do
        :not_found ->
          row = %{
            "v" => 1,
            "hash" => hash,
            "owner_sub" => sub,
            "owner_xid" => owner_xid,
            "owner_wrap" => Base.url_encode64(wrap, padding: false),
            "friends" => []
          }

          with :ok <- write_atomic(path, Jason.encode!(row)), do: {:ok, :created}

        {:ok, row} ->
          cond do
            row["owner_sub"] == sub and row["owner_xid"] == owner_xid and
                same_wrap?(row["owner_wrap"], wrap) ->
              {:ok, :exists}

            row["owner_sub"] == sub ->
              {:error, :conflict}

            true ->
              {:error, :not_owner}
          end

        {:error, _} = err ->
          err
      end
    end
  end

  defp write_friend(sub, hash, friend_xid, wrap) do
    with {:ok, path} <- recording_path_ok(hash),
         :ok <- reject_bad_wrap(wrap) do
      case read_recording_file(path) do
        :not_found ->
          {:error, :not_found}

        {:error, _} = err ->
          err

        {:ok, row} ->
          cond do
            row["owner_sub"] != sub ->
              {:error, :not_owner}

            row["owner_xid"] == friend_xid ->
              {:error, :self}

            true ->
              case insert_friend(row["friends"], friend_xid, wrap) do
                :same ->
                  {:ok, :exists}

                :conflict ->
                  {:error, :conflict}

                {:new, friends} ->
                  with :ok <- write_atomic(path, Jason.encode!(%{row | "friends" => friends})),
                       do: {:ok, :created}

                :corrupt ->
                  {:error, :corrupt}
              end
          end
      end
    end
  end

  defp reject_bad_wrap(wrap) do
    if Mjolnir.Sites.WrapShape.valid?(wrap), do: :ok, else: {:error, :bad_wrap}
  end

  defp same_wrap?(stored, wrap) when is_binary(stored) and is_binary(wrap) do
    case Base.url_decode64(stored, padding: false) do
      {:ok, ^wrap} -> true
      _ -> false
    end
  end

  defp same_wrap?(_, _), do: false

  defp insert_friend(friends, xid, wrap) when is_list(friends) do
    encoded = Base.url_encode64(wrap, padding: false)

    case Enum.find(friends, &(is_map(&1) and &1["friend_xid"] == xid)) do
      nil ->
        {:new, friends ++ [%{"friend_xid" => xid, "wrap" => encoded}]}

      %{"wrap" => ^encoded} ->
        :same

      _ ->
        :conflict
    end
  end

  defp insert_friend(_, _, _), do: :corrupt

  defp read_recording_file(path) do
    case File.read(path) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok,
           %{
             "hash" => _,
             "owner_sub" => _,
             "owner_xid" => _,
             "owner_wrap" => _,
             "friends" => friends
           } = row}
          when is_list(friends) ->
            {:ok, row}

          {:ok, _} ->
            {:error, :corrupt}

          {:error, _} ->
            {:error, :corrupt}
        end

      {:error, :enoent} ->
        :not_found

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_atomic(final, bytes) do
    tmp = final <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(final)),
         {:ok, io} <- :file.open(tmp, [:raw, :write, :binary]),
         :ok <- :file.write(io, bytes),
         :ok <- :file.sync(io),
         :ok <- :file.close(io),
         :ok <- File.rename(tmp, final) do
      :ok
    else
      error ->
        _ = File.rm(tmp)
        {:error, error}
    end
  end
end
