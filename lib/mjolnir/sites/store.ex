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

  This module is the Elixir-side facade. The actual Bao tree construction /
  verification is delegated to a Rust helper (planned: NIF or sidecar binary
  wrapping `bao-tree`). For Phase 1 scaffolding the verification path is
  STUBBED — see `verify_bao!/3`.
  """

  use GenServer
  require Logger

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

  @doc "True if a chunk's ciphertext + outboard are both on disk."
  @spec has_chunk?(String.t()) :: boolean()
  def has_chunk?(bao_hash58) do
    File.regular?(chunk_path(bao_hash58)) and File.regular?(outboard_path(bao_hash58))
  end

  @doc """
  Write a chunk + outboard, verifying the bytes match `bao_hash`. Returns
  `{:error, :bao_mismatch}` if verification fails — nothing is left on disk
  in that case.
  """
  @spec put_chunk(String.t(), binary(), binary()) :: :ok | {:error, term()}
  def put_chunk(bao_hash58, ciphertext, outboard)
      when is_binary(ciphertext) and is_binary(outboard) do
    GenServer.call(__MODULE__, {:put_chunk, bao_hash58, ciphertext, outboard})
  end

  @doc """
  Read a chunk's ciphertext + outboard. Verification on read is the caller's
  responsibility for streaming use — call `verify_bao!/3` if needed.
  """
  @spec get_chunk(String.t()) ::
          {:ok, %{ciphertext: binary(), outboard: binary()}} | :not_found
  def get_chunk(bao_hash58) do
    cp = chunk_path(bao_hash58)
    op = outboard_path(bao_hash58)

    with {:ok, ct} <- File.read(cp),
         {:ok, ob} <- File.read(op) do
      {:ok, %{ciphertext: ct, outboard: ob}}
    else
      {:error, :enoent} -> :not_found
      {:error, _} = err -> err
    end
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
  def handle_call({:put_chunk, bao_hash58, ciphertext, outboard}, _from, state) do
    with :ok <- verify_bao!(bao_hash58, ciphertext, outboard),
         :ok <- write_atomic(chunk_path(bao_hash58), ciphertext),
         :ok <- write_atomic(outboard_path(bao_hash58), outboard) do
      {:reply, :ok, state}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

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

  # Whole-content Blake3 verification. Phase 1 does not stream-verify with
  # the .obao; that arrives with the real Bao-tree wiring. For Phase 1 we
  # check the ciphertext hash matches the supplied bao_hash. The outboard
  # bytes are stored as-supplied (empty allowed in Phase 1) for future use.
  defp verify_bao!(_bao_hash58, <<>>, _outboard), do: {:error, :empty_ciphertext}

  defp verify_bao!(bao_hash58, ciphertext, _outboard) do
    actual = Mjolnir.Sites.Crypto.blake3_hash_base58(ciphertext)

    if actual == bao_hash58 do
      :ok
    else
      {:error, {:bao_mismatch, expected: bao_hash58, actual: actual}}
    end
  end
end
