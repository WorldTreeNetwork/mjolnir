# Run as root on morphie: MIX_ENV=prod mix run --no-start scripts/acceptance/unikernel.exs
# Required: REFLECT_KERNEL, MJ_BINARY. Uses an isolated control plane and real KVM.
# Does not start production cleanup/reconciliation, Forge, or sidecars.
alias Mjolnir.{VM, StateStore}
root = System.fetch_env!("REFLECT_TEST_ROOT")
kernel = System.fetch_env!("REFLECT_KERNEL")
mj = System.fetch_env!("MJ_BINARY")
pin = "c917ae04e69fa83d5d3e34bb1d86be4196d904fe42e03800fbb459ca820d90d1"
socket = Path.join(root, "operator.sock")
File.mkdir_p!(root)

for {key, value} <- [
      state_dir: "#{root}/state",
      socket_dir: "#{root}/sock",
      btrfs_root: "#{root}/btrfs",
      secret_store_root: "#{root}/secrets",
      secret_escrow_dir: "#{root}/escrow",
      deploy_state_dir: "#{root}/deploy",
      operator_socket: socket,
      vmm_slice: "mju-vms.slice",
      vmm_scope_prefix: "mju-",
      tap_prefix: "mju-",
      cloud_hypervisor_bin: "/home/dorje/ch54/cloud-hypervisor",
      unikernel_kernel_prefixes: [Path.dirname(kernel)],
      gateway_routes_enabled: false,
      published_port_range: nil,
      pg_enabled: false
    ],
    do: Application.put_env(:mjolnir, key, value)

for app <- Application.spec(:mjolnir, :applications), do: Application.ensure_all_started(app)

{:ok, sup} =
  Supervisor.start_link(
    [
      Mjolnir.StateStore,
      Mjolnir.SecretStore,
      {Registry, keys: :unique, name: Mjolnir.VMRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Mjolnir.VMSupervisor},
      {Task.Supervisor, name: Mjolnir.TaskSupervisor},
      Mjolnir.EventBus,
      Mjolnir.DormantRegistry,
      Mjolnir.Mailbox,
      {Bandit,
       plug: Mjolnir.API.OperatorPipeline,
       scheme: :http,
       port: 0,
       ip: {:local, socket},
       thousand_island_options: [read_timeout: :infinity]}
    ],
    strategy: :one_for_one
  )

File.chmod!(socket, 0o600)
owner = Mjolnir.Deploy.Owner.encode(:crypto.strong_rand_bytes(32))
env = [{"MJOLNIR_OPERATOR_SOCKET", socket}]
fixtures = Path.expand("test/fixtures/reflect")
fact = File.read!("#{fixtures}/factorial-793b583.wire")
expected = File.read!("#{fixtures}/factorial-793b583.reply")
forever = File.read!("#{fixtures}/forever-793b583.wire")
budget_reply = File.read!("#{fixtures}/forever-793b583.reply")

check = fn
  true, label -> IO.puts("PASS #{label}")
  false, label -> raise "FAIL #{label}"
end

command = fn args ->
  {output, status} = System.cmd(mj, args ++ ["--owner", owner], env: env, stderr_to_stdout: true)
  # Transcript: the command as typed (owner elided) and what it printed.
  shown = if String.printable?(output), do: output, else: "<hex> " <> Base.encode16(output)

  IO.puts(
    "$ mj #{Enum.join(args, " ")} --owner <owner>\n#{String.trim_trailing(shown)}\n[exit #{status}]"
  )

  check.(status == 0, "mj #{Enum.join(args, " ")}")
  output
end

spawn_guest = fn peer_pin ->
  output = command.(["spawn", "--kind", "unikernel", "--kernel", kernel, "--peer-pin", peer_pin])
  output = Regex.replace(~r/\e\[[0-9;]*m/, output, "")
  [_, id] = Regex.run(~r/VM:\s+([A-Za-z0-9]+)/, output)
  id
end

Process.put(:guests, [])

try do
  id = spawn_guest.(pin)
  Process.put(:guests, [id])
  {:ok, vm} = VM.get(id)
  {:ok, record} = StateStore.get(id)

  IO.puts(
    "GUEST #{id} IP #{vm.net_config.guest_ip} TAP #{vm.net_config.tap_name} SCOPE #{Mjolnir.VmmScope.scope_name(id)}"
  )

  IO.puts(File.read!(vm.serial_path))

  check.(
    record.spawn_config["kind"] == "unikernel" and
      record.spawn_config["restart_policy"] == "never",
    "persisted kind and never-restart"
  )

  {info, 0} =
    System.cmd("curl", ["-sS", "--unix-socket", vm.socket_path, "http://localhost/api/v1/vm.info"])

  config = Jason.decode!(info)["config"]
  payload = config["payload"] || %{}
  IO.puts("VMINFO payload #{Jason.encode!(payload)}")

  IO.puts(
    "VMINFO cpus #{Jason.encode!(config["cpus"])} memory #{Jason.encode!(config["memory"])}"
  )

  IO.puts(
    "VMINFO disks #{Jason.encode!(config["disks"])} fs #{Jason.encode!(config["fs"])} vsock #{Jason.encode!(config["vsock"])}"
  )

  check.(
    config["fs"] in [nil, []] and config["vsock"] == nil and config["disks"] in [nil, []],
    "no rootfs, virtiofs or vsock"
  )

  words = String.split(payload["cmdline"] || "")

  check.(
    payload["kernel"] == kernel and payload["initramfs"] == nil and length(words) == 3 and
      Enum.map(words, &(&1 |> String.split("=") |> hd())) ==
        ["reflect.ip", "reflect.port", "reflect.quic_port"],
    "kernel is the Reflect ELF and the command line is three reflect.* words"
  )

  check.(
    config["cpus"]["boot_vcpus"] == 1 and config["memory"]["size"] == 512 * 1024 * 1024,
    "1 vCPU and 512 MiB"
  )

  {procs, _} = System.cmd("pgrep", ["-af", "virtiofsd|mjolnir-agent"])
  check.(not String.contains?(procs, id), "no virtiofsd or agent process for the guest")

  check.(
    vm.rootfs_path == nil and not File.exists?(Mjolnir.Reconcile.rootfs_path(id)),
    "no rootfs clone for the guest"
  )

  {route, 0} = System.cmd("ip", ["route", "get", vm.net_config.guest_ip])
  IO.puts("ROUTE #{String.trim(route)}")
  check.(String.contains?(route, vm.net_config.tap_name), "Mjolnir TAP route")
  reply = command.(["message", "--budget", "100000000", id, "#{fixtures}/factorial-793b583.wire"])
  check.(reply == expected, "QUIC factorial exact Lean reply #{Base.encode16(reply)}")
  reply = command.(["message", "--budget", "5000", id, "#{fixtures}/forever-793b583.wire"])
  check.(reply == budget_reply, "QUIC budget outcome #{Base.encode16(reply)}")
  {:ok, still_running} = VM.get(id)
  check.(still_running.state == :running, "guest running after budget")
  # Exercise the server MCP handler against the real guest and transport.
  {:ok, %{content: [%{"text" => text}]}, %{}} =
    Mjolnir.MCP.Server.handle_tool_call(
      "deliver_message",
      %{"vm_id" => id, "program_b64" => Base.encode64(fact), "budget" => 100_000_000},
      %{}
    )

  check.(
    Jason.decode!(text)["reply_b64"] == Base.encode64(expected),
    "MCP program and budget over QUIC"
  )

  first = Task.async(fn -> VM.unikernel_message(id, forever, 100_000) end)

  admitted =
    Enum.reduce_while(1..2000, false, fn _, _ ->
      if GenServer.call({:via, Registry, {Mjolnir.VMRegistry, id}}, :get_state).unikernel_busy,
        do: {:halt, true},
        else:
          (
            Process.sleep(1)
            {:cont, false}
          )
    end)

  check.(admitted, "first caller admitted")

  check.(
    VM.unikernel_message(id, fact) == {:error, :unikernel_busy},
    "second caller refused busy"
  )

  check.(
    Task.await(first, 65_000) == {:ok, 0, budget_reply},
    "first caller completes after busy refusal"
  )

  check.(VM.reboot(id) == {:error, :unikernel_restart_refused}, "live reboot refused")
  check.(VM.resume(record) == {:error, :unikernel_restart_refused}, "persisted resume refused")

  check.(
    VM.unikernel_message(id, fact) == {:ok, 0, expected},
    "guest still works after refused restart"
  )

  bad = spawn_guest.("d" <> String.slice(pin, 1..-1//1))
  Process.put(:guests, [id, bad])
  check.(VM.unikernel_message(bad, fact) == {:error, :peer_key_refused}, "wrong peer pin refused")

  check.(
    VM.unikernel_message(bad, fact) == {:error, :peer_key_refused},
    "wrong peer stays refused"
  )

  for guest <- [id, bad] do
    {:ok, before} = VM.get(guest)
    command.(["kill", guest])

    {_, tap_status} =
      System.cmd("ip", ["link", "show", before.net_config.tap_name], stderr_to_stdout: true)

    {scope, _} =
      System.cmd("systemctl", [
        "show",
        Mjolnir.VmmScope.scope_name(guest),
        "-p",
        "ActiveState",
        "--value"
      ])

    check.(
      tap_status != 0 and String.trim(scope) not in ["active", "activating"],
      "kill removed #{guest} TAP and scope"
    )
  end

  Process.put(:guests, [])
  fatal = spawn_guest.(pin)
  # This image exhausts its fixed memory on the large forever run and self-exits.
  fatal_call = Task.async(fn -> VM.unikernel_message(fatal, forever, 100_000_000) end)

  exited =
    Enum.reduce_while(1..5000, false, fn _, _ ->
      case StateStore.get(fatal) do
        {:ok, %{intent: :stopped, runtime: %{"reason" => "guest_exit"}}} ->
          {:halt, true}

        _ ->
          Process.sleep(10)
          {:cont, false}
      end
    end)

  check.(exited, "guest self-exit records stopped/guest_exit")
  {:ok, stopped} = StateStore.get(fatal)
  check.(stopped.spawn_config["owner_id"] == owner, "guest-exit record retains ownership")
  check.(VM.revive(fatal) == {:error, :unikernel_restart_refused}, "stopped guest cannot restart")

  check.(
    match?({:error, _}, Task.await(fatal_call, 65_000)),
    "in-flight call ends after guest exit"
  )

  {_, tap_status} =
    System.cmd("ip", ["link", "show", Mjolnir.Network.tap_name(fatal)], stderr_to_stdout: true)

  {scope, _} =
    System.cmd("systemctl", [
      "show",
      Mjolnir.VmmScope.scope_name(fatal),
      "-p",
      "ActiveState",
      "--value"
    ])

  check.(
    tap_status != 0 and String.trim(scope) not in ["active", "activating"],
    "self-exit removes TAP and scope"
  )

  IO.puts("ALL UNIKERNEL HARDWARE CHECKS PASSED")
after
  for vm <- VM.list(), do: VM.stop(vm.id)
  Supervisor.stop(sup)
  File.rm(socket)
end
