defmodule Mjolnir.HonorBeing.KeyScrubTest do
  use ExUnit.Case, async: true

  alias Mjolnir.HonorBeing.KeyScrub

  setup do
    root = Path.join(System.tmp_dir!(), "mj-key-scrub-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "root/.config/grok"))
    File.mkdir_p!(Path.join(root, "root/hypersigil-store-frontend"))
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "hosted snapshot names", do: assert(KeyScrub.hosted_snapshot_name?("hosted-abc"))

  test "other snapshot names are left alone",
    do: refute(KeyScrub.hosted_snapshot_name?("ubuntu-24.04"))

  test "strips grok config, history, and storefront .env", %{root: root} do
    File.write!(Path.join(root, "root/.config/grok/config.toml"), """
    model = "grok-4"
    XAI_API_KEY = "sk-secret"
    """)

    File.write!(Path.join(root, "root/.bash_history"), """
    echo hi
    export XAI_API_KEY=sk-secret
    ls
    """)

    File.write!(Path.join(root, "root/hypersigil-store-frontend/.env"), """
    VITE_MEDUSA_BACKEND_URL=https://api.hypersigil.world
    XAI_API_KEY=sk-secret
    """)

    File.write!(Path.join(root, "root/.bashrc"), "export PATH=/usr/bin\n")

    assert KeyScrub.contains_key?(root)
    assert :ok = KeyScrub.scrub_rootfs(root)
    refute KeyScrub.contains_key?(root)

    grok = File.read!(Path.join(root, "root/.config/grok/config.toml"))
    refute grok =~ "XAI_API_KEY"
    assert grok =~ "model = \"grok-4\""

    hist = File.read!(Path.join(root, "root/.bash_history"))
    refute hist =~ "XAI_API_KEY"
    assert hist =~ "echo hi"

    env = File.read!(Path.join(root, "root/hypersigil-store-frontend/.env"))
    refute env =~ "XAI_API_KEY"
    assert env =~ "VITE_MEDUSA_BACKEND_URL"

    bashrc = File.read!(Path.join(root, "root/.bashrc"))
    assert bashrc =~ "PATH"
  end

  test "missing rootfs is an error" do
    assert {:error, :no_rootfs} =
             KeyScrub.scrub_rootfs("/no/such/rootfs-#{System.unique_integer([:positive])}")
  end
end
