defmodule Mjolnir.Sites.Store do
  @moduledoc """
  Content-addressed chunk store for site content. Layout matches the recrypt
  `LocalFileStorage` convention:

      <sites_root>/blob/b3/<bao_hash58>          ciphertext chunk
      <sites_root>/blob/b3/<bao_hash58>.obao     Bao outboard sibling
      <sites_root>/manifests/<snapshot_hash58>    Gordian envelope
      <sites_root>/manifests/<snapshot_hash58>.ots  OpenTimestamps proof

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

  ## Internals

  defp validate_hash!(hash58) when is_binary(hash58) do
    if String.match?(hash58, ~r/^[A-Za-z0-9]+$/) do
      hash58
    else
      raise ArgumentError, "invalid bao hash: #{inspect(hash58)}"
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
