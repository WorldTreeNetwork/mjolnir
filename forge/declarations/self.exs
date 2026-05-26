defmodule Forge.Declarations.MjolnirSelf do
  # Forge declarations for the Mjolnir control-plane host (self).
  #
  # Intentionally NOT managed here:
  #   * /etc/mjolnir/env           — contains the release cookie; lives outside source control
  #   * /etc/forgejo/app.ini       — contains DB creds + secrets; managed by Forgejo itself
  #   * /etc/mjolnir/gateway.env   — contains API keys; hand-managed per host
  use Mjolnir.Forge.Declaration, host: "self"

  # ── Mjolnir services ──────────────────────────────────────────────────

  systemd_unit "mjolnir.service" do
    source File.read!("systemd/mjolnir.service")
    enabled true
    state :running
  end

  systemd_unit "mjolnir-gateway.service" do
    source File.read!("systemd/mjolnir-gateway.service")
    enabled true
    state :running
  end

  # ── Forgejo services ──────────────────────────────────────────────────

  systemd_unit "forgejo.service" do
    source File.read!("systemd/forgejo.service")
    enabled true
    state :running
  end

  # Drop-in override: Forgejo needs ProtectHome=false to read SSH authorized_keys
  file "/etc/systemd/system/forgejo.service.d/ssh-keys.conf" do
    source "[Service]\nProtectHome=false\n"
    mode 0o644
    owner "root"
    group "root"
  end

  systemd_unit "forgejo-backup.service" do
    source File.read!("systemd/forgejo-backup.service")
    enabled false
    state :stopped
  end

  systemd_unit "forgejo-backup.timer" do
    source File.read!("systemd/forgejo-backup.timer")
    enabled true
    state :running
  end

  # ── Kernel parameters ─────────────────────────────────────────────────

  sysctl "net.ipv4.ip_forward" do
    value "1"
  end

  # ── Network: VM NAT ───────────────────────────────────────────────────
  #
  # NOTE: The server currently uses legacy markers (# BEGIN MJOLNIR NAT).
  # First apply requires manually removing the old block from
  # /etc/ufw/before.rules, then `forge apply` will insert the
  # Forge-managed block with standard markers.

  ufw_nat "mjolnir-vm-nat" do
    rules """
    *nat
    :POSTROUTING ACCEPT [0:0]
    -A POSTROUTING -s 10.200.0.0/10 -o enp1s0 -j MASQUERADE
    COMMIT
    """
  end
end
