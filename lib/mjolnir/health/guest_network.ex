defmodule Mjolnir.Health.GuestNetwork do
  @moduledoc """
  L2 check: can the guest exec a ping, and does it come back?

  Runs `ping -c1 -W2 <gateway>` inside the guest via vsock exec. The
  gateway is the host-side IP associated with the guest's TAP. A failure
  here usually means the TAP is down, routing is wiped, or NAT is broken
  — any of which are fixable by re-running `configure_network`.
  """

  @behaviour Mjolnir.Health.Check

  require Logger

  @impl true
  def level, do: 2

  @impl true
  def name, do: "guest_network"

  @impl true
  def probe(%Mjolnir.VM{net_config: nil}), do: {:dead, :no_net_config}

  def probe(%Mjolnir.VM{} = vm) do
    # Guest-agnostic network probe: does the guest have a default route?
    # This tests that `configure_network` successfully installed routing.
    # Interface names vary (eth0 on Ubuntu, enp0s* on Arch), so we probe
    # the route table directly. "default" appears if and only if routing
    # is working.
    try do
      case Mjolnir.VM.exec(
             vm.id,
             "ip route show default 2>/dev/null | head -1",
             timeout: 5_000
           ) do
        {:ok, output} ->
          if String.contains?(output, "default") do
            :ok
          else
            {:dead, {:no_default_route, String.trim(output)}}
          end

        {:error, reason} ->
          {:dead, reason}
      end
    catch
      :exit, reason -> {:dead, {:exit, reason}}
    end
  end

  @impl true
  def heal(%Mjolnir.VM{} = vm) do
    Mjolnir.VM.reconfigure_network(vm.id)
  end
end
