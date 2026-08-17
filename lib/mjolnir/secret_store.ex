defmodule Mjolnir.SecretStore do
  @moduledoc """
  Durable signed-record key-value store, keyed by `(identikey_fp, key)` where
  `key` is a `/`-separated path inside the IdentiKey's keyspace.

  Records are Gordian envelope bytes signed by the owning IdentiKey. The store
  is the single source of truth for IdentiKey-rooted mutable state: site HEAD
  pointers, Iroh-node bindings, per-site config, etc.

  See `docs/plans/initiatives/identikey-sites.md` §7 for the design context.

  ## Layout

      <secret_store_root>/
      `-- <identikey_fp58>/
          `-- <key_segment>/.../<leaf>

  Each leaf is the serialized envelope bytes for one record. Writes are atomic
  (tmp + rename). Signature verification is currently STUBBED — the seam is
  `verify_envelope/2`, to be wired to recrypt's MultiSig verification when the
  Rust integration lands.

  ## Public API

      SecretStore.put(identikey_fp, "sites/blog/HEAD", envelope_bytes)
      SecretStore.get(identikey_fp, "sites/blog/HEAD")
      SecretStore.list(identikey_fp, "sites/blog")
      SecretStore.delete(identikey_fp, "sites/blog/HEAD", tombstone_bytes)
  """

  use GenServer
  require Logger

  alias Mjolnir.Sites.{AliasRecord, HeadRecord, IdentiKey, Manifest}

  @type identikey_fp :: String.t()
  @type key :: String.t()
  @type envelope :: binary()

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Persist a signed envelope under `(identikey_fp, key)`. The envelope MUST be
  signed by the IdentiKey identified by `identikey_fp`; verification happens
  before the on-disk write.
  """
  @spec put(identikey_fp(), key(), envelope()) :: :ok | {:error, term()}
  def put(identikey_fp, key, envelope) when is_binary(envelope) do
    _ = validate_fp!(identikey_fp)
    _ = validate_key!(key)
    GenServer.call(__MODULE__, {:put, identikey_fp, key, envelope})
  end

  @doc """
  Read the envelope bytes for `(identikey_fp, key)`. Signature verification is
  the caller's responsibility on read; stored bytes are pre-verified at write.
  """
  @spec get(identikey_fp(), key()) :: {:ok, envelope()} | :not_found
  def get(identikey_fp, key) do
    path = record_path(identikey_fp, key)

    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  List leaf keys under a key prefix. Returns the relative paths (without the
  identikey root). Order is filesystem-defined.
  """
  @spec list(identikey_fp(), key()) :: [key()]
  def list(identikey_fp, key_prefix) do
    root = record_path(identikey_fp, key_prefix)

    case walk(root) do
      {:ok, paths} ->
        prefix_len = byte_size(record_path(identikey_fp, "")) + 1

        Enum.map(paths, fn p ->
          binary_part(p, prefix_len, byte_size(p) - prefix_len)
        end)

      :not_found ->
        []
    end
  end

  @doc """
  Delete a record by replacing it with a signed tombstone envelope. The
  tombstone bytes are themselves stored (so peers can replicate the deletion
  decision) until garbage collection sweeps tombstones older than a grace
  period.

  TODO Phase 1: tombstone semantics, GC sweep. Current implementation just
  removes the file.
  """
  @spec delete(identikey_fp(), key(), envelope()) :: :ok | {:error, term()}
  def delete(identikey_fp, key, tombstone) when is_binary(tombstone) do
    _ = validate_fp!(identikey_fp)
    _ = validate_key!(key)
    GenServer.call(__MODULE__, {:delete, identikey_fp, key, tombstone})
  end

  @doc """
  Look up which (identikey_fp, site_name) owns a custom-domain FQDN.

  Reads from the reverse index at `<root>/_index/aliases/<fqdn>`.
  Returns `{:ok, {fp, site_name}}` or `:not_found`.
  """
  @spec lookup_alias(String.t()) :: {:ok, {String.t(), String.t()}} | :not_found
  def lookup_alias(fqdn) when is_binary(fqdn) do
    # validate_fqdn! is allowed to raise — lookup is called on untrusted Host
    # headers, so silently treat bad inputs as :not_found.
    try do
      path = alias_index_path(fqdn)

      case File.read(path) do
        {:ok, contents} ->
          case parse_alias_index(contents) do
            {fp, site_name} -> {:ok, {fp, site_name}}
            :error -> :not_found
          end

        {:error, :enoent} ->
          :not_found

        {:error, _} ->
          :not_found
      end
    rescue
      ArgumentError -> :not_found
    end
  end

  @doc "Filesystem root configured via `config :mjolnir, :secret_store_root`."
  @spec root() :: String.t()
  def root do
    Application.fetch_env!(:mjolnir, :secret_store_root)
  end

  @doc """
  Persist an opaque (unsigned) blob under `_opaque/<kind>/<id>/<key>`.

  Used for VM-scoped material that is not a Gordian envelope (Buzz nsec).
  Atomic write, mode 0600. Never logged. `kind` and `id` must be path-safe.
  """
  @spec put_opaque(String.t(), String.t(), String.t(), binary()) :: :ok | {:error, term()}
  def put_opaque(kind, id, key, bytes)
      when is_binary(kind) and is_binary(id) and is_binary(key) and is_binary(bytes) do
    with :ok <- validate_opaque_segment(kind),
         :ok <- validate_opaque_segment(id),
         :ok <- validate_opaque_key(key),
         path = opaque_path(kind, id, key),
         :ok <- File.mkdir_p(Path.dirname(path)),
         tmp = path <> ".tmp",
         :ok <- File.write(tmp, bytes),
         _ = File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path),
         _ = File.chmod(path, 0o600) do
      :ok
    end
  end

  @doc "Read an opaque blob. `:not_found` if missing."
  @spec get_opaque(String.t(), String.t(), String.t()) ::
          {:ok, binary()} | :not_found | {:error, term()}
  def get_opaque(kind, id, key) do
    with :ok <- validate_opaque_segment(kind),
         :ok <- validate_opaque_segment(id),
         :ok <- validate_opaque_key(key),
         path = opaque_path(kind, id, key) do
      case File.read(path) do
        {:ok, bytes} -> {:ok, bytes}
        {:error, :enoent} -> :not_found
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Delete one opaque blob. Idempotent."
  @spec delete_opaque(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete_opaque(kind, id, key) do
    with :ok <- validate_opaque_segment(kind),
         :ok <- validate_opaque_segment(id),
         :ok <- validate_opaque_key(key),
         path = opaque_path(kind, id, key) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Delete every opaque blob for `<kind>/<id>`. Idempotent."
  @spec delete_opaque_id(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_opaque_id(kind, id) do
    with :ok <- validate_opaque_segment(kind),
         :ok <- validate_opaque_segment(id) do
      dir = Path.join([root(), "_opaque", kind, id])

      case File.rm_rf(dir) do
        {:ok, _} -> :ok
        {:error, reason, _} -> {:error, reason}
      end
    end
  end

  ## GenServer

  @impl true
  def init(_opts) do
    case File.mkdir_p(root()) do
      :ok ->
        Logger.info("SecretStore: root=#{root()}")

      {:error, reason} ->
        Logger.warning(
          "SecretStore: root #{root()} not creatable at startup (#{inspect(reason)}); " <>
            "writes will retry on demand"
        )
    end

    rebuild_alias_index()

    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, identikey_fp, key, envelope}, _from, state) do
    with :ok <- verify_envelope(identikey_fp, envelope),
         :ok <- write_atomic(identikey_fp, key, envelope),
         :ok <- maybe_write_alias_index(identikey_fp, key) do
      {:reply, :ok, state}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:delete, identikey_fp, key, tombstone}, _from, state) do
    with :ok <- verify_envelope(identikey_fp, tombstone) do
      path = record_path(identikey_fp, key)

      reply =
        case File.rm(path) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, _} = err -> err
        end

      # Remove reverse alias index entry when deleting an alias record.
      # Only the IdentiKey that currently holds the index entry can clear it
      # — prevents one IdentiKey from removing another's claim via tombstone.
      maybe_delete_alias_index(identikey_fp, key)

      {:reply, reply, state}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  ## Internals

  # Path for the reverse alias index file for a given fqdn. Always lowercased
  # so the index canonicalises hostnames (HTTP Host is case-insensitive).
  #
  # Validates fqdn shape before path construction — the fqdn flows in from
  # untrusted callers (HTTP Host header, URL path parameter, ?host= query)
  # so a raw `..` or `/` in the input would otherwise escape the
  # `_index/aliases/` directory.
  defp alias_index_path(fqdn) do
    Path.join([root(), "_index", "aliases", validate_fqdn!(fqdn)])
  end

  # RFC 1035 / 5890 compatible FQDN allowlist. Conservative: ASCII letters,
  # digits, hyphens, and dots. Total length capped at 253. Rejects
  # IDN/punycode-bypass attempts at this layer; callers needing Unicode
  # domains should punycode-encode before deposit.
  @fqdn_re ~r/^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$/

  defp validate_fqdn!(fqdn) when is_binary(fqdn) do
    lowered = String.downcase(fqdn)

    cond do
      byte_size(lowered) == 0 ->
        raise ArgumentError, "fqdn cannot be empty"

      byte_size(lowered) > 253 ->
        raise ArgumentError, "fqdn too long: #{inspect(fqdn)}"

      not String.match?(lowered, @fqdn_re) ->
        raise ArgumentError, "invalid fqdn: #{inspect(fqdn)}"

      true ->
        lowered
    end
  end

  # Write the reverse alias index entry for a key matching the alias pattern.
  # Key pattern: "sites/<site_name>/aliases/<fqdn>"
  #
  # Enforces two invariants:
  #
  # 1. **Cross-IdentiKey hijack prevention**: if `_index/aliases/<fqdn>` is
  #    currently owned by a different IdentiKey, refuse to overwrite. Returns
  #    `{:error, :alias_already_claimed}`. The record itself is still in the
  #    contender's keyspace (legitimate self-signed data), it just doesn't
  #    win the resolution race.
  # 2. **Same-IdentiKey monotonicity**: if the current owner is the same fp,
  #    use `AliasRecord.replaces?/2` to ignore sequence-regressions.
  defp maybe_write_alias_index(identikey_fp, key) do
    case Regex.run(~r{^sites/([^/]+)/aliases/([^/]+)$}, key) do
      [_, site_name, fqdn] ->
        do_write_alias_index(identikey_fp, site_name, fqdn)

      nil ->
        :ok
    end
  end

  # Atomic write of the alias index file with cross-IdentiKey + monotonic checks.
  defp do_write_alias_index(identikey_fp, site_name, fqdn) do
    index_path = alias_index_path(fqdn)

    case File.read(index_path) do
      {:ok, existing} ->
        case parse_alias_index(existing) do
          {existing_fp, _existing_site} when existing_fp != identikey_fp ->
            Logger.info(
              "SecretStore: refusing alias index overwrite for #{fqdn}: " <>
                "owned by #{existing_fp}, requester is #{identikey_fp}"
            )

            {:error, :alias_already_claimed}

          {^identikey_fp, _existing_site} ->
            # Same IdentiKey re-claim. Always allowed; sequence-monotonicity
            # is enforced at the HTTP layer via existing replaces?/2 paths.
            atomic_write_index(index_path, identikey_fp, site_name)

          :error ->
            # Existing index file is corrupt. Overwrite is safer than leaving
            # the alias dark.
            Logger.warning("SecretStore: alias index #{fqdn} unparseable, overwriting")
            atomic_write_index(index_path, identikey_fp, site_name)
        end

      {:error, :enoent} ->
        atomic_write_index(index_path, identikey_fp, site_name)

      {:error, reason} ->
        Logger.error("SecretStore: alias index read failed for #{fqdn}: #{inspect(reason)}")
        {:error, {:alias_index_read_failed, reason}}
    end
  end

  defp atomic_write_index(index_path, identikey_fp, site_name) do
    # JSON encoding so site_name can contain any safe char without breaking
    # the parser. The earlier colon-delimited format was fragile.
    contents = Jason.encode!(%{"fp" => identikey_fp, "site" => site_name})
    tmp = index_path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(index_path)),
         :ok <- File.write(tmp, contents),
         :ok <- File.rename(tmp, index_path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        Logger.error("SecretStore: alias index write failed: #{inspect(reason)}")
        {:error, {:alias_index_write_failed, reason}}
    end
  end

  defp parse_alias_index(contents) do
    case Jason.decode(contents) do
      {:ok, %{"fp" => fp, "site" => site}} ->
        {fp, site}

      _ ->
        # Legacy colon-delimited fallback for any pre-existing index entries.
        case String.split(contents, ":", parts: 2) do
          [fp, site] -> {fp, site}
          _ -> :error
        end
    end
  end

  # Remove the reverse alias index entry — only if the requesting IdentiKey
  # currently owns the entry. Prevents cross-IdentiKey tombstone forgery.
  defp maybe_delete_alias_index(identikey_fp, key) do
    case Regex.run(~r{^sites/([^/]+)/aliases/([^/]+)$}, key) do
      [_, _site_name, fqdn] ->
        index_path = alias_index_path(fqdn)

        with {:ok, existing} <- File.read(index_path),
             {existing_fp, _site} <- parse_alias_index(existing),
             true <- existing_fp == identikey_fp do
          case File.rm(index_path) do
            :ok ->
              :ok

            {:error, :enoent} ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "SecretStore: failed to remove alias index for #{fqdn}: #{inspect(reason)}"
              )
          end
        else
          {:error, :enoent} -> :ok
          _ -> :ok
        end

      nil ->
        :ok
    end
  end

  # On init, scan all keyspaces for alias records and rebuild the index.
  # Defensive: logs warnings on bad records, does not crash.
  defp rebuild_alias_index do
    store_root = root()

    case File.ls(store_root) do
      {:ok, entries} ->
        Enum.each(entries, fn fp_dir ->
          # Skip the _index directory itself
          if fp_dir != "_index" do
            fp_root = Path.join(store_root, fp_dir)

            if File.dir?(fp_root) do
              rebuild_alias_index_for_fp(fp_dir, fp_root)
            end
          end
        end)

      {:error, _} ->
        :ok
    end
  end

  defp rebuild_alias_index_for_fp(fp, fp_root) do
    aliases_root = Path.join([fp_root, "sites"])

    case walk(aliases_root) do
      {:ok, paths} ->
        Enum.each(paths, fn path ->
          # Extract relative key from the fp root
          prefix_len = byte_size(fp_root) + 1
          key = binary_part(path, prefix_len, byte_size(path) - prefix_len)

          case Regex.run(~r{^sites/([^/]+)/aliases/([^/]+)$}, key) do
            [_, site_name, fqdn] ->
              # Validate by parsing the record
              case File.read(path) do
                {:ok, bytes} ->
                  case AliasRecord.parse(bytes) do
                    {:ok, _record} ->
                      # Use the same atomic-write + JSON path as runtime writes
                      _ = do_write_alias_index(fp, site_name, fqdn)

                    {:error, reason} ->
                      Logger.warning(
                        "SecretStore: skipping bad alias record at #{path}: #{inspect(reason)}"
                      )
                  end

                {:error, reason} ->
                  Logger.warning(
                    "SecretStore: could not read alias record at #{path}: #{inspect(reason)}"
                  )
              end

            nil ->
              :ok
          end
        end)

      :not_found ->
        :ok
    end
  end

  defp record_path(identikey_fp, key) do
    safe_key = validate_key!(key)
    Path.join([root(), validate_fp!(identikey_fp), safe_key])
  end

  defp opaque_path(kind, id, key) do
    Path.join([root(), "_opaque", kind, id, key])
  end

  defp validate_opaque_segment(seg) when is_binary(seg) and seg != "" do
    if String.contains?(seg, ["/", "\\", "\0"]) or seg in [".", ".."] or
         String.contains?(seg, "..") do
      {:error, :invalid_opaque_id}
    else
      :ok
    end
  end

  defp validate_opaque_segment(_), do: {:error, :invalid_opaque_id}

  defp validate_opaque_key(key) when is_binary(key) and key != "" do
    if String.contains?(key, ["/", "\\", "\0", ".."]) do
      {:error, :invalid_opaque_key}
    else
      :ok
    end
  end

  defp validate_opaque_key(_), do: {:error, :invalid_opaque_key}

  defp validate_fp!(fp) when is_binary(fp) do
    if String.match?(fp, ~r/^[A-Za-z0-9]+$/) do
      fp
    else
      raise ArgumentError, "invalid identikey fingerprint: #{inspect(fp)}"
    end
  end

  defp validate_key!(""), do: ""

  defp validate_key!(key) when is_binary(key) do
    if String.contains?(key, "..") or String.starts_with?(key, "/") do
      raise ArgumentError, "invalid key: #{inspect(key)}"
    else
      key
    end
  end

  defp write_atomic(identikey_fp, key, bytes) do
    final = record_path(identikey_fp, key)
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

  defp walk(root) do
    case File.ls(root) do
      {:ok, entries} ->
        files =
          entries
          |> Enum.flat_map(fn entry ->
            path = Path.join(root, entry)

            cond do
              File.regular?(path) ->
                [path]

              File.dir?(path) ->
                case walk(path) do
                  {:ok, sub} -> sub
                  :not_found -> []
                end

              true ->
                []
            end
          end)

        {:ok, files}

      {:error, :enoent} ->
        :not_found

      {:error, _} ->
        :not_found
    end
  end

  # ---------------------------------------------------------------------------
  # Signature verification
  # ---------------------------------------------------------------------------

  # Rejects trivially empty envelopes without parsing.
  defp verify_envelope(_identikey_fp, <<>>), do: {:error, :empty_envelope}

  defp verify_envelope(identikey_fp, bytes) when is_binary(bytes) do
    case Jason.decode(bytes) do
      {:error, _} ->
        {:error, :bad_envelope_json}

      {:ok, raw} ->
        cond do
          # Identity/pubkey bootstrap record: has "pubkey" field, no signature.
          # Self-authenticates by verifying the fingerprint of the embedded
          # public key matches the claimed identikey_fp.
          Map.has_key?(raw, "pubkey") and not Map.has_key?(raw, "signature") and
              not Map.has_key?(raw, "signatures") ->
            verify_identity_bootstrap(identikey_fp, raw)

          # Signed record: must have a signature (HEAD) or signatures (manifest).
          true ->
            verify_signed_record(identikey_fp, bytes, raw)
        end
    end
  end

  # Bootstrap: the "identity/pubkey" registration record self-authenticates.
  # The embedded pubkey, when fingerprinted, must equal the claimed fp.
  defp verify_identity_bootstrap(identikey_fp, raw) do
    with {:ok, pub_b64} <- Map.fetch(raw, "pubkey"),
         {:ok, pub} <- Base.decode64(pub_b64) do
      computed_fp = IdentiKey.fingerprint(pub)

      if computed_fp == identikey_fp do
        :ok
      else
        {:error, :fingerprint_mismatch}
      end
    else
      :error -> {:error, :missing_pubkey}
      {:error, _} = err -> err
    end
  end

  # Signed record: fetch the registered public key from storage, recompute the
  # canonical signing bytes (envelope with signature field cleared), and verify.
  defp verify_signed_record(identikey_fp, bytes, raw) do
    with {:ok, pub} <- fetch_registered_pubkey(identikey_fp),
         {:ok, sig} <- extract_signature(raw),
         {:ok, signing_bytes} <- canonical_bytes_without_sig(bytes, raw) do
      if IdentiKey.verify(pub, signing_bytes, sig) do
        :ok
      else
        {:error, :bad_signature}
      end
    end
  end

  # Look up the identity/pubkey record previously registered for this fp.
  defp fetch_registered_pubkey(identikey_fp) do
    case get(identikey_fp, "identity/pubkey") do
      :not_found ->
        {:error, :identity_not_registered}

      {:ok, identity_bytes} ->
        with {:ok, identity_raw} <- Jason.decode(identity_bytes),
             {:ok, pub_b64} <- Map.fetch(identity_raw, "pubkey"),
             {:ok, pub} <- Base.decode64(pub_b64) do
          {:ok, pub}
        else
          :error -> {:error, :bad_identity_record}
          {:error, _} = err -> err
        end
    end
  end

  # Extract the ED25519 signature leg from a JSON-decoded envelope.
  # HEAD/alias records use "signature"; manifests use "signatures".
  #
  # The field is a forward-compatible MultiSig object (`%{"ed25519" => b64}`)
  # but `Mjolnir.Sites.MultiSig.from_field/1` also accepts the legacy bare
  # base64-string shape so envelopes written before the struct landed still
  # verify.
  defp extract_signature(raw) do
    field =
      cond do
        Map.has_key?(raw, "signature") -> raw["signature"]
        Map.has_key?(raw, "signatures") -> raw["signatures"]
        true -> nil
      end

    case Mjolnir.Sites.MultiSig.from_field(field) do
      %Mjolnir.Sites.MultiSig{ed25519: sig} when is_binary(sig) -> {:ok, sig}
      _ -> {:error, :missing_signature}
    end
  end

  # Rebuild the canonical bytes that were signed: re-parse as the appropriate
  # struct and call canonical_signing_bytes/1 on it.
  defp canonical_bytes_without_sig(bytes, _raw) do
    cond do
      # Try HeadRecord first (has "snapshot_hash" field)
      head_record?(bytes) ->
        case HeadRecord.parse(bytes) do
          {:ok, r} -> {:ok, HeadRecord.canonical_signing_bytes(r)}
          {:error, _} = err -> err
        end

      # Try Manifest (has "entries" field)
      manifest?(bytes) ->
        case Manifest.parse(bytes) do
          {:ok, m} -> {:ok, Manifest.canonical_signing_bytes(m)}
          {:error, _} = err -> err
        end

      # Try AliasRecord (has "fqdn" field)
      alias_record?(bytes) ->
        case AliasRecord.parse(bytes) do
          {:ok, r} -> {:ok, AliasRecord.canonical_signing_bytes(r)}
          {:error, _} = err -> err
        end

      true ->
        {:error, :unrecognized_envelope_type}
    end
  end

  defp head_record?(bytes) do
    case Jason.decode(bytes) do
      {:ok, raw} -> Map.has_key?(raw, "snapshot_hash")
      _ -> false
    end
  end

  defp manifest?(bytes) do
    case Jason.decode(bytes) do
      {:ok, raw} -> Map.has_key?(raw, "entries")
      _ -> false
    end
  end

  defp alias_record?(bytes) do
    case Jason.decode(bytes) do
      {:ok, raw} -> Map.has_key?(raw, "fqdn")
      _ -> false
    end
  end
end
