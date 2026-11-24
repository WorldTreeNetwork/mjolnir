# Run as root on morphie: MIX_ENV=prod mix run --no-start scripts/acceptance/unikernel.exs
# Required: REFLECT_KERNEL (a reflect-net.elf built at homoiconic e9a4c86 or
# later), MJ_BINARY, and priv/reflect-quic-client and priv/reflect-entity
# built from native/reflect_quic. Uses an isolated control plane and real KVM.
# Does not start production cleanup/reconciliation, Forge, or sidecars.
# Entity keys are made per run and never printed.
alias Mjolnir.{VM, StateStore, Unikernel}
alias Mjolnir.Unikernel.Exchange
root = System.fetch_env!("REFLECT_TEST_ROOT")
kernel = System.fetch_env!("REFLECT_KERNEL")
mj = System.fetch_env!("MJ_BINARY")
socket = Path.join(root, "operator.sock")
File.mkdir_p!(root)
keys = Path.join(root, "keys")
File.mkdir_p!(keys)
File.chmod!(keys, 0o700)

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

# An entity's key: 32 random bytes in a 0600 file. Only the path is shown.
make_key = fn label ->
  path = Path.join(keys, "#{label}.key")
  :ok = Unikernel.write_private(path, :crypto.strong_rand_bytes(32))
  path
end

key_name = fn path ->
  {:ok, name} = Unikernel.entity_name(path)
  name
end

# The key text a spawn sends, to prove it is kept nowhere.
key_text = fn path -> Mjolnir.Base58.encode(File.read!(path)) end

spawn_guest = fn key_path, extra ->
  output =
    command.(
      ["spawn", "--kind", "unikernel", "--kernel", kernel, "--entity-key-file", key_path] ++
        extra
    )

  output = Regex.replace(~r/\e\[[0-9;]*m/, output, "")
  [_, id] = Regex.run(~r/VM:\s+([A-Za-z0-9]+)/, output)
  [_, entity] = Regex.run(~r/Entity:\s+([A-Za-z0-9]+)/, output)
  {id, entity}
end

job_for = fn id, program, budget ->
  {:ok, vm} = VM.get(id)

  %{
    guest_ip: vm.net_config.guest_ip,
    quic_port: vm.config.quic_port,
    entity: vm.config.entity,
    budget: budget,
    program: program,
    correlation_id: Unikernel.correlation_id(nil)
  }
end

key1 = make_key.("entity-1")
key2 = make_key.("entity-2")
key3 = make_key.("entity-3")
name1 = key_name.(key1)
name2 = key_name.(key2)
name3 = key_name.(key3)
{:ok, client_key} = Unikernel.client_key()
client_name = key_name.(client_key)

check.(
  File.stat!(client_key).mode |> Bitwise.band(0o777) == 0o600 and
    byte_size(File.read!(client_key)) == 32,
  "Mjolnir's client key is a 0600 file of 32 bytes"
)

check.(
  length(Enum.uniq([name1, name2, name3, client_name])) == 4,
  "four keys, four names"
)

Process.put(:guests, [])

try do
  # A spawn with no entity key is refused before anything starts, by the
  # API and by VM.spawn.
  {refused, 0} =
    System.cmd("curl", [
      "-sS",
      "--unix-socket",
      socket,
      "-H",
      "X-Owner-Id: #{owner}",
      "-H",
      "Content-Type: application/json",
      "--data",
      Jason.encode!(%{kind: "unikernel", kernel: kernel}),
      "http://localhost/api/vms"
    ])

  IO.puts("SPAWN WITHOUT KEY #{refused}")
  check.(Jason.decode!(refused)["error"] == "entity_key_required", "API: entity_key_required")

  check.(
    VM.spawn(%{kind: :unikernel, kernel: kernel, owner_id: owner}) ==
      {:error, :entity_key_required},
    "VM.spawn: entity_key_required"
  )

  # The first guest also allows entity 3, which may call it directly.
  {id, entity} = spawn_guest.(key1, ["--allow", name3])
  Process.put(:guests, [id])
  {:ok, vm} = VM.get(id)
  {:ok, record} = StateStore.get(id)

  IO.puts(
    "GUEST #{id} IP #{vm.net_config.guest_ip} TAP #{vm.net_config.tap_name} SCOPE #{Mjolnir.VmmScope.scope_name(id)}"
  )

  serial = File.read!(vm.serial_path)
  IO.puts(serial)

  check.(
    record.spawn_config["kind"] == "unikernel" and
      record.spawn_config["restart_policy"] == "never",
    "persisted kind and never-restart"
  )

  check.(
    entity == name1 and vm.config.entity == name1 and record.spawn_config["entity"] == name1 and
      record.spawn_config["allow"] == [name3],
    "the guest's name is its key's name, returned and stored with allow"
  )

  check.(
    String.contains?(serial, "reflect: entity #{name1}\n"),
    "the guest printed its name on serial"
  )

  key_file = Unikernel.key_file_path(Application.fetch_env!(:mjolnir, :socket_dir), id)
  check.(not File.exists?(key_file), "the key file is gone once the guest is ready")

  stored = File.read!(Path.join(Application.fetch_env!(:mjolnir, :state_dir), "#{id}.json"))
  ch_log = Path.join(Application.fetch_env!(:mjolnir, :socket_dir), "cloud-hypervisor-#{id}.log")
  ch_log = if File.exists?(ch_log), do: File.read!(ch_log), else: ""

  check.(
    not Enum.any?([stored, serial, ch_log, inspect(vm.config), inspect(record)], fn text ->
      String.contains?(text, key_text.(key1)) or
        String.contains?(text, File.read!(key1)) or
        String.contains?(text, Base.encode16(File.read!(key1), case: :lower))
    end),
    "the key is not in the record, the serial log, the hypervisor log or the VM state"
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
    payload["kernel"] == kernel and payload["initramfs"] == key_file and length(words) == 4 and
      Enum.map(words, &(&1 |> String.split("=") |> hd())) ==
        ["reflect.ip", "reflect.port", "reflect.quic_port", "reflect.allow"] and
      List.last(words) == "reflect.allow=#{client_name},#{name3}",
    "kernel is the Reflect ELF, the key file is the initramfs, and the command line is four reflect.* words allowing Mjolnir then entity 3"
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

  check.(
    reply == expected,
    "QUIC factorial with Mjolnir's client key, exact Lean reply #{Base.encode16(reply)}"
  )

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

  {second, entity2} = spawn_guest.(key2, [])
  Process.put(:guests, [id, second])
  check.(entity2 == name2 and entity2 != entity, "two keys, two guest names")

  check.(
    VM.unikernel_message(second, fact) == {:ok, 0, expected},
    "the second guest answers Mjolnir's client key"
  )

  # Exchanges run directly, as the API cannot choose the client key or the
  # name expected. Each starts from the first guest's own job.
  job = job_for.(id, fact, 100_000_000)

  check.(
    Exchange.port(Map.put(job, :client_key, key3)) == {:ok, 0, expected},
    "a client with entity 3's key, on the guest's allow list, is answered"
  )

  check.(
    Exchange.port(Map.put(job, :client_key, key2)) == {:error, :unikernel_timeout},
    "a client key the guest does not allow gets no answer (unikernel_timeout)"
  )

  check.(
    Exchange.port(Map.put(job, :entity, name2)) == {:error, :peer_key_refused},
    "a client that expects another guest name refuses the guest (peer_key_refused)"
  )

  check.(
    VM.unikernel_message(id, fact) == {:ok, 0, expected},
    "the guest still answers Mjolnir after the refused connections"
  )

  for guest <- [id, second] do
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
  # The first key again, on a new guest: the same entity, the same name.
  {fatal, fatal_entity} = spawn_guest.(key1, [])
  check.(fatal_entity == name1, "the same key spawned again has the same name")
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

  check.(
    stopped.spawn_config["entity"] == name1 and not Map.has_key?(stopped.spawn_config, "peer_pin"),
    "guest-exit record keeps the entity name"
  )

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
