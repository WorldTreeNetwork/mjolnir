defmodule Mjolnir.Mailbox do
  @moduledoc """
  Per-actor durable message spool (ADR 0006).

  Accept is a fsynced JSON file at `{btrfs_root}/@mail/<vm_id>/<message_id>.json`.
  The filename is identity. Vsock ACK never deletes a file; application ACK
  tombstones it under `acked/`. Give-up moves it to `bounced/`.

  The VM GenServer is the single delivery consumer while the VM is in
  VMRegistry. When it is not, `kick/1` restores a dormant VM if unacked
  mail exists. Attempt counts live in the file body, not the VM struct.
  """

  use GenServer
  require Logger

  @max_id_bytes 128
  @valid_id ~r/^[A-Za-z0-9._-]+$/

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @type accept_result :: %{message_id: String.t(), status: :queued | :duplicate}

  @spec accept(String.t(), String.t(), term(), keyword()) ::
          {:ok, accept_result()} | {:error, term()}
  def accept(vm_id, from_vm_id, payload, opts \\ []) do
    GenServer.call(__MODULE__, {:accept, vm_id, from_vm_id, payload, opts})
  end

  @spec ack(String.t(), String.t()) :: :ok | {:error, term()}
  def ack(vm_id, message_id) do
    GenServer.call(__MODULE__, {:ack, vm_id, message_id})
  end

  @spec list_unacked(String.t()) :: [map()]
  def list_unacked(vm_id) do
    vm_id
    |> vm_dir()
    |> list_json_files()
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(&{&1["seq"] || 0, &1["accepted_at"] || "", &1["message_id"] || ""})
  end

  @spec unacked_count(String.t()) :: non_neg_integer()
  def unacked_count(vm_id), do: length(list_unacked(vm_id))

  @doc """
  Ask the delivery consumer to try vsock (if the VM is up) or restore
  (if it is dormant). Safe to call after accept; does not block accept.
  """
  @spec kick(String.t()) :: :ok
  def kick(vm_id) do
    GenServer.cast(__MODULE__, {:kick, vm_id})
    :ok
  end

  @doc "Move remaining unacked mail to bounced/. Used on VM kill."
  @spec drop_mailbox(String.t()) :: :ok
  def drop_mailbox(vm_id) do
    GenServer.call(__MODULE__, {:drop, vm_id})
  end

  @doc """
  Startup / periodic sweep: expire tombstones, bounce give-up, kick live
  mailboxes, bounce orphans (VM gone from registry, dormant, and StateStore).
  """
  @spec sweep() :: :ok
  def sweep do
    GenServer.call(__MODULE__, :sweep, 30_000)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:accept, vm_id, from_vm_id, payload, opts}, _from, state) do
    {:reply, do_accept(vm_id, from_vm_id, payload, opts), state}
  end

  def handle_call({:ack, vm_id, message_id}, _from, state) do
    {:reply, do_ack(vm_id, message_id), state}
  end

  def handle_call({:drop, vm_id}, _from, state) do
    {:reply, do_drop(vm_id), state}
  end

  def handle_call(:sweep, _from, state) do
    {:reply, do_sweep(), state}
  end

  def handle_call({:record_attempt, vm_id, message_id}, _from, state) do
    {:reply, do_record_attempt(vm_id, message_id), state}
  end

  @impl true
  def handle_cast({:kick, vm_id}, state) do
    bounce_expired(vm_id)
    spawn(fn -> kick_consumer(vm_id) end)
    {:noreply, state}
  end

  @spec record_attempt(String.t(), String.t()) :: :ok | :bounced | {:error, term()}
  def record_attempt(vm_id, message_id) do
    GenServer.call(__MODULE__, {:record_attempt, vm_id, message_id})
  end

  defp do_accept(vm_id, from_vm_id, payload, opts) do
    with {:ok, message_id} <- resolve_id(opts) do
      cond do
        known?(vm_id, message_id) ->
          {:ok, %{message_id: message_id, status: :duplicate}}

        true ->
          write_new(vm_id, from_vm_id, payload, message_id)
      end
    end
  end

  defp resolve_id(opts) do
    case Keyword.get(opts, :id) do
      nil ->
        {:ok, UUID.uuid4()}

      id when is_binary(id) ->
        if valid_id?(id), do: {:ok, id}, else: {:error, :invalid_message_id}

      _ ->
        {:error, :invalid_message_id}
    end
  end

  defp valid_id?(id) do
    byte_size(id) > 0 and byte_size(id) <= @max_id_bytes and id =~ @valid_id
  end

  defp known?(vm_id, message_id) do
    File.exists?(live_path(vm_id, message_id)) or
      File.exists?(acked_path(vm_id, message_id)) or
      File.exists?(bounced_path(vm_id, message_id))
  end

  defp write_new(vm_id, from_vm_id, payload, message_id) do
    dir = vm_dir(vm_id)
    File.mkdir_p!(dir)
    seq = next_seq(dir)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    record = %{
      "message_id" => message_id,
      "from_vm_id" => from_vm_id,
      "payload" => payload,
      "accepted_at" => now,
      "seq" => seq,
      "attempts" => 0,
      "last_attempt_at" => nil
    }

    tmp = live_path(vm_id, message_id) <> ".tmp"
    final = live_path(vm_id, message_id)
    json = Jason.encode!(record)

    with {:ok, io} <- :file.open(tmp, [:raw, :write, :binary]),
         :ok <- :file.write(io, json),
         :ok <- :file.sync(io),
         :ok <- :file.close(io),
         :ok <- exclusive_link(tmp, final),
         :ok <- fsync_dir(dir) do
      _ = File.rm(tmp)
      {:ok, %{message_id: message_id, status: :queued}}
    else
      {:error, :eexist} ->
        _ = File.rm(tmp)
        {:ok, %{message_id: message_id, status: :duplicate}}

      {:error, reason} ->
        _ = File.rm(tmp)
        Logger.warning("Mailbox accept failed for #{vm_id}/#{message_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp exclusive_link(tmp, final) do
    case :file.make_link(String.to_charlist(tmp), String.to_charlist(final)) do
      :ok -> :ok
      {:error, :eexist} -> {:error, :eexist}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fsync_dir(dir) do
    chars = String.to_charlist(dir)

    case open_dir(chars) do
      {:ok, io} ->
        result = :file.sync(io)
        :file.close(io)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp open_dir(chars) do
    case :file.open(chars, [:raw, :read]) do
      {:ok, io} ->
        {:ok, io}

      {:error, :eisdir} ->
        :file.open(chars, [:raw, :read, :directory])

      other ->
        other
    end
  end

  defp next_seq(dir) do
    dir
    |> list_json_files()
    |> Enum.map(fn {_, rec} -> rec["seq"] || 0 end)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp do_ack(vm_id, message_id) do
    src = live_path(vm_id, message_id)

    if File.exists?(src) do
      dest_dir = Path.join(vm_dir(vm_id), "acked")
      File.mkdir_p!(dest_dir)
      dest = Path.join(dest_dir, message_id <> ".json")
      tombstone = stamp_file(src, "acked_at")

      with :ok <- atomic_write(dest, dest_dir, tombstone),
           :ok <- File.rm(src),
           :ok <- fsync_dir(vm_dir(vm_id)) do
        :ok
      end
    else
      if File.exists?(acked_path(vm_id, message_id)), do: :ok, else: {:error, :not_found}
    end
  end

  defp do_record_attempt(vm_id, message_id) do
    path = live_path(vm_id, message_id)

    case read_json(path) do
      {:ok, rec} ->
        attempts = (rec["attempts"] || 0) + 1

        rec =
          Map.merge(rec, %{
            "attempts" => attempts,
            "last_attempt_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          })

        cond do
          give_up?(rec) ->
            bounce_record(vm_id, message_id, rec, "give_up")
            :bounced

          true ->
            atomic_write(path, vm_dir(vm_id), rec)
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_drop(vm_id) do
    for rec <- list_unacked(vm_id) do
      bounce_record(vm_id, rec["message_id"], rec, "vm_deleted")
    end

    :ok
  end

  defp do_sweep do
    root = root()

    case File.ls(root) do
      {:ok, vm_ids} ->
        Enum.each(vm_ids, &sweep_vm/1)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("Mailbox sweep could not list #{root}: #{inspect(reason)}")
        :ok
    end

    :ok
  end

  defp sweep_vm(vm_id) do
    expire_tombstones(vm_id)
    bounce_expired(vm_id)

    unacked = list_unacked(vm_id)

    cond do
      unacked == [] ->
        :ok

      vm_present?(vm_id) ->
        spawn(fn -> kick_consumer(vm_id) end)

      true ->
        Logger.info("Mailbox bouncing orphan mailbox for deleted VM #{vm_id}")
        do_drop(vm_id)
    end
  end

  defp vm_present?(vm_id) do
    Registry.lookup(Mjolnir.VMRegistry, vm_id) != [] or
      match?({:ok, _}, Mjolnir.DormantRegistry.lookup(vm_id)) or
      match?({:ok, _}, Mjolnir.StateStore.get(vm_id))
  end

  defp bounce_expired(vm_id) do
    for rec <- list_unacked(vm_id), give_up?(rec) do
      bounce_record(vm_id, rec["message_id"], rec, "give_up")
    end
  end

  defp expire_tombstones(vm_id) do
    retention = tombstone_seconds()
    now = DateTime.utc_now()

    for {path, rec} <-
          list_json_files(Path.join(vm_dir(vm_id), "acked")) ++
            list_json_files(Path.join(vm_dir(vm_id), "bounced")) do
      stamped = rec["acked_at"] || rec["bounced_at"] || rec["accepted_at"]

      case stamped do
        bin when is_binary(bin) ->
          case DateTime.from_iso8601(bin) do
            {:ok, dt, _} ->
              if DateTime.diff(now, dt, :second) > retention, do: File.rm(path)

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    end
  end

  defp bounce_record(vm_id, message_id, rec, reason) do
    dest_dir = Path.join(vm_dir(vm_id), "bounced")
    File.mkdir_p!(dest_dir)
    dest = Path.join(dest_dir, message_id <> ".json")

    rec =
      rec
      |> Map.put("bounced_at", DateTime.utc_now() |> DateTime.to_iso8601())
      |> Map.put("bounce_reason", reason)

    src = live_path(vm_id, message_id)
    _ = atomic_write(dest, dest_dir, rec)
    _ = File.rm(src)
    _ = fsync_dir(vm_dir(vm_id))
    :ok
  end

  defp give_up?(rec) do
    max_attempts = Application.get_env(:mjolnir, :mailbox_max_attempts, 10)
    ttl_ms = Application.get_env(:mjolnir, :mailbox_ttl_ms, 86_400_000)
    attempts = rec["attempts"] || 0

    expired =
      case rec["accepted_at"] do
        stamp when is_binary(stamp) ->
          case DateTime.from_iso8601(stamp) do
            {:ok, dt, _} -> DateTime.diff(DateTime.utc_now(), dt, :millisecond) >= ttl_ms
            _ -> false
          end

        _ ->
          false
      end

    attempts >= max_attempts or expired
  end

  defp kick_consumer(vm_id) do
    case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
      [{pid, _}] ->
        GenServer.cast(pid, :deliver_mailbox)

      [] ->
        case Mjolnir.DormantRegistry.lookup(vm_id) do
          {:ok, %{state: :dormant}} ->
            if list_unacked(vm_id) != [] do
              Mjolnir.VM.restore_for_mail(vm_id)
            end

          _ ->
            :ok
        end
    end
  end

  defp stamp_file(path, field) do
    case read_json(path) do
      {:ok, rec} ->
        Map.put(rec, field, DateTime.utc_now() |> DateTime.to_iso8601())

      _ ->
        %{field => DateTime.utc_now() |> DateTime.to_iso8601()}
    end
  end

  defp atomic_write(path, dir, record) do
    File.mkdir_p!(dir)
    tmp = path <> ".tmp"
    json = Jason.encode!(record)

    with {:ok, io} <- :file.open(tmp, [:raw, :write, :binary]),
         :ok <- :file.write(io, json),
         :ok <- :file.sync(io),
         :ok <- :file.close(io),
         :ok <- File.rename(tmp, path),
         :ok <- fsync_dir(dir) do
      :ok
    else
      error ->
        _ = File.rm(tmp)
        error
    end
  end

  defp list_json_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.reject(&String.ends_with?(&1, ".tmp"))
        |> Enum.flat_map(fn name ->
          path = Path.join(dir, name)

          case read_json(path) do
            {:ok, rec} -> [{path, rec}]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp read_json(path) do
    case File.read(path) do
      {:ok, bin} ->
        case Jason.decode(bin) do
          {:ok, rec} when is_map(rec) -> {:ok, rec}
          _ -> {:error, :invalid_json}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp root do
    Path.join(Application.get_env(:mjolnir, :btrfs_root, "/var/lib/mjolnir/btrfs"), "@mail")
  end

  defp vm_dir(vm_id), do: Path.join(root(), vm_id)
  defp live_path(vm_id, id), do: Path.join(vm_dir(vm_id), id <> ".json")
  defp acked_path(vm_id, id), do: Path.join([vm_dir(vm_id), "acked", id <> ".json"])
  defp bounced_path(vm_id, id), do: Path.join([vm_dir(vm_id), "bounced", id <> ".json"])

  defp tombstone_seconds do
    Application.get_env(:mjolnir, :mailbox_tombstone_seconds, 7 * 24 * 60 * 60)
  end
end
