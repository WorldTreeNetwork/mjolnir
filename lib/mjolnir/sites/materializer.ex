defmodule Mjolnir.Sites.Materializer do
  @moduledoc """
  Materialize a published snapshot into a plaintext directory tree so a static
  file server (the Rust gateway's `ServeDir`) can serve it with zero per-request
  crypto.

  See `docs/plans/initiatives/identikey-sites.md` §6.1 — this is the fast path
  that replaces `Mjolnir.Sites.Server.serve/3` for materialized sites. `serve/3`
  stays as the fallback for sites published before this feature (or when
  materialization failed).

  ## Directory layout

      <materialized_root>/<identikey_fp>/<site_name>/snapshots/<snapshot_hash>/…
      <materialized_root>/<identikey_fp>/<site_name>/current      → snapshots/<snapshot_hash>

  Manifest entry paths carry a leading `/`, so `/index.html` lands at
  `<snapshot_dir>/index.html`. `current` is a *relative* symlink so the tree
  survives being moved or bind-mounted somewhere else.

  ## Derived cache

  Nothing here is authoritative. The signed manifest plus the content-addressed
  chunk store remain the source of truth; the whole tree can be deleted and
  rebuilt with `materialize/3` (or `mix mjolnir.sites.materialize`). That is
  what makes it safe to write plaintext to disk at publish time.

  ## Atomicity

  Files are written into `<site_dir>/.tmp/<rand>` and `:file.rename/2`-d into
  `snapshots/<hash>` in one step, so a half-written snapshot is never reachable.
  The `current` symlink is flipped the same way (write a new link under `.tmp`,
  rename it over `current`), so readers see either the old or the new snapshot
  and never a missing one.

  ## Path safety

  Manifest entry paths are attacker-controlled — a publisher can put anything in
  a manifest it signs. `safe_relative/1` rejects absolute escapes, `..`
  components and empty/dot segments before any file is opened. A bad entry is
  skipped, not fatal: one hostile path must not be able to take a whole site
  offline.

  A snapshot cannot contain a symlink: `Manifest.Entry` has no type or
  link-target field to express one, and this module writes regular files only.
  `Mjolnir.Sites.Publisher` walks source directories with `lstat` so a symlink
  in a build directory is skipped rather than dereferenced into the snapshot.

  ## Precompression

  Compressible entries above `@min_compress_size` get `.gz` (and `.br` when a
  brotli encoder is available) siblings written at publish time, so the gateway
  can serve `Content-Encoding` without compressing per request.
  """

  require Logger

  alias Mjolnir.SecretStore
  alias Mjolnir.Sites.{HeadRecord, Manifest, Server, Store}

  @default_retention 5
  @min_compress_size 1024

  # Extensions worth compressing. Everything else (already-compressed image and
  # font formats in particular) is written plain — a .gz of a .png is bigger
  # than the .png.
  @compressible_exts ~w(.html .htm .css .js .mjs .json .svg .xml .txt .wasm .map)

  @type identikey_fp :: String.t()
  @type site_name :: String.t()

  ## Paths

  @doc """
  Root of the materialized tree. Configured via `:sites_materialized_root`,
  defaulting to a `materialized/` sibling of the chunk store inside
  `:sites_root`.
  """
  @spec root() :: String.t()
  def root do
    Application.get_env(:mjolnir, :sites_materialized_root) ||
      Path.join(Store.root(), "materialized")
  end

  @doc "Directory holding one site's snapshots and its `current` symlink."
  @spec site_dir(identikey_fp(), site_name()) :: String.t()
  def site_dir(identikey_fp, site_name) do
    Path.join([root(), safe_segment!(identikey_fp), safe_segment!(site_name)])
  end

  @doc "Directory a single snapshot materializes into."
  @spec snapshot_dir(identikey_fp(), site_name(), String.t()) :: String.t()
  def snapshot_dir(identikey_fp, site_name, snapshot_hash) do
    Path.join([site_dir(identikey_fp, site_name), "snapshots", safe_segment!(snapshot_hash)])
  end

  @doc "The `current` symlink pointing at the live snapshot directory."
  @spec current_link(identikey_fp(), site_name()) :: String.t()
  def current_link(identikey_fp, site_name) do
    Path.join(site_dir(identikey_fp, site_name), "current")
  end

  @doc """
  Snapshot hash `current` points at, or `:not_found` when the site has never
  been materialized.
  """
  @spec current_snapshot(identikey_fp(), site_name()) :: {:ok, String.t()} | :not_found
  def current_snapshot(identikey_fp, site_name) do
    case File.read_link(current_link(identikey_fp, site_name)) do
      {:ok, target} -> {:ok, Path.basename(target)}
      {:error, _} -> :not_found
    end
  end

  ## Materialization

  @doc """
  Materialize the snapshot named by the site's current HEAD record.

  This is what the publish path calls after a HEAD update lands.
  """
  @spec materialize_head(identikey_fp(), site_name(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def materialize_head(identikey_fp, site_name, opts \\ []) do
    with {:ok, bytes} <- fetch_head(identikey_fp, site_name),
         {:ok, %HeadRecord{snapshot_hash: hash}} <- HeadRecord.parse(bytes) do
      materialize(identikey_fp, site_name, hash, opts)
    end
  end

  @doc """
  Materialize `snapshot_hash` and flip `current` to it.

  Returns `{:ok, snapshot_dir}`. Re-materializing a hash that is already on disk
  rebuilds it from the chunk store — the tree is a cache, so a rebuild is always
  legal and always produces the same bytes.

  Options:
    * `:retention` — how many snapshot directories to keep (default
      `:sites_snapshot_retention`, itself defaulting to #{@default_retention}).
    * `:prune` — set `false` to skip pruning entirely.
  """
  @spec materialize(identikey_fp(), site_name(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def materialize(identikey_fp, site_name, snapshot_hash, opts \\ []) do
    with {:ok, manifest} <- read_manifest(snapshot_hash),
         :ok <- check_manifest_matches(manifest, identikey_fp, site_name),
         {:ok, tmp} <- build_tree(manifest, identikey_fp, site_name, snapshot_hash),
         {:ok, dir} <- install_tree(tmp, identikey_fp, site_name, snapshot_hash),
         :ok <- flip_current(identikey_fp, site_name, snapshot_hash) do
      if Keyword.get(opts, :prune, true), do: prune(identikey_fp, site_name, opts)

      {:ok, dir}
    end
  end

  @doc """
  Delete all but the most recent `retention` snapshot directories, never
  touching the one `current` points at. Keeping old snapshots on disk is what
  makes a rollback a symlink flip rather than a re-publish.
  """
  @spec prune(identikey_fp(), site_name(), keyword()) :: :ok
  def prune(identikey_fp, site_name, opts \\ []) do
    retention = Keyword.get(opts, :retention, configured_retention())
    snapshots = Path.join(site_dir(identikey_fp, site_name), "snapshots")

    live =
      case current_snapshot(identikey_fp, site_name) do
        {:ok, hash} -> hash
        :not_found -> nil
      end

    case File.ls(snapshots) do
      {:ok, names} ->
        names
        |> Enum.reject(&(&1 == live))
        |> Enum.map(&{&1, mtime_of(Path.join(snapshots, &1))})
        |> Enum.sort_by(&elem(&1, 1), :desc)
        |> Enum.drop(max(retention - 1, 0))
        |> Enum.each(fn {name, _mtime} ->
          _ = File.rm_rf(Path.join(snapshots, name))
        end)

      {:error, _} ->
        :ok
    end

    :ok
  end

  ## Internals — read side

  defp fetch_head(identikey_fp, site_name) do
    case SecretStore.get(identikey_fp, "sites/#{site_name}/HEAD") do
      {:ok, bytes} -> {:ok, bytes}
      :not_found -> {:error, :no_head}
      err -> err
    end
  end

  defp read_manifest(snapshot_hash) do
    case Store.get_manifest(snapshot_hash) do
      {:ok, bytes} -> Manifest.parse(bytes)
      :not_found -> {:error, :no_manifest}
      err -> err
    end
  end

  defp check_manifest_matches(%Manifest{identikey_fp: fp, site_name: name}, fp, name), do: :ok
  defp check_manifest_matches(%Manifest{}, _fp, _name), do: {:error, :manifest_mismatch}

  ## Internals — write side

  # Decrypt every entry into a fresh temp directory. Entries whose path is not
  # safely relative are skipped loudly rather than failing the whole publish:
  # one hostile path should not be able to take a site offline.
  defp build_tree(manifest, identikey_fp, site_name, snapshot_hash) do
    tmp =
      Path.join([
        site_dir(identikey_fp, site_name),
        ".tmp",
        "#{snapshot_hash}-#{System.unique_integer([:positive])}"
      ])

    with :ok <- File.mkdir_p(tmp) do
      result =
        Enum.reduce_while(manifest.entries, :ok, fn entry, :ok ->
          case write_entry(manifest, entry, tmp) do
            :ok -> {:cont, :ok}
            {:skip, reason} -> skip_entry(entry, reason)
            {:error, _} = err -> {:halt, err}
          end
        end)

      case result do
        :ok ->
          {:ok, tmp}

        {:error, _} = err ->
          _ = File.rm_rf(tmp)
          err
      end
    end
  end

  defp skip_entry(entry, reason) do
    Logger.warning(
      "Sites.Materializer: skipping unsafe entry #{inspect(entry.path)} (#{inspect(reason)})"
    )

    {:cont, :ok}
  end

  defp write_entry(manifest, entry, tmp) do
    with {:ok, rel} <- safe_relative(entry.path),
         {:ok, chunk} <- fetch_chunk(entry.bao_hash),
         {:ok, plaintext} <-
           Server.decrypt_public(manifest, entry, chunk.ciphertext, chunk.outboard) do
      dest = Path.join(tmp, rel)

      with :ok <- File.mkdir_p(Path.dirname(dest)),
           :ok <- File.write(dest, plaintext) do
        precompress(dest, rel, plaintext)
        :ok
      end
    end
  end

  defp fetch_chunk(bao_hash) do
    case Store.get_chunk(bao_hash) do
      {:ok, _} = ok -> ok
      :not_found -> {:error, {:chunk_missing, bao_hash}}
      err -> err
    end
  end

  # Move the finished tree into place. A rename cannot clobber a non-empty
  # directory, so an existing materialization of the same hash is swapped out
  # first and deleted after — the window where neither exists is not observable
  # through `current`, which still points at whatever it pointed at before.
  defp install_tree(tmp, identikey_fp, site_name, snapshot_hash) do
    final = snapshot_dir(identikey_fp, site_name, snapshot_hash)
    stale = final <> ".stale-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(final)),
         :ok <- swap_aside(final, stale),
         :ok <- :file.rename(tmp, final) do
      _ = File.rm_rf(stale)
      {:ok, final}
    else
      error ->
        _ = File.rm_rf(tmp)
        _ = :file.rename(stale, final)
        {:error, {:install_failed, error}}
    end
  end

  defp swap_aside(final, stale) do
    if File.exists?(final), do: :file.rename(final, stale), else: :ok
  end

  # Write the new link under `.tmp` and rename it over `current`. `rename` onto
  # an existing symlink replaces it in one step, so a concurrent reader either
  # follows the old target or the new one.
  defp flip_current(identikey_fp, site_name, snapshot_hash) do
    dir = site_dir(identikey_fp, site_name)
    link = Path.join(dir, "current")
    tmp_link = Path.join([dir, ".tmp", "current-#{System.unique_integer([:positive])}"])
    target = Path.join("snapshots", snapshot_hash)

    with :ok <- File.mkdir_p(Path.dirname(tmp_link)),
         :ok <- File.ln_s(target, tmp_link),
         :ok <- :file.rename(tmp_link, link) do
      :ok
    else
      error ->
        _ = File.rm(tmp_link)
        {:error, {:symlink_failed, error}}
    end
  end

  ## Precompression

  defp precompress(dest, rel, plaintext) do
    if compressible?(rel, plaintext) do
      _ = File.write(dest <> ".gz", :zlib.gzip(plaintext))

      case brotli(plaintext) do
        {:ok, br} -> File.write(dest <> ".br", br)
        :unavailable -> :ok
      end
    end

    :ok
  end

  defp compressible?(rel, plaintext) do
    byte_size(plaintext) >= @min_compress_size and
      String.downcase(Path.extname(rel)) in @compressible_exts
  end

  # Brotli is a NIF (`:brotli`). It is a hard dep, but the guard keeps a host
  # where the .so failed to load serving gzip instead of crashing every publish.
  # The gateway must tolerate a missing `.br` regardless — tiny and
  # incompressible files never get one.
  defp brotli(plaintext) do
    if Code.ensure_loaded?(:brotli) and function_exported?(:brotli, :encode, 1) do
      case :brotli.encode(plaintext) do
        {:ok, encoded} -> {:ok, encoded}
        _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  ## Path safety

  # Turn a manifest entry path into a relative path guaranteed to stay inside
  # the snapshot directory, or reject it. Entry paths are attacker-controlled.
  @doc false
  @spec safe_relative(String.t()) :: {:ok, String.t()} | {:skip, atom()}
  def safe_relative(path) when is_binary(path) do
    cond do
      not String.starts_with?(path, "/") -> {:skip, :not_absolute}
      String.contains?(path, <<0>>) -> {:skip, :null_byte}
      true -> validate_segments(String.split(path, "/", trim: true))
    end
  end

  def safe_relative(_), do: {:skip, :not_a_string}

  defp validate_segments([]), do: {:skip, :empty_path}

  defp validate_segments(segments) do
    if Enum.any?(segments, &(&1 in [".", ".."] or &1 == "" or String.contains?(&1, "\\"))) do
      {:skip, :traversal}
    else
      {:ok, Path.join(segments)}
    end
  end

  # Fingerprints, site names and snapshot hashes all become path segments, so
  # they get the same treatment — but a bad one here is a bug in the caller, not
  # attacker input that should be tolerated, so it raises.
  defp safe_segment!(segment) when is_binary(segment) do
    if segment != "" and segment not in [".", ".."] and
         not String.contains?(segment, "/") and not String.contains?(segment, <<0>>) do
      segment
    else
      raise ArgumentError, "unsafe path segment: #{inspect(segment)}"
    end
  end

  ## Misc

  defp configured_retention do
    Application.get_env(:mjolnir, :sites_snapshot_retention, @default_retention)
  end

  defp mtime_of(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      {:error, _} -> 0
    end
  end
end
