defmodule Mjolnir.Health.IrohConnection do
  @moduledoc """
  L1 check: is the guest's Iroh endpoint actually reachable, or has the
  relay/QUIC connection silently rotted?

  This is the *motivating* check for the whole Health system. The pattern
  that inspired it: a VM's Iroh connection would work on the first inference
  request, then silently hang on the second — socket open, handshake done,
  but packets vanished. `get_iroh_status` over vsock from the host is our
  way of exercising the dependency end-to-end (ish): we at least confirm
  the guest agent thinks the iroh daemon is reachable.

  Heal: re-run `configure_iroh(true)` which tells the guest to tear down
  and rebuild its Iroh endpoint.
  """

  @behaviour Mjolnir.Health.Check

  require Logger

  @impl true
  def level, do: 1

  @impl true
  def name, do: "iroh_connection"

  @impl true
  def probe(%Mjolnir.VM{enable_iroh: false}), do: :ok

  def probe(%Mjolnir.VM{vsock_path: nil}), do: {:dead, :no_vsock_path}

  def probe(%Mjolnir.VM{} = vm) do
    case Mjolnir.VM.iroh_status(vm.id, 3_000) do
      {:ok, %{ready: true}} -> :ok
      {:ok, %{ready: false}} -> {:degraded, :iroh_not_ready}
      {:error, :timeout} -> {:dead, :iroh_probe_timeout}
      {:error, reason} -> {:dead, reason}
    end
  end

  @impl true
  def heal(%Mjolnir.VM{} = vm) do
    case Mjolnir.VM.reconfigure_iroh(vm.id) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
