defmodule Mjolnir.UnikernelTest do
  use ExUnit.Case, async: false

  setup do
    old = Application.get_env(:mjolnir, :unikernel_kernel_prefixes)

    on_exit(fn ->
      if old,
        do: Application.put_env(:mjolnir, :unikernel_kernel_prefixes, old),
        else: Application.delete_env(:mjolnir, :unikernel_kernel_prefixes)
    end)

    :ok
  end

  alias Mjolnir.CloudHypervisor.Config
  alias Mjolnir.Unikernel

  test "linux is the default kind" do
    assert {:ok, opts} = Unikernel.prepare_spawn(%{})
    assert opts.kind == :linux
  end

  test "unikernel spawn rejects a kernel outside the allow-list" do
    Application.put_env(:mjolnir, :unikernel_kernel_prefixes, ["/opt/kernels"])

    assert {:error, :kernel_not_allowed} =
             Unikernel.prepare_spawn(%{
               kind: :unikernel,
               kernel: "/tmp/reflect.elf",
               peer_pin: String.duplicate("ab", 32)
             })
  end

  test "unikernel spawn rejects memory other than 512" do
    Application.put_env(:mjolnir, :unikernel_kernel_prefixes, ["/tmp"])

    assert {:error, :unikernel_memory} =
             Unikernel.prepare_spawn(%{
               kind: "unikernel",
               kernel: "/tmp/reflect.elf",
               memory_mb: 1024,
               peer_pin: String.duplicate("ab", 32)
             })
  end

  test "command line is exactly three reflect words" do
    line = Unikernel.cmdline("10.200.1.2", 20001, 30001)
    assert line == "reflect.ip=10.200.1.2 reflect.port=20001 reflect.quic_port=30001"
    assert length(String.split(line, " ")) == 3
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

  test "unikernel vm.create has no filesystem and no vsock" do
    payload =
      Config.vm_create_payload(
        %Config{
          vm_id: "vm-1",
          kernel_path: "/tmp/reflect.elf",
          rootfs_path: "",
          guest_kind: :unikernel,
          boot_args: "reflect.ip=10.0.0.2 reflect.port=1 reflect.quic_port=2",
          serial_log: "/tmp/vm-1_serial.log",
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
    assert payload["payload"]["cmdline"] =~ "reflect.quic_port=2"
    refute Map.has_key?(payload, "fs")
    refute Map.has_key?(payload, "vsock")
  end
end
