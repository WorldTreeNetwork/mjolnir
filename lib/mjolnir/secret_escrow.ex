defmodule Mjolnir.SecretEscrow do
  @moduledoc """
  Per-VM LUKS passphrase escrow for `secrets_mode: :managed`.

  The host generates a random passphrase per VM, stores it here, and re-injects
  it over vsock on every boot — including dormancy wake — so a managed VM can
  scale to zero and be auto-unlocked without a human in the loop.

  ## Security posture

  This is deliberately **not** zero-knowledge: the host can read the passphrase,
  so `:managed` does not survive host compromise (an accepted trade for autonomous
  dormancy; see `docs/secrets-architecture.md` → "Managed Mode"). What it *does*
  preserve:

    * The escrow dir lives **outside `btrfs_root`** (the data volume), so it is
      never inside `@vms/<uuid>` and never captured by `btrfs subvolume snapshot`.
      A leaked or offsite-synced snapshot contains only the ciphertext LUKS blob.
    * Each VM gets an independent random passphrase (per-VM blast radius).

  Only the **passphrase** is escrowed — never the secret material. The `.env`
  content lives inside the (snapshotted, ciphertext) LUKS volume, so waking a
  dormant VM is just re-opening an already-present volume.

  ## Layout

      <secret_escrow_dir>/
      `-- <vm_id>            # base64url passphrase, mode 0600

  Writes are atomic (tmp + rename). The directory is created mode 0700.
  """

  require Logger

  @passphrase_bytes 32

  @typedoc "A VM UUID — must be a path-safe identifier (no separators)."
  @type vm_id :: String.t()

  @doc "Generate a fresh random passphrase (256 bits, base64url, unpadded)."
  @spec gen_passphrase() :: String.t()
  def gen_passphrase do
    :crypto.strong_rand_bytes(@passphrase_bytes)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Store `passphrase` for `vm_id`, overwriting any existing entry. Atomic.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec put(vm_id(), String.t()) :: :ok | {:error, term()}
  def put(vm_id, passphrase) when is_binary(passphrase) do
    vm_id = Mjolnir.VmId.storage_id(vm_id)

    with :ok <- validate_id(vm_id),
         dir = dir(),
         :ok <- File.mkdir_p(dir),
         _ = File.chmod(dir, 0o700),
         path = Path.join(dir, vm_id),
         tmp = path <> ".tmp",
         :ok <- File.write(tmp, passphrase),
         _ = File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path),
         _ = File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} = err ->
        Logger.error("SecretEscrow.put failed for #{inspect(vm_id)}: #{inspect(reason)}")
        err
    end
  end

  @doc """
  Read the escrowed passphrase for `vm_id`. Returns `{:ok, passphrase}`,
  `:not_found`, or `{:error, reason}`.
  """
  @spec get(vm_id()) :: {:ok, String.t()} | :not_found | {:error, term()}
  def get(vm_id) do
    vm_id = Mjolnir.VmId.storage_id(vm_id)

    with :ok <- validate_id(vm_id),
         path = Path.join(dir(), vm_id) do
      case File.read(path) do
        {:ok, passphrase} -> {:ok, passphrase}
        {:error, :enoent} -> :not_found
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Return the existing passphrase, or generate+store a new one. Returns
  `{:ok, passphrase, :existing | :created}` so callers can decide whether to
  *create* (first boot) or *open* (wake) the LUKS volume.
  """
  @spec get_or_create(vm_id()) ::
          {:ok, String.t(), :existing | :created} | {:error, term()}
  def get_or_create(vm_id) do
    case get(vm_id) do
      {:ok, passphrase} ->
        {:ok, passphrase, :existing}

      :not_found ->
        passphrase = gen_passphrase()

        case put(vm_id, passphrase) do
          :ok -> {:ok, passphrase, :created}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Delete the escrow entry for `vm_id`. Idempotent — missing is `:ok`."
  @spec delete(vm_id()) :: :ok | {:error, term()}
  def delete(vm_id) do
    vm_id = Mjolnir.VmId.storage_id(vm_id)

    with :ok <- validate_id(vm_id),
         path = Path.join(dir(), vm_id) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "True if an escrow entry exists for `vm_id`."
  @spec exists?(vm_id()) :: boolean()
  def exists?(vm_id) do
    vm_id = Mjolnir.VmId.storage_id(vm_id)

    case validate_id(vm_id) do
      :ok -> File.exists?(Path.join(dir(), vm_id))
      _ -> false
    end
  end

  defp dir do
    Application.get_env(:mjolnir, :secret_escrow_dir, "/var/lib/mjolnir/escrow")
  end

  # vm_id becomes a filename — reject anything with path separators, traversal,
  # or that is empty, so a crafted id can't escape the escrow dir.
  defp validate_id(id) when is_binary(id) and id != "" do
    if String.contains?(id, ["/", "\\", "\0"]) or id in [".", ".."] do
      {:error, :invalid_vm_id}
    else
      :ok
    end
  end

  defp validate_id(_), do: {:error, :invalid_vm_id}
end
