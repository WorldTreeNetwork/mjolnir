defmodule Mjolnir.UnikernelTest do
  use ExUnit.Case, async: false

  @env_keys [
    :unikernel_kernel_prefixes,
    :unikernel_entity_name,
    :reflect_client_key,
    :reflect_entity
  ]

  setup do
    old = Map.new(@env_keys, &{&1, Application.get_env(:mjolnir, &1)})
    dir = Path.join(System.tmp_dir!(), "unikernel-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      for {key, value} <- old do
        if value,
          do: Application.put_env(:mjolnir, key, value),
          else: Application.delete_env(:mjolnir, key)
      end

      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  alias Mjolnir.CloudHypervisor.Config
  alias Mjolnir.Unikernel

  # identikey's fixture seed and the name identikey prints for it
  # (homoiconic openspec/changes/add-entity-keys/design.md, section 1).
  @seed :binary.copy(<<0x11>>, 32)
  @seed_name "6mUFfKo4KPLqjeAVqthhCZB82jgWjbo3RPJAAWdTynq1"

  defp key_text(bytes \\ @seed), do: Mjolnir.Base58.encode(bytes)
  defp name(n), do: Mjolnir.Base58.encode(:crypto.hash(:sha256, "name-#{n}"))

  defp unikernel(extra) do
    Map.merge(%{kind: :unikernel, kernel: "/tmp/reflect.elf", entity_key: key_text()}, extra)
  end

  test "linux is the default kind" do
    assert {:ok, opts} = Unikernel.prepare_spawn(%{})
    assert opts.kind == :linux
  end

  test "a linux spawn drops any entity key it was given" do
    assert {:ok, opts} = Unikernel.prepare_spawn(%{entity_key: key_text(), allow: [name(1)]})
    refute Map.has_key?(opts, :entity_key)
    refute Map.has_key?(opts, :allow)
  end

  test "unikernel spawn rejects a kernel outside the allow-list" do
    Application.put_env(:mjolnir, :unikernel_kernel_prefixes, ["/opt/kernels"])
    assert {:error, :kernel_not_allowed} = Unikernel.prepare_spawn(unikernel(%{}))
  end

  test "unikernel spawn rejects memory other than 512" do
    Application.put_env(:mjolnir, :unikernel_kernel_prefixes, ["/tmp"])

    assert {:error, :unikernel_memory} =
             Unikernel.prepare_spawn(unikernel(%{kind: "unikernel", memory_mb: 1024}))
  end

  describe "the entity key at spawn" do
    setup do
      Application.put_env(:mjolnir, :unikernel_kernel_prefixes, ["/tmp"])
      :ok
    end

    test "is required" do
      assert {:error, :entity_key_required} =
               Unikernel.prepare_spawn(Map.delete(unikernel(%{}), :entity_key))

      assert {:error, :entity_key_required} =
               Unikernel.prepare_spawn(unikernel(%{entity_key: ""}))
    end

    test "must be canonical base58 of exactly 32 bytes that are not all zero" do
      for bad <- [
            key_text(:binary.copy(<<1>>, 31)),
            key_text(:binary.copy(<<1>>, 33)),
            key_text(<<0::256>>),
            "0OIl" <> String.slice(key_text(), 4..-1//1),
            " " <> key_text(),
            Base.encode16(@seed),
            123
          ] do
        assert {:error, :entity_key_invalid} =
                 Unikernel.prepare_spawn(unikernel(%{entity_key: bad})),
               "accepted #{inspect(bad)}"
      end
    end

    test "is carried as a closure and its text is dropped" do
      assert {:ok, opts} = Unikernel.prepare_spawn(Map.put(unikernel(%{}), "peer_pin", "ab"))
      assert is_function(opts.entity_key, 0)
      assert opts.entity_key.() == @seed
      refute inspect(opts) =~ key_text()
      refute Map.has_key?(opts, "entity_key")
      refute Map.has_key?(opts, "peer_pin")
      assert opts.allow == []
    end

    test "allow holds up to seven distinct names" do
      seven = Enum.map(1..7, &name/1)
      assert {:ok, %{allow: ^seven}} = Unikernel.prepare_spawn(unikernel(%{allow: seven}))

      for bad <- [
            Enum.map(1..8, &name/1),
            [name(1), name(1)],
            ["not a name"],
            [key_text(:binary.copy(<<1>>, 31))],
            name(1)
          ] do
        assert {:error, :allow_invalid} = Unikernel.prepare_spawn(unikernel(%{allow: bad})),
               "accepted #{inspect(bad)}"
      end
    end
  end

  test "command line is exactly four reflect words, Mjolnir's name first" do
    line = Unikernel.cmdline("10.200.1.2", 20001, 30001, [name(0), name(1), name(2)])

    assert line ==
             "reflect.ip=10.200.1.2 reflect.port=20001 reflect.quic_port=30001 " <>
               "reflect.allow=#{name(0)},#{name(1)},#{name(2)}"

    assert length(String.split(line, " ")) == 4
    # A name the caller also listed is not repeated: the guest refuses a list with one twice.
    assert Unikernel.cmdline("10.0.0.2", 1, 2, [name(0), name(0)]) =~ ~r/allow=[^,]+$/
  end

  test "program over 1176 bytes is rejected before an exchange" do
    assert {:error, :program_too_large} = Unikernel.check_program(:binary.copy(<<0>>, 1177))
    assert :ok = Unikernel.check_program(:binary.copy(<<0>>, 1176))
  end

  test "budget defaults and rejects out of range" do
    assert {:ok, 100_000_000} = Unikernel.normalize_budget(nil)
    assert {:ok, 5000} = Unikernel.normalize_budget(5000)
    assert {:error, :invalid_budget} = Unikernel.normalize_budget(0)
    assert {:error, :invalid_budget} = Unikernel.normalize_budget(100_000_001)
  end

  test "a sixteen-hex id is the correlation id" do
    assert Unikernel.correlation_id("0000000000000007") == <<0, 0, 0, 0, 0, 0, 0, 7>>
    assert byte_size(Unikernel.correlation_id("turn-1")) == 8
  end

  test "readiness is the serial line" do
    assert Unikernel.ready_line?("boot\nreflect: quic 30001\n", 30001)
    refute Unikernel.ready_line?("reflect: quic 30002\n", 30001)
  end

  describe "the boot outcome on serial" do
    test "ready needs the entity line with the expected name and the QUIC line" do
      log = "reflect: entity #{@seed_name}\nreflect: ready 10.0.0.2:20001\nreflect: quic 30001\n"
      assert :ok = Unikernel.boot_outcome(log, 30001, @seed_name)
      assert :wait = Unikernel.boot_outcome("reflect: entity #{@seed_name}\n", 30001, @seed_name)
    end

    test "another name fails at once, without waiting for the QUIC line" do
      assert {:error, :entity_name_mismatch} =
               Unikernel.boot_outcome("reflect: entity #{name(1)}\n", 30001, @seed_name)
    end

    test "an image with no entity line is a mismatch" do
      assert {:error, :entity_name_mismatch} =
               Unikernel.boot_outcome("reflect: quic 30001\n", 30001, @seed_name)
    end

    test "a refused key file fails at once" do
      for line <- [
            "reflect: no entity key",
            "reflect: the entity key is not 32 bytes",
            "reflect: the entity key is all zero"
          ] do
        assert {:error, :entity_key_refused} =
                 Unikernel.boot_outcome("#{line}\n", 30001, @seed_name)
      end
    end
  end

  describe "key files" do
    test "write_private makes a 0600 file and never replaces one", %{dir: dir} do
      path = Path.join(dir, "vm.entity-key")
      assert :ok = Unikernel.write_private(path, @seed)
      assert File.read!(path) == @seed
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
      assert {:error, :eexist} = Unikernel.write_private(path, <<1::256>>)
      assert File.read!(path) == @seed
      assert File.ls!(dir) == ["vm.entity-key"]
    end

    test "the client key is made once, 0600, 32 bytes", %{dir: dir} do
      path = Path.join([dir, "state", "reflect-client.key"])
      Application.put_env(:mjolnir, :reflect_client_key, path)
      assert {:ok, ^path} = Unikernel.client_key()
      bytes = File.read!(path)
      assert byte_size(bytes) == 32
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
      assert {:ok, ^path} = Unikernel.client_key()
      assert File.read!(path) == bytes
    end

    test "a client key that is not 32 bytes, or all zero, is refused", %{dir: dir} do
      path = Path.join(dir, "reflect-client.key")
      Application.put_env(:mjolnir, :reflect_client_key, path)

      for bad <- [<<1::248>>, <<0::256>>] do
        File.write!(path, bad)
        assert {:error, :reflect_client_key_invalid} = Unikernel.client_key()
      end
    end

    test "the client key defaults to the state directory" do
      Application.delete_env(:mjolnir, :reflect_client_key)

      assert Unikernel.client_key_path() ==
               Path.join(Application.fetch_env!(:mjolnir, :state_dir), "reflect-client.key")
    end
  end

  describe "entity names" do
    test "come from the override, and must be a canonical 32-byte name", %{dir: dir} do
      path = Path.join(dir, "k")
      Application.put_env(:mjolnir, :unikernel_entity_name, fn ^path -> {:ok, @seed_name} end)
      assert {:ok, @seed_name} = Unikernel.entity_name(path)

      Application.put_env(:mjolnir, :unikernel_entity_name, fn _ -> {:ok, "nope"} end)
      assert {:error, :entity_name_failed} = Unikernel.entity_name(path)
    end

    test "a missing tool is named", %{dir: dir} do
      Application.delete_env(:mjolnir, :unikernel_entity_name)
      Application.put_env(:mjolnir, :reflect_entity, Path.join(dir, "absent"))
      assert {:error, :reflect_entity_missing} = Unikernel.entity_name(Path.join(dir, "k"))
    end

    test "the tool's output is trimmed and checked", %{dir: dir} do
      bin = Path.join(dir, "entity")
      File.write!(bin, "#!/bin/sh\n[ \"$1\" = name ] && echo #{@seed_name}\n")
      File.chmod!(bin, 0o755)
      Application.delete_env(:mjolnir, :unikernel_entity_name)
      Application.put_env(:mjolnir, :reflect_entity, bin)
      assert {:ok, @seed_name} = Unikernel.entity_name(Path.join(dir, "k"))
    end
  end

  test "unikernel vm.create has no filesystem and no vsock, and its key is the initramfs" do
    payload =
      Config.vm_create_payload(
        %Config{
          vm_id: "vm-1",
          kernel_path: "/tmp/reflect.elf",
          rootfs_path: "",
          guest_kind: :unikernel,
          boot_args: Unikernel.cmdline("10.0.0.2", 1, 2, [name(0)]),
          serial_log: "/tmp/vm-1_serial.log",
          initramfs_path: "/tmp/vm-1.entity-key",
          network_interface: %{
            tap_name: "mj-1",
            guest_mac: "02:00:00:00:00:01",
            guest_ip: "10.0.0.2"
          }
        },
        nil
      )

    assert payload["cpus"] == %{"boot_vcpus" => 1, "max_vcpus" => 1}
    assert payload["memory"]["size"] == 512 * 1024 * 1024
    assert payload["payload"]["cmdline"] =~ "reflect.quic_port=2 reflect.allow=#{name(0)}"
    assert payload["payload"]["initramfs"] == "/tmp/vm-1.entity-key"
    refute Map.has_key?(payload, "fs")
    refute Map.has_key?(payload, "vsock")
  end

  describe "a unikernel boot" do
    setup %{dir: dir} do
      Application.put_env(:mjolnir, :unikernel_kernel_prefixes, ["/tmp"])
      Application.put_env(:mjolnir, :reflect_client_key, Path.join(dir, "reflect-client.key"))
      :ok
    end

    test "refuses before a process starts when this host cannot name its client key" do
      Application.put_env(:mjolnir, :unikernel_entity_name, fn _ ->
        {:error, :entity_name_failed}
      end)

      assert {:error, :entity_name_failed} = Mjolnir.VM.spawn(unikernel(%{}))
    end

    test "gives the key as a 0600 file and removes it when the boot fails" do
      parent = self()

      Application.put_env(:mjolnir, :unikernel_entity_name, fn path ->
        if String.ends_with?(path, ".entity-key") do
          send(parent, {:key_file, path, File.read!(path), File.stat!(path).mode})
          {:error, :entity_name_failed}
        else
          {:ok, @seed_name}
        end
      end)

      # The boot fails in the VM's first continue, which can end the process
      # before the spawn's await_boot call is served: either outcome is a failure.
      result =
        try do
          Mjolnir.VM.spawn(unikernel(%{}))
        catch
          :exit, _ -> :exited
        end

      assert result in [{:error, :entity_name_failed}, :exited]
      assert_receive {:key_file, path, @seed, mode}
      assert Bitwise.band(mode, 0o777) == 0o600
      assert String.ends_with?(path, ".entity-key")

      assert Path.dirname(path) ==
               Path.expand(Application.fetch_env!(:mjolnir, :socket_dir))

      refute File.exists?(path)
    end
  end
end
