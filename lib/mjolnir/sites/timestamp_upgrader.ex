defmodule Mjolnir.Sites.TimestampUpgrader do
  @moduledoc """
  Periodic OpenTimestamps proof upgrader.

  At publish time, snapshots get a "pending" `.ots` receipt from the
  OpenTimestamps calendar servers. This GenServer wakes on a schedule
  (configurable via `:sites_ots_upgrade_interval_ms`) and asks the calendars
  whether each pending receipt's Bitcoin commitment has confirmed; if so, it
  fetches the Bitcoin block proof and rewrites the `.ots` file as a
  self-contained, trust-minimized verification artifact.

  See `docs/plans/initiatives/identikey-sites.md` §6.1.1.

  Phase 1 scaffold: the GenServer is wired up and runs on schedule, but the
  actual OTS calendar interaction is STUBBED. The seam is `upgrade_one/1` —
  to be replaced with calls to an `opentimestamps` binary or a Rust client.
  """

  use GenServer
  require Logger

  @default_interval_ms 30 * 60 * 1_000

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Force a sweep now (for tests and manual invocation)."
  @spec sweep_now() :: :ok
  def sweep_now do
    GenServer.call(__MODULE__, :sweep_now)
  end

  ## GenServer

  @impl true
  def init(_opts) do
    interval = Application.get_env(:mjolnir, :sites_ots_upgrade_interval_ms, @default_interval_ms)
    schedule(interval)
    Logger.info("Sites.TimestampUpgrader: interval=#{interval}ms")
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_call(:sweep_now, _from, state) do
    {n_upgraded, n_pending} = sweep()

    {:reply, :ok,
     state |> Map.put(:last_upgraded, n_upgraded) |> Map.put(:last_pending, n_pending)}
  end

  @impl true
  def handle_info(:tick, state) do
    {n_upgraded, n_pending} = sweep()

    if n_upgraded > 0 do
      Logger.info("Sites.TimestampUpgrader: upgraded #{n_upgraded} (#{n_pending} still pending)")
    end

    schedule(state.interval)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internals

  defp schedule(interval) do
    Process.send_after(self(), :tick, interval)
  end

  defp sweep do
    root = Mjolnir.Sites.Store.root()
    manifests_dir = Path.join(root, "manifests")

    case File.ls(manifests_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".ots"))
        |> Enum.reduce({0, 0}, fn name, {up, pend} ->
          path = Path.join(manifests_dir, name)

          case upgrade_one(path) do
            :upgraded -> {up + 1, pend}
            :still_pending -> {up, pend + 1}
            :error -> {up, pend}
          end
        end)

      {:error, :enoent} ->
        {0, 0}

      {:error, reason} ->
        Logger.warning(
          "Sites.TimestampUpgrader: cannot list #{manifests_dir}: #{inspect(reason)}"
        )

        {0, 0}
    end
  end

  # OTS upgrade seam: read the receipt at `path`, ask the calendar(s) whether
  # the Bitcoin commitment has confirmed, and if so atomically rewrite the file
  # with the upgraded (block-anchored) proof bytes.
  defp upgrade_one(path) do
    with {:ok, receipt_bytes} <- File.read(path) do
      case Mjolnir.Sites.OpenTimestamps.upgrade(receipt_bytes) do
        {:ok, :upgraded, new_bytes} ->
          tmp = path <> ".tmp"

          case write_atomic(tmp, path, new_bytes) do
            :ok ->
              Logger.info("Sites.TimestampUpgrader: upgraded #{path}")
              :upgraded

            {:error, reason} ->
              Logger.warning(
                "Sites.TimestampUpgrader: failed to rewrite #{path}: #{inspect(reason)}"
              )

              :error
          end

        {:ok, :still_pending} ->
          :still_pending

        {:error, :ots_not_installed} ->
          Logger.warning("Sites.TimestampUpgrader: ots CLI not installed; skipping upgrade")
          :still_pending

        {:error, reason} ->
          Logger.warning("Sites.TimestampUpgrader: upgrade error for #{path}: #{inspect(reason)}")

          :error
      end
    else
      {:error, reason} ->
        Logger.warning("Sites.TimestampUpgrader: cannot read #{path}: #{inspect(reason)}")
        :error
    end
  end

  defp write_atomic(tmp, final, bytes) do
    with {:ok, io} <- :file.open(tmp, [:raw, :write, :binary]),
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
