defmodule Mjolnir.Entropy.Probe do
  @moduledoc """
  Concurrent two-thaw key probe for `mjolnir-3y6.5`.

  Restoring one memory snapshot twice yields identical CRNG state. The
  original acceptance criterion — "two VMs restored from the same snapshot
  produce different keys" — could not be run: a second thaw collided on the
  virtiofsd socket and vsock CID baked into `config.json`.

  This module is the harness that makes the criterion runnable:

  1. Thaw the same snapshot onto two new identities (`thaw/3` with
     `remap: true`) so sockets and CIDs do not collide.
  2. Optionally reseed each guest (`Mjolnir.Entropy.reseed/2`).
  3. Sample `/dev/urandom` over vsock from each.
  4. Report whether the samples diverged.

  Guest network identity is **not** remapped (MAC stays; TAP name changes).
  Exec goes over vsock, which is enough. Full fork (net_fds, guest
  re-identity) remains `mjolnir-8m3`.

  Every host-side step is injectable so the control flow is unit-testable
  without KVM. The default functions talk to a real snapshot.
  """

  require Logger

  alias Mjolnir.Entropy
  alias Mjolnir.MemorySnapshot
  alias Mjolnir.Vsock.Connection

  @default_bytes 16
  @default_connect_timeout_ms 30_000

  @doc """
  Thaw `name` twice, sample each guest's CRNG, compare.

  ## Options

    - `:reseed` — run `Entropy.reseed/2` on both before sampling (default
      `true`). Pass `false` for the control: cloned CRNG, keys should match
      unless virtio-rng has already mixed in new host entropy.
    - `:bytes` — sample length (default #{@default_bytes})
    - `:id_a` / `:id_b` — thaw identities (default fresh UUIDs)
    - `:thaw_opts` — extra opts forwarded to `MemorySnapshot.thaw/3`
      (`remap: true` is always set)
    - `:thaw`, `:connect`, `:reseed_fun`, `:sample`, `:teardown` —
      injectable steps for tests

  Returns `{:ok, %{key_a, key_b, diverged, reseeded, vm_a, vm_b}}`.
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(name, opts \\ []) do
    reseed? = Keyword.get(opts, :reseed, true)
    bytes = Keyword.get(opts, :bytes, @default_bytes)
    id_a = Keyword.get_lazy(opts, :id_a, &UUID.uuid4/0)
    id_b = Keyword.get_lazy(opts, :id_b, &UUID.uuid4/0)
    thaw_opts = Keyword.merge(Keyword.get(opts, :thaw_opts, []), remap: true)

    case boot(name, id_a, thaw_opts, opts) do
      {:ok, a} ->
        case boot(name, id_b, thaw_opts, opts) do
          {:ok, b} ->
            result = probe_pair(a, b, reseed?, bytes, opts)
            teardown_boot(a, opts)
            teardown_boot(b, opts)
            result

          {:error, reason} ->
            teardown_boot(a, opts)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp probe_pair(a, b, reseed?, bytes, opts) do
    reseed_fun = Keyword.get(opts, :reseed_fun, &Entropy.reseed/1)
    sample_fun = Keyword.get(opts, :sample, &sample_urandom/2)

    with :ok <- maybe_reseed(a, b, reseed?, reseed_fun),
         {:ok, ka} <- sample_fun.(a.conn, bytes),
         {:ok, kb} <- sample_fun.(b.conn, bytes) do
      {:ok,
       %{
         key_a: ka,
         key_b: kb,
         diverged: ka != kb,
         reseeded: reseed?,
         vm_a: a.vm_id,
         vm_b: b.vm_id
       }}
    end
  end

  defp maybe_reseed(_a, _b, false, _fun), do: :ok

  defp maybe_reseed(a, b, true, fun) do
    with :ok <- fun.(a.conn),
         :ok <- fun.(b.conn) do
      :ok
    end
  end

  defp boot(name, id, thaw_opts, opts) do
    thaw_fun = Keyword.get(opts, :thaw, &MemorySnapshot.thaw/3)
    connect_fun = Keyword.get(opts, :connect, &connect_vsock/2)

    case thaw_fun.(name, id, thaw_opts) do
      {:ok, thawed} ->
        case connect_fun.(thawed, opts) do
          {:ok, conn} ->
            {:ok, Map.put(thawed, :conn, conn)}

          {:error, reason} ->
            teardown_boot(thawed, opts)
            {:error, {:vsock_connect_failed, id, reason}}
        end

      {:error, reason} ->
        {:error, {:thaw_failed, id, reason}}
    end
  end

  defp teardown_boot(boot, opts) do
    teardown = Keyword.get(opts, :teardown, &default_teardown/1)
    _ = teardown.(boot)
    :ok
  end

  defp default_teardown(boot) when is_map(boot) do
    if conn = Map.get(boot, :conn) do
      if is_pid(conn) and Process.alive?(conn) do
        _ = GenServer.stop(conn, :normal, 5_000)
      end
    end

    MemorySnapshot.teardown(boot)
  rescue
    _ -> :ok
  end

  defp connect_vsock(thawed, opts) do
    timeout = Keyword.get(opts, :connect_timeout_ms, @default_connect_timeout_ms)
    deadline = System.monotonic_time(:millisecond) + timeout
    connect_loop(thawed, deadline, nil)
  end

  defp connect_loop(thawed, deadline, last_reason) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, last_reason || :timeout}
    else
      case Connection.start_link(%{vm_id: thawed.vm_id, socket_path: thawed.vsock_socket}) do
        {:ok, pid} ->
          case Connection.ping(pid, 3_000) do
            :pong ->
              {:ok, pid}

            {:error, reason} ->
              _ = safe_stop(pid)
              Process.sleep(250)
              connect_loop(thawed, deadline, reason)
          end

        {:error, reason} ->
          Process.sleep(250)
          connect_loop(thawed, deadline, reason)
      end
    end
  end

  defp safe_stop(pid) do
    if is_pid(pid) and Process.alive?(pid), do: GenServer.stop(pid, :normal, 2_000)
  rescue
    _ -> :ok
  end

  @doc """
  Read `bytes` of `/dev/urandom` from a guest and return lowercase hex.

  Uses `od` rather than `xxd` so a minimal Ubuntu rootfs can run it. The
  sample is taken *after* reseed when this is called from `run/2`, which is
  the property the acceptance criterion asks for.
  """
  @spec sample_urandom(pid(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def sample_urandom(conn, bytes) when is_integer(bytes) and bytes > 0 do
    cmd = "head -c #{bytes} /dev/urandom | od -An -tx1 | tr -d ' \\n'"

    case Connection.exec(conn, cmd) do
      {:ok, out} ->
        hex =
          out
          |> to_string()
          |> String.downcase()
          |> String.replace(~r/[^0-9a-f]/, "")

        if byte_size(hex) == bytes * 2 do
          {:ok, hex}
        else
          {:error, {:malformed_sample, out}}
        end

      {:error, reason} ->
        {:error, {:sample_failed, reason}}
    end
  end
end
