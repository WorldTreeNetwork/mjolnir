defmodule Mjolnir.ProxyGuestTest do
  use ExUnit.Case, async: false
  alias Mjolnir.{ProxyGuest, VM}

  setup do
    root = Path.join(System.tmp_dir!(), "proxy-class-#{System.unique_integer([:positive])}")
    image = Path.join([root, "@base", "proxy-fixture"])
    File.mkdir_p!(image)
    {_, 0} = System.cmd("bash", ["scripts/install-proxy-guest-class.sh", image])
    old_root = Application.fetch_env(:mjolnir, :btrfs_root)
    Application.put_env(:mjolnir, :btrfs_root, root)

    on_exit(fn ->
      case old_root do
        {:ok, value} -> Application.put_env(:mjolnir, :btrfs_root, value)
        :error -> Application.delete_env(:mjolnir, :btrfs_root)
      end

      File.rm_rf!(root)
    end)

    %{root: root, image: image}
  end

  test "installed artifacts identify the class, independently of the image name", %{image: image} do
    assert ProxyGuest.class_for_root(image) == :proxy
    assert ProxyGuest.image_class("proxy-fixture") == :proxy
    network = File.read!(Path.join(image, "usr/local/bin/mjolnir-network-setup"))

    drop_in =
      File.read!(
        Path.join(image, "etc/systemd/system/identikey-api-proxy.service.d/data-dir.conf")
      )

    assert ProxyGuest.classify(network, drop_in) == :proxy
    assert ProxyGuest.classify(network, nil) == :ordinary
    assert ProxyGuest.classify("stock", drop_in) == :ordinary
    assert network =~ "route replace 10.200.0.1/32"
    assert network =~ "route del default"
    assert network =~ "nameserver 127.0.0.1"
    assert drop_in =~ "--data-dir /var/lib/private/identikey-api-proxy"
    assert drop_in =~ "IPAddressAllow=10.200.0.1/32"
    assert {_, 0} = System.cmd("bash", ["scripts/install-proxy-guest-class.sh", image])
    assert ProxyGuest.class_for_root(image) == :proxy
  end

  test "proxy omitted Iroh resolves false; explicit true is refused before a guest starts" do
    assert {:ok, %{enable_iroh: false}} = VM.resolve_spawn_network(%{base_image: "proxy-fixture"})

    assert {:error, :proxy_guest_iroh_forbidden} =
             VM.spawn(%{base_image: "proxy-fixture", enable_iroh: true})

    assert {:error, :proxy_guest_iroh_forbidden} =
             VM.spawn_with_id(%{id: "unused", base_image: "proxy-fixture", enable_iroh: true})

    assert {:stop, :proxy_guest_iroh_forbidden} =
             VM.init(%{
               id: Mjolnir.VmId.generate(),
               base_image: "proxy-fixture",
               enable_iroh: true
             })
  end

  test "ordinary explicit false does not create a proxy class", %{root: root} do
    ordinary = Path.join([root, "@base", "ordinary"])
    File.mkdir_p!(Path.join(ordinary, "usr/local/bin"))
    stock = "ip route add default dev eth0\nnameserver 1.1.1.1\n"
    File.write!(Path.join(ordinary, "usr/local/bin/mjolnir-network-setup"), stock)

    assert {:ok, %{enable_iroh: false}} =
             VM.resolve_spawn_network(%{base_image: "ordinary", enable_iroh: false})

    assert ProxyGuest.image_class("ordinary") == :ordinary
    assert File.read!(Path.join(ordinary, "usr/local/bin/mjolnir-network-setup")) == stock
    assert ProxyGuest.resolve_iroh(:ordinary, nil, true) == {:ok, true}
    assert ProxyGuest.resolve_iroh(:proxy, nil, true) == {:ok, false}
  end

  test "running-record to reboot resume options preserves the base and false flag" do
    vm = %VM{
      id: Mjolnir.VmId.generate(),
      enable_iroh: false,
      config: %{base_image: "proxy-fixture", vcpu_count: 1, mem_size_mib: 512}
    }

    record = VM.build_running_record(vm)
    assert record.spawn_config["base_image"] == "proxy-fixture"
    assert record.spawn_config["enable_iroh"] == false
    assert %{base_image: "proxy-fixture", enable_iroh: false} = opts = VM.resume_opts(record)
    assert {:ok, %{enable_iroh: false}} = VM.resolve_spawn_network(opts)
    legacy = %{record | spawn_config: %{"base_image" => "ordinary"}}
    assert VM.resume_opts(legacy).enable_iroh == nil

    assert ProxyGuest.resolve_iroh(:ordinary, VM.resume_opts(legacy).enable_iroh, true) ==
             {:ok, true}
  end

  test "installer refuses the host root and symlink escapes", %{root: root} do
    assert {_, 1} =
             System.cmd("bash", ["scripts/install-proxy-guest-class.sh", "/"],
               stderr_to_stdout: true
             )

    escape = Path.join(root, "escape")
    File.mkdir_p!(escape)
    File.ln_s!("/tmp", Path.join(escape, "usr"))

    assert {_, 1} =
             System.cmd("bash", ["scripts/install-proxy-guest-class.sh", escape],
               stderr_to_stdout: true
             )
  end
end
