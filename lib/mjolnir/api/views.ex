defmodule Mjolnir.API.Views do
  @moduledoc """
  JSON serialization helpers for VM data.
  """

  @doc """
  Full VM representation including connection details.
  """
  @gateway_domain Application.compile_env(:mjolnir, :gateway_domain, "vm.worldtree.network")

  def render_vm(vm) do
    %{
      id: vm.id,
      state: vm.state,
      owner_id: vm.owner_id,
      hypervisor: hypervisor_name(vm.hypervisor),
      guest_ip: get_in_net(vm, :guest_ip),
      pty_ready: vm.pty_ready || false,
      ticket: vm.ticket,
      iroh_node_id: vm.iroh_node_id,
      iroh_addr: vm.iroh_json,
      enable_iroh: vm.enable_iroh,
      restart_policy: vm.restart_policy || :always,
      web_url: web_url(vm),
      config: render_config(vm.config),
      boot_time: vm.boot_time,
      rootfs_bytes: rootfs_bytes(vm),
      persist_interval_ms: Application.get_env(:mjolnir, :dormant_flush_delay_ms, 250)
    }
  end

  # Exclusive (CoW-aware) disk cost of this VM's rootfs. Computed on the detail
  # view only — one btrfs du shell-out — never in the list path.
  defp rootfs_bytes(%{rootfs_path: path}) when is_binary(path) and path != "" do
    Mjolnir.BTRFS.du_exclusive(path)
  end

  defp rootfs_bytes(_), do: nil

  @doc "JSON for one `@trash` entry (soft-deleted VM)."
  def render_trash_entry(entry) do
    %{
      vm_id: entry.vm_id,
      trashed_at: entry.trashed_at,
      age_seconds: entry.age_seconds,
      reaps_in_seconds: entry.reaps_in_seconds,
      restorable: Map.get(entry, :restorable, entry.metadata != nil),
      owner_id: get_in(entry, [:metadata, "spawn_config", "owner_id"])
    }
  end

  @doc """
  Summary VM representation for list endpoints.
  """
  def render_vm_summary(vm) do
    %{
      id: vm.id,
      state: vm.state,
      owner_id: vm.owner_id,
      hypervisor: hypervisor_name(vm.hypervisor),
      guest_ip: get_in_net(vm, :guest_ip),
      pty_ready: vm.pty_ready || false,
      ticket: vm.ticket,
      iroh_node_id: vm.iroh_node_id,
      web_url: web_url(vm),
      metadata: vm.metadata || %{},
      generation: generation_of(vm.id)
    }
  end

  @doc """
  Render a summary for a stranded/recovering VM (a StateStore record whose
  GenServer is not currently alive). Same shape as `render_vm_summary/1` so
  clients can render one list, plus a `rootfs_present` recoverability flag.
  """
  def render_stranded_summary(record) do
    config = record.spawn_config || %{}

    %{
      id: record.uuid,
      state: :recovering,
      owner_id: Map.get(config, "owner_id"),
      hypervisor: nil,
      guest_ip: nil,
      pty_ready: false,
      ticket: nil,
      iroh_node_id: nil,
      web_url: nil,
      rootfs_present: File.exists?(Mjolnir.Reconcile.rootfs_path(record.uuid)),
      metadata: record.metadata || %{},
      generation: record.generation
    }
  end

  @doc """
  Render a summary for a VM that `Mjolnir.Reconcile` retired to `intent: :failed`
  after repeated resume failures (mjolnir-5fu). Same shape as a recovering VM,
  but `state: :failed` and with the failure counters so an operator can see why
  it gave up. The VM is no longer auto-resumed — revive it with
  `POST /api/vms/:id/revive` once the cause is fixed.
  """
  def render_failed_summary(record) do
    config = record.spawn_config || %{}
    runtime = record.runtime || %{}

    %{
      id: record.uuid,
      state: :failed,
      owner_id: Map.get(config, "owner_id"),
      hypervisor: nil,
      guest_ip: nil,
      pty_ready: false,
      ticket: nil,
      iroh_node_id: nil,
      web_url: nil,
      rootfs_present: File.exists?(Mjolnir.Reconcile.rootfs_path(record.uuid)),
      metadata: record.metadata || %{},
      generation: record.generation,
      resume_failures: Map.get(runtime, "resume_failures"),
      first_failure_at: Map.get(runtime, "first_failure_at"),
      last_failure_at: Map.get(runtime, "last_failure_at")
    }
  end

  @doc """
  Render a VM that ended and was deliberately not restarted — a record
  `Mjolnir.Reconcile` finalized because its `restart_policy` is `:never`
  (mjolnir-yhr).

  `state: :stopped`, not `:failed`: nothing went wrong. The rootfs is preserved,
  so a later owner-initiated start can resume from it. Any harness exit evidence
  the guest left behind is surfaced here so the operator can see *how* it ended
  (`exited`/`0` is an intentional termination) without shelling into the
  subvolume.
  """
  def render_stopped_summary(record) do
    config = record.spawn_config || %{}
    runtime = record.runtime || %{}

    %{
      id: record.uuid,
      state: :stopped,
      owner_id: Map.get(config, "owner_id"),
      hypervisor: nil,
      guest_ip: nil,
      pty_ready: false,
      ticket: nil,
      iroh_node_id: nil,
      web_url: nil,
      rootfs_present: File.exists?(Mjolnir.Reconcile.rootfs_path(record.uuid)),
      metadata: record.metadata || %{},
      generation: record.generation,
      restart_policy: Map.get(config, "restart_policy", "always"),
      finalized_at: Map.get(runtime, "finalized_at"),
      harness_exit_reason: Map.get(runtime, "harness_exit_reason"),
      harness_exit_status: Map.get(runtime, "harness_exit_status")
    }
  end

  # The live VM struct carries metadata, but `generation` belongs to the durable
  # record — it is the fencing token, so it has to come from the thing being
  # fenced. An ETS read, so cheap enough to do per row.
  defp generation_of(vm_id) do
    case Mjolnir.StateStore.get(vm_id) do
      {:ok, record} -> record.generation
      :not_found -> nil
    end
  end

  defp get_in_net(vm, key) do
    case vm.net_config do
      %{^key => val} -> val
      _ -> nil
    end
  end

  defp hypervisor_name(nil), do: nil

  defp hypervisor_name(hypervisor_module) when is_atom(hypervisor_module) do
    hypervisor_module.process_name()
  end

  defp web_url(%{enable_iroh: true, ticket: ticket}) when is_binary(ticket) do
    "https://#{ticket}.#{@gateway_domain}"
  end

  defp web_url(_), do: nil

  defp render_config(nil), do: nil

  defp render_config(config) do
    %{
      vcpu_count: config.vcpu_count,
      mem_size_mib: config.mem_size_mib,
      base_image: config.base_image,
      snapshot: config.snapshot
    }
  end
end
