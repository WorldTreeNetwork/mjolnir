defmodule Mjolnir.Health.Host do
  @moduledoc """
  Host-wide checks that gate the entire fleet's health. Each returns a
  report entry of `%{name: ..., status: ..., detail: ...}`.

  These probes exercise things that *cannot* be tested per-VM — kernel
  modules, NAT rules, btrfs mount state. If any of these is `:dead`, no
  fresh VM spawn can succeed, and existing VMs may not be reachable.

  Some heals are automatic (sysctl, iptables), some are refuse-to-fix
  (`btrfs root readonly` — don't auto-remount, fail loudly instead).
  """

  require Logger

  @type report_entry :: %{name: String.t(), status: :ok | {:degraded, any()} | {:dead, any()}}

  @spec check() :: [report_entry()]
  def check do
    [
      check_kvm(),
      check_vsock_module(),
      check_ip_forward(),
      check_nat(),
      check_btrfs_mount(),
      check_socket_dir(),
      check_state_dir()
    ]
  end

  @spec heal() :: :ok
  def heal do
    # Best-effort automatic heals. Failed heals are logged; nothing raises.
    _ = heal_kvm()
    _ = heal_vsock_module()
    _ = heal_ip_forward()
    _ = heal_nat()
    _ = heal_socket_dir()
    _ = heal_state_dir()
    :ok
  end

  # --- KVM ---

  defp check_kvm do
    if File.exists?("/dev/kvm") do
      entry("kvm", :ok)
    else
      entry("kvm", {:dead, :no_dev_kvm})
    end
  end

  defp heal_kvm do
    case System.cmd("modprobe", ["kvm"], stderr_to_stdout: true) do
      {_, 0} ->
        System.cmd("modprobe", ["kvm_intel"], stderr_to_stdout: true)
        :ok

      {out, code} ->
        Logger.warning("modprobe kvm failed (#{code}): #{out}")
        {:error, {:modprobe_failed, code}}
    end
  end

  # --- vhost-vsock ---

  defp check_vsock_module do
    if File.exists?("/dev/vhost-vsock") do
      entry("vhost_vsock", :ok)
    else
      entry("vhost_vsock", {:dead, :no_dev_vhost_vsock})
    end
  end

  defp heal_vsock_module do
    case System.cmd("modprobe", ["vhost_vsock"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:modprobe_failed, code, out}}
    end
  end

  # --- IP forwarding ---

  defp check_ip_forward do
    case File.read("/proc/sys/net/ipv4/ip_forward") do
      {:ok, "1\n"} -> entry("ip_forward", :ok)
      {:ok, other} -> entry("ip_forward", {:dead, {:disabled, String.trim(other)}})
      {:error, reason} -> entry("ip_forward", {:dead, reason})
    end
  end

  defp heal_ip_forward do
    case System.cmd("sysctl", ["-w", "net.ipv4.ip_forward=1"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:sysctl_failed, code, out}}
    end
  end

  # --- NAT masquerade ---
  #
  # VMs use private /32 addresses in 10.200.0.0/10 and rely on a host-wide
  # MASQUERADE rule in iptables nat POSTROUTING for outbound traffic. If the
  # rule is missing (wiped by `iptables -F`, stomped on by a `ufw reload`
  # without our before.rules, etc.), guests can ping each other but nothing
  # reaches the internet — the original "LLM hangs on second inference"
  # signature.
  #
  # Heal strategy lives in `Mjolnir.Network.ensure_nat/1`: reload ufw when
  # active (our rule lives in /etc/ufw/before.rules), otherwise add the rule
  # directly via iptables.

  defp check_nat do
    if Mjolnir.Network.nat_rule_present?() do
      entry("nat_masquerade", :ok)
    else
      entry("nat_masquerade", {:dead, :missing_masquerade_rule})
    end
  end

  defp heal_nat do
    case Mjolnir.Network.ensure_nat() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Health.Host: NAT heal failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # --- BTRFS root ---

  defp check_btrfs_mount do
    root = Application.get_env(:mjolnir, :btrfs_root)

    cond do
      is_nil(root) ->
        entry("btrfs_mount", {:dead, :no_btrfs_root_configured})

      not File.dir?(root) ->
        entry("btrfs_mount", {:dead, {:not_a_dir, root}})

      true ->
        case System.cmd("findmnt", ["-n", "-o", "FSTYPE,OPTIONS", root], stderr_to_stdout: true) do
          {out, 0} ->
            if String.contains?(out, "btrfs") and not String.contains?(out, "ro,") do
              entry("btrfs_mount", :ok, String.trim(out))
            else
              entry("btrfs_mount", {:dead, {:bad_mount, String.trim(out)}})
            end

          {out, _} ->
            entry("btrfs_mount", {:dead, {:findmnt_failed, String.trim(out)}})
        end
    end
  end

  # NOTE: no heal for btrfs — if root is readonly or wrong fs, something
  # is seriously wrong upstream (hardware, kernel, corruption). Auto-remount
  # is too risky. Fail loudly and let a human investigate.

  # --- Socket dir ---

  defp check_socket_dir do
    dir = Application.get_env(:mjolnir, :socket_dir)
    check_writable_dir("socket_dir", dir)
  end

  defp heal_socket_dir do
    dir = Application.get_env(:mjolnir, :socket_dir)
    if dir, do: File.mkdir_p(dir), else: :ok
  end

  # --- State dir ---

  defp check_state_dir do
    dir = Application.get_env(:mjolnir, :state_dir)
    check_writable_dir("state_dir", dir)
  end

  defp heal_state_dir do
    dir = Application.get_env(:mjolnir, :state_dir)
    if dir, do: File.mkdir_p(dir), else: :ok
  end

  defp check_writable_dir(name, nil), do: entry(name, {:dead, :not_configured})

  defp check_writable_dir(name, path) do
    canary = Path.join(path, ".health-canary-#{System.unique_integer([:positive])}")

    case File.write(canary, "ok") do
      :ok ->
        File.rm(canary)
        entry(name, :ok, path)

      {:error, reason} ->
        entry(name, {:dead, reason}, path)
    end
  end

  defp entry(name, status, detail \\ nil)

  defp entry(name, status, nil), do: %{name: name, status: status}
  defp entry(name, status, detail), do: %{name: name, status: status, detail: detail}
end
