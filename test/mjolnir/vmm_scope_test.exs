defmodule Mjolnir.VmmScopeTest do
  use ExUnit.Case, async: true
  alias Mjolnir.{VmmScope, VirtioFS}

  test "production, test and dev use sibling slices and disjoint prefixes" do
    peers = [
      {"mjolnir-vms.slice", "mjolnir-"},
      {"mjt-vms.slice", "mjt-"},
      {"mjd-vms.slice", "mjd-"}
    ]

    for {slice, prefix} <- peers,
        do: assert(:ok == VmmScope.validate_namespace!(slice, prefix, peers))

    assert_raise ArgumentError, fn ->
      VmmScope.validate_namespace!("mjolnir-vms-test.slice", "mjt-")
    end

    assert_raise ArgumentError, fn ->
      VmmScope.validate_namespace!("other-vms.slice", "mjolnir-")
    end

    assert_raise ArgumentError, fn ->
      VmmScope.validate_namespace!("other-vms.slice", "mj-", [{"peer-vms.slice", "mj-long-"}])
    end

    assert VmmScope.scope_name("abc-123") == "mjt-abc-123.scope"
    assert_raise ArgumentError, fn -> VmmScope.scope_name("../foreign.scope") end
  end

  test "membership and stop use exact Slice property, never scope prefix" do
    refute VmmScope.member?(%{"Slice" => "mjolnir-vms.slice"}, "mjt-vms.slice")
    assert VmmScope.member?(%{"Slice" => "mjt-vms.slice"}, "mjt-vms.slice")
    parent = self()

    runner = fn "systemctl", args, _opts ->
      send(parent, args)
      if hd(args) == "show", do: {"Slice=mjt-vms.slice\nLoadState=loaded\n", 0}, else: {"", 0}
    end

    assert :ok == VmmScope.stop("abc", runner)
    assert_received ["show", "mjt-abc.scope" | _]
    assert_received ["stop", "mjt-abc.scope"]

    foreign = fn _, args, _ ->
      assert hd(args) == "show"
      {"Slice=mjolnir-vms.slice\nLoadState=loaded\n", 0}
    end

    assert {:error, :foreign_or_unclassified_scope} == VmmScope.stop("abc", foreign)
  end

  test "all virtiofs tags and cloud-hypervisor launch in a single collected scope" do
    {:ok, root} = VirtioFS.prepare(System.tmp_dir!(), "/tmp/guest-root.sock")

    {:ok, extras} =
      VirtioFS.prepare_many("/tmp", "guest", [
        %{tag: "repo", shared_dir: System.tmp_dir!()},
        %{tag: "cache", shared_dir: System.tmp_dir!(), opts: [thread_pool_size: 2]}
      ])

    daemons = [root | Enum.map(extras, &elem(&1, 1))]

    {"systemd-run", args} =
      VmmScope.launch_spec(
        "guest",
        ["cloud-hypervisor", "--api-socket", "/tmp/guest.sock"],
        daemons
      )

    assert "--scope" in args
    assert "--unit=mjt-guest.scope" in args
    assert "--slice=mjt-vms.slice" in args
    assert "--property=CollectMode=inactive-or-failed" in args
    assert Enum.count(args, &(&1 == "--scope")) == 1
    script = List.last(args)
    for tag <- ["myfs", "repo", "cache"], do: assert(script =~ "virtiofs tag: #{inspect(tag)}")
    for daemon <- daemons, do: assert(script =~ daemon.socket)
    assert script =~ "cloud-hypervisor"
    refute Enum.any?(args, &String.contains?(&1, "Restart="))
  end

  @tag timeout: 10_000
  test "wrapper exits with VMM status and kills every filesystem daemon" do
    dir = Path.join(System.tmp_dir!(), "scope-wrapper-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    python = System.find_executable("python3")

    daemons =
      for tag <- ["myfs", "repo", "cache"] do
        sock = Path.join(dir, tag <> ".sock")
        # A file simulates readiness in the sandbox; an external witness proves
        # the wrapper reaped each daemon before returning.
        code =
          "import os,time; open(#{inspect(sock <> ".pid")},'w').write(str(os.getpid())); open(#{inspect(sock)},'w').close(); time.sleep(60)"

        %{tag: tag, socket: sock, argv: [python, "-c", code]}
      end

    vmm = ["/bin/bash", "-c", "sleep 0.05; exit 7"]
    started = System.monotonic_time(:millisecond)

    assert {_, 7} =
             System.cmd(
               "/bin/bash",
               ["-c", String.replace(VmmScope.wrapper(vmm, daemons), "[[ -S ", "[[ -f ")],
               stderr_to_stdout: true
             )

    assert System.monotonic_time(:millisecond) - started < 5000

    for daemon <- daemons do
      pid = File.read!(daemon.socket <> ".pid")
      assert {_, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
      assert status != 0
    end
  end

  test "orchestrator and GenServer crashes detach; explicit stop and VMM death clean up" do
    for reason <- [:shutdown, {:shutdown, :supervisor}, :killed, {:error, :crash}],
        do: assert(VmmScope.detach?(reason))

    refute VmmScope.detach?(:normal)
    refute VmmScope.detach?({:hypervisor_exit, 1})
    assert :ok == VmmScope.detach(nil)
  end

  test "watcher is independent, has no restart policy, and persists systemd Result" do
    unit = File.read!("systemd/mjolnir-vmm-watch.service")
    refute unit =~ "Restart="
    refute unit =~ "PartOf="
    refute unit =~ "BindsTo="
    refute unit =~ "Requires=mjolnir.service"
    assert unit =~ "priv/vmm_watch.py"
    refute unit =~ "bin/mjolnir"
    refute unit =~ "eval "
    assert unit =~ "StateDirectory=mjolnir"
    source = VmmScope.watcher_source()
    assert source =~ "props.get('Slice') != slice_name"
    assert source =~ "'Result'"
    assert source =~ "'inactive', 'failed'"
    assert source =~ "os.fsync"
    refute source =~ "ExecMainStatus"
    refute source =~ "['systemctl', 'start'"
    # Check syntax without importing libsystemd or contacting live systemd.
    assert {_, 0} =
             System.cmd("python3", ["-c", "import ast,sys; ast.parse(sys.argv[1])", source],
               stderr_to_stdout: true
             )
  end

  test "witness writes active, inactive and failed Result records durably" do
    source = VmmScope.watcher_source()
    [_, rest] = String.split(source, "def persist(", parts: 2)
    [functions, _] = String.split("def persist(" <> rest, "def inspect_unit(", parts: 2)
    dir = Path.join(System.tmp_dir!(), "scope-witness-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    code = """
    import json, os, sys, time
    history = {}
    slice_name = 'mjt-vms.slice'
    record_path = sys.argv[1]
    #{functions}
    for state, result in [('active', 'success'), ('inactive', 'success'), ('failed', 'oom-kill')]:
        persist('mjt-guest.scope', state, result)
        with open(record_path) as f: record = json.load(f)['mjt-guest.scope']
        assert record['state'] == state
        assert record['result'] == result
        assert record['slice'] == slice_name
        assert not os.path.exists(record_path + '.tmp')
    """

    assert {_, 0} =
             System.cmd("python3", ["-c", code, Path.join(dir, "record.json")],
               stderr_to_stdout: true
             )
  end

  test "active scope sockets are kept and foreign units are not our ids" do
    assert VmmScope.socket_protected?("abc.sock", ["abc"])
    assert VmmScope.socket_protected?("abc_vsock", ["abc"])
    assert VmmScope.socket_protected?("abc_repo_virtiofs.sock", ["abc"])
    refute VmmScope.socket_protected?("abcd.sock", ["abc"])
    refute VmmScope.socket_protected?("other.sock", ["abc"])
    assert {:ok, "abc-123"} == VmmScope.id_from_unit("mjt-abc-123.scope", "mjt-")
    assert :error == VmmScope.id_from_unit("mjolnir-abc-123.scope", "mjt-")
  end

  test "startup sweep never ps-kills or deletes unclassified guest resources" do
    source = File.read!("lib/mjolnir/cleanup.ex")
    refute source =~ "System.cmd(\"ps\""
    refute source =~ "System.cmd(\"kill\""
    refute source =~ "File.rm("
    refute source =~ "delete_tap"
  end
end
