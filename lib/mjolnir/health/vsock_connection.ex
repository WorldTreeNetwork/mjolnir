defmodule Mjolnir.Health.VsockConnection do
  @moduledoc """
  L1 check: is the `Mjolnir.Vsock.Connection` GenServer responsive?

  Probe: send a ping through the existing connection GenServer (not a
  fresh socket). If the GenServer call times out or returns an error,
  the connection is considered dead/degraded.

  Heal: stop and restart the `Vsock.Connection` GenServer on the VM.
  """

  @behaviour Mjolnir.Health.Check

  require Logger

  @impl true
  def level, do: 1

  @impl true
  def name, do: "vsock_connection"

  @impl true
  def probe(%Mjolnir.VM{vsock_conn: nil}), do: {:dead, :no_vsock_conn}

  def probe(%Mjolnir.VM{vsock_conn: conn}) do
    unless Process.alive?(conn) do
      {:dead, :vsock_conn_process_dead}
    else
      try do
        case Mjolnir.Vsock.Connection.ping(conn, 2_000) do
          :ok -> :ok
          :pong -> :ok
          {:ok, _} -> :ok
          {:pong, _} -> :ok
          {:error, reason} -> {:dead, reason}
          other -> {:degraded, {:unexpected, other}}
        end
      catch
        :exit, {:timeout, _} -> {:dead, :ping_timeout}
        :exit, reason -> {:dead, {:exit, reason}}
      end
    end
  end

  @impl true
  def heal(%Mjolnir.VM{id: vm_id}) do
    Mjolnir.VM.rebuild_vsock_connection(vm_id)
  end
end
