defmodule Mjolnir.LanFilesInstallTest do
  use ExUnit.Case, async: false
  import Bitwise, only: [band: 2]
  alias Mjolnir.LanFiles

  @config %{vm_id: "share", interface: "lan-test", publish_port: 7443, http_port: 8080}
  @unit "etc/systemd/system/mjolnir-lan-files.service"
  @config_file Path.expand("../../config/runtime.exs", __DIR__)

  setup do
    temp = Path.join(System.tmp_dir!(), "lan-files-#{System.unique_integer([:positive])}")
    rootfs = Path.join(temp, "rootfs")
    binary = Path.join(temp, "fake-lan-files")
    File.mkdir_p!(rootfs)
    File.write!(binary, "fake guest binary\n")
    on_exit(fn -> File.rm_rf!(temp) end)
    %{rootfs: rootfs, binary: binary}
  end

  test "installs a service bound only to the selected guest IPv4 and HTTP port", ctx do
    assert :ok = LanFiles.install(ctx.rootfs, "share", "10.200.0.9", @config, ctx.binary)
    destination = Path.join(ctx.rootfs, "usr/local/bin/mjolnir-lan-files")
    assert File.read!(destination) == File.read!(ctx.binary)
    assert band(File.stat!(destination).mode, 0o777) == 0o755
    assert File.dir?(Path.join(ctx.rootfs, "var/lib/mjolnir"))

    unit = File.read!(Path.join(ctx.rootfs, @unit))
    assert unit =~ "Environment=LAN_FILES_BIND=10.200.0.9:8080\n"
    assert unit =~ "Environment=LAN_FILES_METADATA=/var/lib/mjolnir/lan-files.sqlite\n"
    assert unit =~ "ExecStart=/usr/local/bin/mjolnir-lan-files\n"
    assert unit =~ "Restart=always\n"
    assert unit =~ "RestartSec=2s\n"
    assert unit =~ "StartLimitIntervalSec=0\n"
    for forbidden <- ["0.0.0.0", "::", "7222"], do: refute(unit =~ forbidden)

    link =
      Path.join(ctx.rootfs, "etc/systemd/system/basic.target.wants/mjolnir-lan-files.service")

    assert File.read_link!(link) == "../mjolnir-lan-files.service"
    assert File.read!(link) == unit
  end

  test "refreshing a reused rootfs updates address and binary and preserves metadata", ctx do
    assert :ok = LanFiles.install(ctx.rootfs, "share", "10.200.0.9", @config, ctx.binary)
    metadata = Path.join(ctx.rootfs, "var/lib/mjolnir/lan-files.sqlite")
    File.write!(metadata, "existing ownership")
    File.write!(ctx.binary, "updated guest binary")
    updated = %{@config | http_port: 9090}

    for _ <- 1..2 do
      assert :ok = LanFiles.install(ctx.rootfs, "share", "10.200.0.12", updated, ctx.binary)
    end

    unit = File.read!(Path.join(ctx.rootfs, @unit))
    assert unit =~ "LAN_FILES_BIND=10.200.0.12:9090\n"
    refute unit =~ "10.200.0.9"

    assert File.read!(Path.join(ctx.rootfs, "usr/local/bin/mjolnir-lan-files")) ==
             "updated guest binary"

    assert File.read!(metadata) == "existing ownership"
  end

  test "disabled, mismatched VM, and absent binaries leave the rootfs untouched", ctx do
    for {vm_id, config, binary} <- [
          {"share", nil, ctx.binary},
          {"other", @config, ctx.binary},
          {"share", @config, nil},
          {"share", @config, Path.join(ctx.rootfs, "missing-binary")}
        ] do
      assert :ok = LanFiles.install(ctx.rootfs, vm_id, "10.200.0.9", config, binary)
      refute File.exists?(Path.join(ctx.rootfs, @unit))
      assert File.ls!(ctx.rootfs) == []
    end
  end

  test "installer refuses unspecified or non-IPv4 binds and the blob door port", ctx do
    for ip <- ["0.0.0.0", "::", "2001:db8::1"] do
      assert {:error, :invalid_lan_files_bind} =
               LanFiles.install(ctx.rootfs, "share", ip, @config, ctx.binary)
    end

    assert {:error, :invalid_lan_files_bind} =
             LanFiles.install(
               ctx.rootfs,
               "share",
               "10.200.0.9",
               %{@config | http_port: 7222},
               ctx.binary
             )

    assert File.ls!(ctx.rootfs) == []
  end

  test "standalone config parses env without changing application configuration" do
    keys = ["MJOLNIR_LAN_FILES", "MJOLNIR_LAN_FILES_BIN"]
    previous = Map.new(keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {key, value} <- previous do
        if value == nil, do: System.delete_env(key), else: System.put_env(key, value)
      end
    end)

    System.put_env("MJOLNIR_LAN_FILES_BIN", "/tmp/fake-lan-files")
    System.put_env("MJOLNIR_LAN_FILES", "share,lan-test,7443,8080")
    config = Config.Reader.read!(@config_file, env: :test) |> Keyword.fetch!(:mjolnir)
    assert config[:lan_files] == @config
    assert config[:lan_files_bin] == "/tmp/fake-lan-files"

    for invalid <- [
          "share,lan-test,bad,8080",
          "share,lan-test,7443,8080suffix",
          "share,lan-test,0,8080",
          "share,lan-test,7443,65536",
          "share,lan-test,7222,8080",
          "share,lan-test,7443,7222",
          "share,lan-test,7443",
          "share,lan-test,7443,8080,extra",
          ",lan-test,7443,8080",
          "share,,7443,8080"
        ] do
      System.put_env("MJOLNIR_LAN_FILES", invalid)
      assert Config.Reader.read!(@config_file, env: :test)[:mjolnir][:lan_files] == nil
    end

    Enum.each(keys, &System.delete_env/1)
    config = Config.Reader.read!(@config_file, env: :test) |> Keyword.fetch!(:mjolnir)
    assert config[:lan_files] == nil
    assert config[:lan_files_bin] == nil
  end
end
