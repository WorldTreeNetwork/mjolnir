defmodule Forge.Declarations.MjolnirSelf do
  # Forge declarations for the Mjolnir control-plane host itself.
  #
  # Intentionally NOT managed here:
  #   * /etc/mjolnir/env             — contains the release cookie; lives outside source control
  #   * .../mjolnir.service.d/override.conf — hand-tuned hardening overrides; leave :unmanaged
  #     until we understand each setting it disables (User=, PrivateTmp=, etc.)
  use Mjolnir.Forge.Declaration, host: "self"

  systemd_unit "mjolnir.service" do
    source File.read!("systemd/mjolnir.service")
    enabled true
    state :running
  end
end
