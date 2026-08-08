defmodule Mjolnir.Deploy.DiagnosticsTest do
  # mjolnir-7jb. A failed build step used to leave nothing behind: the ephemeral
  # VM is discarded in run_build's `after`, taking the serial console — the only
  # place the guest KERNEL speaks — with it. An OOM-killed bundler and a
  # genuinely broken command both arrived as {:vsock_unavailable, ...}, so
  # diagnosis meant guessing, at ~8 minutes per guess.
  use ExUnit.Case, async: true

  alias Mjolnir.Deploy.Diagnostics

  # A serial log as it actually appears: systemd's ANSI progress redraw is the
  # overwhelming majority of the bytes, which is why a naive grep is useless.
  defp systemd_noise(n) do
    1..n
    |> Enum.map_join("\n", fn i ->
      "\e[K\e[[0;31m*\e[0;1;31m*\e[0m] Job dev-ttyS0.device/start running (#{i}s / 1min 30s)"
    end)
  end

  describe "highlights/1 — finding the cause in the noise" do
    test "surfaces an OOM kill buried in systemd chatter" do
      log =
        systemd_noise(200) <>
          "\n[  312.44] Out of memory: Killed process 412 (bun) total-vm:2891234kB\n" <>
          systemd_noise(50)

      # The kernel timestamp prefix is deliberately kept — it locates the death
      # in the boot timeline.
      assert [line] = Diagnostics.highlights(log)
      assert line =~ "Out of memory: Killed process 412 (bun)"
      assert line =~ "[  312.44]"
    end

    test "surfaces a full disk" do
      log = systemd_noise(10) <> "\nEXT4-fs (vda): No space left on device\n"
      assert [line] = Diagnostics.highlights(log)
      assert line =~ "No space left on device"
    end

    test "surfaces a kernel panic and a segfault" do
      log = "Kernel panic - not syncing: Attempted to kill init!\nbun[412]: segfault at 0 ip 0000"
      assert length(Diagnostics.highlights(log)) == 2
    end

    test "strips ANSI so the line is readable, not escape soup" do
      log = "\e[0;1;31m[  99.9] Out of memory: Killed process 7 (node)\e[0m"
      assert [line] = Diagnostics.highlights(log)
      refute line =~ "\e["
      assert line =~ "Killed process 7 (node)"
    end

    test "returns [] for a clean log — itself a useful signal" do
      # No kernel complaint means the guest did NOT die of memory/disk/panic,
      # which redirects the investigation rather than leaving it open.
      assert Diagnostics.highlights(systemd_noise(500)) == []
    end

    test "does not fire on ordinary boot chatter" do
      log = """
      [  OK  ] Reached target multi-user.target - Multi-User System.
      [  OK  ] Started mjolnir-agent.service - Mjolnir Guest Agent.
               Starting systemd-update-utmp-runlevel...
      """

      assert Diagnostics.highlights(log) == []
    end

    test "deduplicates a repeated splat and keeps the tail bounded" do
      log = String.duplicate("Out of memory: Killed process 412 (bun)\n", 300)
      assert Diagnostics.highlights(log) == ["Out of memory: Killed process 412 (bun)"]
    end

    test "handles an empty or binary-garbage log without raising" do
      assert Diagnostics.highlights("") == []
      assert is_list(Diagnostics.highlights("\x00\x01\x02 partial"))
    end
  end

  describe "capture/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "diag-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "sockets"))

      prev_socket = Application.get_env(:mjolnir, :socket_dir)
      prev_state = Application.get_env(:mjolnir, :deploy_state_dir)
      Application.put_env(:mjolnir, :socket_dir, Path.join(dir, "sockets"))
      Application.put_env(:mjolnir, :deploy_state_dir, Path.join(dir, "registry"))

      on_exit(fn ->
        if prev_socket,
          do: Application.put_env(:mjolnir, :socket_dir, prev_socket),
          else: Application.delete_env(:mjolnir, :socket_dir)

        if prev_state,
          do: Application.put_env(:mjolnir, :deploy_state_dir, prev_state),
          else: Application.delete_env(:mjolnir, :deploy_state_dir)

        File.rm_rf(dir)
      end)

      %{dir: dir}
    end

    test "preserves the serial log and extracts the cause", %{dir: dir} do
      vm = "abcd1234-0000-0000-0000-000000000000"

      File.write!(
        Diagnostics.serial_log_path(vm),
        systemd_noise(20) <> "\nOut of memory: Killed process 412 (bun)\n"
      )

      assert {:ok, capture} = Diagnostics.capture(vm, command: "bun run build", reason: :boom)

      assert capture.highlights == ["Out of memory: Killed process 412 (bun)"]
      assert File.exists?(Path.join(capture.dir, "serial.log"))
      # Sibling of registry/, not nested inside it — the registry dir is scanned
      # on boot and is not a dumping ground.
      assert String.starts_with?(capture.dir, Path.join(dir, "failures"))
      refute String.contains?(capture.dir, "registry")

      ctx = capture.dir |> Path.join("context.json") |> File.read!() |> Jason.decode!()
      assert ctx["vm_id"] == vm
      assert ctx["context"]["command"] =~ "bun run build"
      assert ctx["highlights"] == ["Out of memory: Killed process 412 (bun)"]
    end

    test "succeeds even when there is no serial log at all" do
      # The VM may have died before CH wrote anything. Capture must still record
      # the context rather than raising into the build's failure path.
      assert {:ok, capture} = Diagnostics.capture("no-such-vm", command: "x", reason: :y)
      assert capture.highlights == []
      assert File.exists?(Path.join(capture.dir, "context.json"))
      refute File.exists?(Path.join(capture.dir, "serial.log"))
    end

    test "summarize/1 leads with the cause, and says so when there is none" do
      assert Diagnostics.summarize(%{dir: "/d", highlights: ["Out of memory: Killed process 1"]}) =~
               "Out of memory"

      assert Diagnostics.summarize(%{dir: "/d", highlights: []}) =~ "no kernel-level cause"
    end
  end
end
