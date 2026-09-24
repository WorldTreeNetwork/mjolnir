defmodule Mjolnir.VmId.Migrate do
  @moduledoc """
  Rewrite dashed-UUID VM ids to base58btc on disk.

  Runs before StateStore reads its directory. One VM at a time, and safe to
  run again: a record already in base58 is left alone. The vsock CID is
  stamped from the old string first, because `Mjolnir.Vsock.cid/1` hashes
  that string and a later resume must not recompute it from the new spelling.

  Paths renamed, when they exist: the state file, `@vms/<id>`, the escrow
  file, `@mail/<id>`. Snapshot sidecars and the dormant registry have their
  `source_vm_id` / vm id fields rewritten. A destination that already exists
  is not overwritten; the old state file is kept so the next boot tries again.
  """

  require Logger

  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    state_dir = Keyword.get(opts, :state_dir, Application.get_env(:mjolnir, :state_dir))

    if is_binary(state_dir) and File.dir?(state_dir) do
      state_dir
      |> File.ls!()
      |> Enum.filter(&uuid_state_file?/1)
      |> Enum.each(&migrate_state(state_dir, &1, opts))
    end

    rewrite_sidecars(opts)
    rewrite_dormant(opts)
    :ok
  end

  defp uuid_state_file?(name) do
    String.ends_with?(name, ".json") and
      Mjolnir.VmId.legacy_uuid?(String.trim_trailing(name, ".json"))
  end

  defp migrate_state(state_dir, filename, opts) do
    old = String.trim_trailing(filename, ".json")
    canonical = Mjolnir.VmId.storage_id(old)
    src = Path.join(state_dir, filename)
    dest = Path.join(state_dir, canonical <> ".json")

    with {:ok, bin} <- File.read(src),
         {:ok, map} <- Jason.decode(bin),
         true <- is_map(map) do
      map = stamp_cid(map, old)
      map = Map.put(map, "uuid", canonical)

      cond do
        File.exists?(dest) and src != dest ->
          Logger.error("VmId migrate #{old} -> #{canonical} skipped: #{dest} already exists")

        true ->
          case write_json(dest, map) do
            :ok ->
              unless rename_tree(old, canonical, opts) do
                Logger.error(
                  "VmId migrate #{old} -> #{canonical} left the state file; paths busy"
                )
              else
                if src != dest, do: File.rm(src)
                Logger.info("VmId migrate #{old} -> #{canonical}")
              end

            {:error, reason} ->
              Logger.error("VmId migrate #{old} failed to write state: #{inspect(reason)}")
          end
      end
    else
      _ -> Logger.error("VmId migrate skipped unreadable #{src}")
    end
  end

  defp stamp_cid(map, old) do
    config = Map.get(map, "spawn_config") || %{}

    config =
      if is_integer(config["vsock_cid"]) do
        config
      else
        Map.put(config, "vsock_cid", Mjolnir.Vsock.cid(old))
      end

    Map.put(map, "spawn_config", config)
  end

  # false when a destination is already occupied by something else.
  defp rename_tree(old, canonical, opts) do
    btrfs = Keyword.get(opts, :btrfs_root, Application.get_env(:mjolnir, :btrfs_root))
    escrow = Keyword.get(opts, :escrow_dir, Application.get_env(:mjolnir, :secret_escrow_dir))

    dirs =
      if is_binary(btrfs) do
        [
          Path.join([btrfs, "@vms", old]),
          Path.join([btrfs, "@mail", old])
        ]
      else
        []
      end

    files = if is_binary(escrow), do: [Path.join(escrow, old)], else: []

    Enum.all?(dirs ++ files, &rename_one(&1, old, canonical))
  end

  defp rename_one(src, old, canonical) do
    dest = String.replace_suffix(src, old, canonical)

    cond do
      src == dest -> true
      not File.exists?(src) -> true
      File.exists?(dest) -> false
      true -> match?(:ok, File.rename(src, dest))
    end
  end

  defp rewrite_sidecars(opts) do
    btrfs = Keyword.get(opts, :btrfs_root, Application.get_env(:mjolnir, :btrfs_root))
    dir = if is_binary(btrfs), do: Path.join(btrfs, "@snapshots"), else: nil

    if is_binary(dir) and File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.each(&rewrite_source_vm(Path.join(dir, &1)))
    end
  end

  defp rewrite_source_vm(path) do
    with {:ok, bin} <- File.read(path),
         {:ok, map} <- Jason.decode(bin),
         true <- is_map(map),
         old when is_binary(old) <- map["source_vm_id"],
         true <- Mjolnir.VmId.legacy_uuid?(old) do
      canonical = Mjolnir.VmId.storage_id(old)
      write_json(path, Map.put(map, "source_vm_id", canonical))
    else
      _ -> :ok
    end
  end

  defp rewrite_dormant(opts) do
    btrfs = Keyword.get(opts, :btrfs_root, Application.get_env(:mjolnir, :btrfs_root))
    path = if is_binary(btrfs), do: Path.join([btrfs, "@dormant", "registry.json"]), else: nil

    with true <- is_binary(path),
         true <- File.regular?(path),
         {:ok, bin} <- File.read(path),
         {:ok, data} <- Jason.decode(bin),
         true <- is_map(data) do
      rewritten =
        Map.new(data, fn {vm_id, raw} ->
          id = Mjolnir.VmId.storage_id(vm_id)

          raw =
            if is_map(raw) do
              raw
              |> Map.put("vm_id", id)
              |> rewrite_messages()
            else
              raw
            end

          {id, raw}
        end)

      if rewritten != data, do: write_json(path, rewritten), else: :ok
    else
      _ -> :ok
    end
  end

  defp rewrite_messages(raw) do
    case raw["pending_messages"] do
      list when is_list(list) ->
        Map.put(
          raw,
          "pending_messages",
          Enum.map(list, fn
            %{"from_vm_id" => from} = msg when is_binary(from) ->
              Map.put(msg, "from_vm_id", Mjolnir.VmId.storage_id(from))

            other ->
              other
          end)
        )

      _ ->
        raw
    end
  end

  defp write_json(path, map) do
    tmp = path <> ".tmp"
    bin = Jason.encode!(map, pretty: true)

    with :ok <- File.write(tmp, bin),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, _} = err ->
        _ = File.rm(tmp)
        err
    end
  end
end
