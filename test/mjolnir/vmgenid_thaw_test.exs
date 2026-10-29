defmodule Mjolnir.VmgenidThawTest do
  use ExUnit.Case, async: false

  alias Mjolnir.{BTRFS, MemorySnapshot, VM}
  alias Mjolnir.Thaw.{Publish, Vmgenid}

  defp gate(overrides \\ %{}) do
    Map.merge(
      %{
        reseed: fn -> :ok end,
        clock: fn -> :ok end,
        enable_iroh: false,
        vmgenid_record: %{"config_vmgenid" => true, "generation_id" => "captured"},
        vmgenid: fn -> {:ok, "restored"} end
      },
      overrides
    )
  end

  setup do
    root = Path.join(System.tmp_dir!(), "vmgenid-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "@snapshots"))
    previous = Application.get_env(:mjolnir, :btrfs_root)
    Application.put_env(:mjolnir, :btrfs_root, root)

    on_exit(fn ->
      Application.put_env(:mjolnir, :btrfs_root, previous)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  defp snapshot(root, record) do
    name = "frozen"
    File.mkdir_p!(Path.join([root, "@snapshots", name]))
    File.mkdir_p!(MemorySnapshot.memory_dir(name))
    File.write!(Path.join(MemorySnapshot.memory_dir(name), "state.json"), "captured RAM")

    File.write!(
      Path.join([root, "@snapshots", "#{name}.json"]),
      Jason.encode!(%{
        name: name,
        source_vm_id: "vmgenid-source",
        vmgenid: record,
        restore_config: %{enable_iroh: true}
      })
    )

    name
  end

  test "changed device id passes only after reseed and clock, before Iroh" do
    parent = self()

    step = fn name, result ->
      fn ->
        send(parent, name)
        result
      end
    end

    assert {:ok, %{published: true, vmgenid: %{changed: true, generation_id: "new"}}} =
             Publish.run(
               gate(%{
                 reseed: step.(:reseed, :ok),
                 clock: step.(:clock, :ok),
                 vmgenid: step.(:generation, {:ok, "new"}),
                 enable_iroh: true,
                 iroh: step.(:iroh, %{ready: true, node_id: "abcd"})
               })
             )

    observed =
      for _ <- 1..4 do
        assert_receive event
        event
      end

    assert observed == [:reseed, :clock, :generation, :iroh]
  end

  test "unchanged, missing, and urandom-shaped observations cannot publish a VMGENID image" do
    for {observation, reason} <- [
          {{:ok, "captured"}, :vmgenid_unchanged},
          {:missing, :vmgenid_observation_missing},
          {{:ok, %{urandom: "random bytes"}}, :vmgenid_observation_missing}
        ] do
      assert {:error, ^reason} =
               Publish.run(
                 gate(%{
                   vmgenid: fn -> observation end,
                   enable_iroh: true,
                   iroh: fn -> flunk("Iroh must not run without device evidence") end
                 })
               )
    end

    assert :missing == Vmgenid.observe(nil)

    assert {:ok, "00112233445566778899aabbccddeeff"} =
             Vmgenid.interpret(%{
               "type" => "vmgenid_response",
               "ok" => true,
               "generation_id" => "00112233445566778899AABBCCDDEEFF"
             })

    assert :missing ==
             Vmgenid.interpret(%{
               "type" => "vmgenid_response",
               "ok" => true,
               "generation_id" => "not-the-device"
             })

    assert :missing == Vmgenid.interpret(%{"type" => "error", "error" => "unknown"})

    assert {:error, :vmgenid_observation_missing} =
             Publish.run(
               gate(%{
                 vmgenid_record: %{"config_vmgenid" => true, "generation_id" => nil}
               })
             )
  end

  test "two injected guest observations can hold different generation ids" do
    assert {:ok, %{vmgenid: %{generation_id: first}, published: true}} = Publish.run(gate())

    assert {:ok, %{vmgenid: %{generation_id: second}, published: false, iroh: nil}} =
             Publish.run(
               gate(%{
                 vsock_only: true,
                 enable_iroh: true,
                 vmgenid: fn -> {:ok, "second"} end,
                 iroh: fn -> flunk("second guest must not request a ticket") end
               })
             )

    assert first != second
  end

  test "asking for PTY on a second guest cannot mint a ticket" do
    state = %VM{id: "second", thaw_vsock_only: true, enable_iroh: true}

    assert {:reply, {:error, :vsock_only}, ^state} =
             VM.handle_call({:await_pty, 100}, {self(), make_ref()}, state)

    assert state.ticket == nil
  end

  test "both first and vsock-only thaw stop on failed reseed" do
    for second? <- [false, true] do
      assert {:error, :reseed_failed} =
               Publish.run(
                 gate(%{
                   vsock_only: second?,
                   reseed: fn -> {:error, :reseed_failed} end,
                   clock: fn -> flunk("clock ran before reseed") end,
                   vmgenid: fn -> flunk("device probe ran before reseed") end
                 })
               )
    end
  end

  test "legacy and unsupported images retain RAM and do not claim a generation change", %{
    root: root
  } do
    for record <- [nil, %{"config_vmgenid" => false}] do
      name = snapshot(root, record)

      assert {:ok, %{published: true, vmgenid: %{changed: false}}} =
               Publish.run(gate(%{vmgenid_record: record, vmgenid: fn -> :missing end}))

      assert File.read!(Path.join(MemorySnapshot.memory_dir(name), "state.json")) ==
               "captured RAM"

      assert {:ok, %{id: "vmgenid-source", thaw_vsock_only: false}} =
               VM.thaw(name, spawn_fun: fn opts -> {:ok, opts} end)
    end
  end

  test "captured boot capability and device id round-trip despite replacement of host image", %{
    root: root
  } do
    kernel = Path.join(root, "vmlinux")
    File.write!(kernel, "ELF" <> "IKCFG_ST" <> :zlib.gzip("CONFIG_VMGENID=y\n") <> "IKCFG_ED")
    boot_support = Vmgenid.kernel_support(kernel)
    assert boot_support == true
    record = Vmgenid.capture(%{kernel_vmgenid: boot_support}, fn _ -> {:ok, "captured"} end)
    name = snapshot(root, nil)
    assert {:ok, %{vmgenid: ^record}} = BTRFS.update_snapshot_metadata(name, %{vmgenid: record})

    File.write!(
      kernel,
      "ELF" <> "IKCFG_ST" <> :zlib.gzip("# CONFIG_VMGENID is not set\n") <> "IKCFG_ED"
    )

    assert Vmgenid.kernel_support(kernel) == false
    assert {:ok, %{metadata: %{vmgenid: ^record}}} = BTRFS.get_snapshot(name)

    assert {:error, :vmgenid_observation_missing} =
             Publish.run(
               gate(%{
                 vmgenid_record: record,
                 vmgenid: fn -> Vmgenid.observe(nil) end
               })
             )
  end

  test "a live source selects a fresh id and vsock-only mode; failed spawn leaves source registered",
       %{root: root} do
    name = snapshot(root, nil)
    {:ok, _} = Registry.register(Mjolnir.VMRegistry, "vmgenid-source", :published)
    assert {:ok, opts} = VM.thaw(name, spawn_fun: fn opts -> {:ok, opts} end)
    assert opts.id != "vmgenid-source"
    assert opts.thaw_vsock_only
    assert opts.thaw == name

    assert {:error, :second_failed} =
             VM.thaw(name,
               spawn_fun: fn opts ->
                 assert opts.id != "vmgenid-source"
                 {:error, :second_failed}
               end
             )

    assert [{pid, :published}] = Registry.lookup(Mjolnir.VMRegistry, "vmgenid-source")
    assert pid == self()
  end
end
