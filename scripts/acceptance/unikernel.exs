# Run as root on morphie: MIX_ENV=prod mix run --no-start scripts/acceptance/unikernel.exs
# Required: REFLECT_KERNEL (a reflect-net.elf built at homoiconic 3122521 or
# later), REFLECT_QUIC_CLIENT and REFLECT_OLD_CLIENT (that build's
# out-net/quic-client and out-net/quic-client-e9a4c86), MJ_BINARY, and
# priv/reflect-quic-client and priv/reflect-entity (scripts/build-reflect-quic.sh).
# Uses an isolated control plane and real KVM.
# Does not start production cleanup/reconciliation, Forge, or sidecars.
# Entity keys are made per run and never printed.
alias Mjolnir.{VM, StateStore, Unikernel}
alias Mjolnir.Unikernel.Exchange
root = System.fetch_env!("REFLECT_TEST_ROOT")
kernel = System.fetch_env!("REFLECT_KERNEL")
mj = System.fetch_env!("MJ_BINARY")
quic_client = System.fetch_env!("REFLECT_QUIC_CLIENT")
old_client = System.fetch_env!("REFLECT_OLD_CLIENT")
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
deep = File.read!("#{fixtures}/deep-3122521.wire")
space_reply = File.read!("#{fixtures}/deep-3122521.reply")
true = space_reply == <<0x81, 7>>

check = fn
  true, label -> IO.puts("PASS #{label}")
  false, label -> raise "FAIL #{label}"
end

err_file = Path.join(root, "mj.stderr")

# mj with stdout and stderr kept apart: stdout is the reply bytes only.
run_mj = fn args ->
  {output, status} =
    System.cmd(
      "sh",
      ["-c", "exec \"$0\" \"$@\" 2>\"$MJ_ERR\"", mj | args ++ ["--owner", owner]],
      env: [{"MJ_ERR", err_file} | env]
    )

  err = File.read!(err_file)
  # Transcript: the command as typed (owner elided) and what it printed.
  shown = if String.printable?(output), do: output, else: "<hex> " <> Base.encode16(output)

  IO.puts(
    "$ mj #{Enum.join(args, " ")} --owner <owner>\n#{String.trim_trailing(shown)}\n" <>
      "#{if err != "", do: "[stderr] " <> String.trim_trailing(err) <> "\n", else: ""}[exit #{status}]"
  )

  {output, err, status}
end

command_err = fn args ->
  {output, err, status} = run_mj.(args)
  check.(status == 0, "mj #{Enum.join(args, " ")}")
  {output, err}
end

command = fn args ->
  {output, err} = command_err.(args)
  output <> err
end

# A capture of a TAP's UDP (tcpdump -w), and its datagrams read back.
capture = fn tap, file ->
  port =
    Port.open(
      {:spawn_executable, System.find_executable("tcpdump")},
      [:binary, :stderr_to_stdout, args: ["-i", tap, "-U", "-n", "-w", file, "udp"]]
    )

  {:os_pid, pid} = Port.info(port, :os_pid)
  Process.sleep(500)
  {port, pid}
end

stop_capture = fn {port, pid} ->
  Process.sleep(300)
  System.cmd("kill", ["-INT", Integer.to_string(pid)])
  Process.sleep(500)
  if Port.info(port), do: Port.close(port)
end

ip4 = fn <<a, b, c, d>> -> "#{a}.#{b}.#{c}.#{d}" end

# Each UDP datagram on an Ethernet capture: time (ms), addresses, ports, and
# the first byte of its payload (a QUIC long header's type is in it).
datagrams = fn file ->
  <<_::binary-size(20), link::little-32, rest::binary>> = File.read!(file)
  1 = link

  Stream.unfold(rest, fn
    <<sec::little-32, usec::little-32, len::little-32, _::little-32, pkt::binary-size(len),
      more::binary>> ->
      {{sec * 1000 + div(usec, 1000), pkt}, more}

    _ ->
      nil
  end)
  |> Enum.flat_map(fn
    {t,
     <<_::binary-size(12), 0x08, 0x00, 4::4, ihl::4, _::binary-size(8), 17, _::16,
       src::binary-size(4), dst::binary-size(4), rest::binary>>} ->
      <<_::binary-size(^ihl * 4 - 20), sport::16, dport::16, _::32, first, _::binary>> = rest
      [%{t: t, src: ip4.(src), sport: sport, dst: ip4.(dst), dport: dport, first: first}]

    _ ->
      []
  end)
end

retry? = fn d -> Bitwise.band(d.first, 0xF0) == 0xF0 end

# Milliseconds a function takes, and what it returned.
timed = fn fun ->
  {us, result} = :timer.tc(fun)
  {div(us, 1000), result}
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
    payload["kernel"] == kernel and payload["initramfs"] == key_file and length(words) == 5 and
      Enum.map(words, &(&1 |> String.split("=") |> hd())) ==
        ["reflect.ip", "reflect.port", "reflect.quic_port", "reflect.allow", "reflect.space"] and
      Enum.at(words, 3) == "reflect.allow=#{client_name},#{name3}" and
      List.last(words) == "reflect.space=4000000",
    "kernel is the Reflect ELF, the key file is the initramfs, and the command line is five reflect.* words allowing Mjolnir then entity 3, with the default space"
  )

  check.(record.spawn_config["space"] == 4_000_000, "the default space is recorded")

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

  {reply, err} =
    command_err.(["message", "--budget", "100000000", id, "#{fixtures}/factorial-793b583.wire"])

  check.(
    reply == expected and err == "",
    "QUIC factorial with Mjolnir's client key, exact Lean reply #{Base.encode16(reply)}, no outcome line"
  )

  {reply, err} =
    command_err.(["message", "--budget", "5000", id, "#{fixtures}/forever-793b583.wire"])

  check.(
    reply == budget_reply and String.trim(err) == "mj: outcome budget",
    "QUIC budget outcome #{Base.encode16(reply)}, stderr names it"
  )

  # A run that passes its space: 81 07, a program outcome, and the guest goes on.
  {reply, err} =
    command_err.(["message", "--budget", "100000000", id, "#{fixtures}/deep-3122521.wire"])

  check.(
    reply == space_reply and String.trim(err) == "mj: outcome space",
    "QUIC space outcome #{Base.encode16(reply)}, stderr names it"
  )

  {json, _} =
    command_err.([
      "message",
      "--json",
      "--budget",
      "100000000",
      id,
      "#{fixtures}/deep-3122521.wire"
    ])

  body = Jason.decode!(json)

  check.(
    body["outcome"] == "space" and body["transport_status"] == 0 and
      body["reply_b64"] == Base.encode64(space_reply),
    "HTTP body: outcome space, transport status 0"
  )

  {:ok, still_running} = VM.get(id)
  check.(still_running.state == :running, "guest running after its space reply")

  check.(
    VM.unikernel_message(id, fact) == {:ok, 0, expected},
    "the guest answers factorial after its space reply, in the same boot"
  )

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
    Jason.decode!(text)["reply_b64"] == Base.encode64(expected) and
      Jason.decode!(text)["outcome"] == "value",
    "MCP program and budget over QUIC, outcome value"
  )

  {:ok, %{content: [%{"text" => text}]}, %{}} =
    Mjolnir.MCP.Server.handle_tool_call(
      "deliver_message",
      %{"vm_id" => id, "program_b64" => Base.encode64(deep), "budget" => 100_000_000},
      %{}
    )

  check.(Jason.decode!(text)["outcome"] == "space", "MCP outcome space")

  # ── The first-flight pool full: Mjolnir's client must answer a Retry. ──
  # A second address of this host floods the guest with new first flights
  # (homoiconic quic-client `flood`, key on no list), as check-quic.sh does.
  # It is on `lo`, not the TAP: an address on the TAP would become the
  # source of every datagram routed to the guest, Mjolnir's client too. It is
  # outside 10/8 (TEST-NET-2) so the kernel keeps choosing the host's own
  # address for Mjolnir's client; the check below confirms it. The flooder
  # binds it; the guest's replies reach it by proxy ARP.
  other_ip = "198.51.100.254"
  tap = vm.net_config.tap_name
  {_, 0} = System.cmd("ip", ["addr", "add", "#{other_ip}/32", "dev", "lo"])
  Process.put(:other_ip, other_ip)
  empty = Path.join(root, "kept-empty.bin")
  File.write!(empty, "")
  qport = Integer.to_string(vm.config.quic_port)
  fact_path = "#{fixtures}/factorial-793b583.wire"

  flood =
    Task.async(fn ->
      System.cmd(
        quic_client,
        [
          vm.net_config.guest_ip,
          qport,
          "1",
          fact_path,
          key2,
          name1,
          "flood",
          other_ip,
          "12",
          "4000",
          empty
        ],
        stderr_to_stdout: true
      )
    end)

  flood_pcap = Path.join(root, "flood.pcap")
  dump = capture.(tap, flood_pcap)
  Process.sleep(1000)

  for i <- 1..5 do
    {ms, result} = timed.(fn -> VM.unikernel_message(id, fact) end)
    IO.puts("     Mjolnir's client #{i} served in #{ms} ms under the flood")

    check.(
      result == {:ok, 0, expected} and ms < 1000,
      "served within a second under the flood (#{i})"
    )
  end

  stop_capture.(dump)
  # Mjolnir's client answered a Retry: the guest sent Retries to Mjolnir's
  # own address (not the flooding one), and Mjolnir's ports then carried on.
  from_guest =
    datagrams.(flood_pcap)
    |> Enum.filter(&(&1.src == vm.net_config.guest_ip and &1.dst != other_ip))

  check.(from_guest != [], "Mjolnir's client used an address other than the flooding one")
  mj_retries = Enum.filter(from_guest, retry?)
  mj_ports = mj_retries |> Enum.map(& &1.dport) |> Enum.uniq()

  answered =
    Enum.count(mj_ports, fn port ->
      Enum.any?(from_guest, &(&1.dport == port and not retry?.(&1)))
    end)

  IO.puts(
    "     capture: #{length(mj_retries)} Retries to Mjolnir's address on #{length(mj_ports)} client ports; #{answered} of those ports then served"
  )

  check.(
    mj_retries != [] and answered == length(mj_ports),
    "Mjolnir's client was sent a Retry under the flood and was served after it (TAP capture)"
  )

  # Control: the e9a4c86 client, which drops a Retry, with entity 3's key
  # (on this guest's allow list). It can only take a first-flight slot the
  # flood leaves free, so it is not served within 1.5 s (it may be later).
  {ms, {_, old_status}} =
    timed.(fn ->
      System.cmd(
        "timeout",
        ["4", old_client, vm.net_config.guest_ip, qport, "100000000", fact_path, key3, name1],
        stderr_to_stdout: true
      )
    end)

  IO.puts("     the e9a4c86 client: exit #{old_status} after #{ms} ms under the flood")

  check.(
    old_status == 124 or ms >= 1500,
    "the client that ignores a Retry is not served within 1.5 s under the flood (control)"
  )

  {flood_out, flood_status} = Task.await(flood, 30_000)
  IO.puts("     #{String.trim(flood_out)}")
  [_, retries] = Regex.run(~r/heard (\d+) Retries/, flood_out)

  check.(
    flood_status == 0 and String.to_integer(retries) > 0,
    "the flooding address heard #{retries} Retries: the first-flight pool was full"
  )

  {_, 0} = System.cmd("ip", ["addr", "del", "#{other_ip}/32", "dev", "lo"])
  Process.delete(:other_ip)

  # Four stalled handshakes (key on no list) hold the first-flight pool.
  Process.sleep(3000)

  stalls =
    for _ <- 1..4 do
      t =
        Task.async(fn ->
          System.cmd(
            quic_client,
            [vm.net_config.guest_ip, qport, "1", fact_path, key2, name1, "stall"],
            stderr_to_stdout: true
          )
        end)

      Process.sleep(50)
      t
    end

  Process.sleep(300)
  stall_pcap = Path.join(root, "stall.pcap")
  dump = capture.(tap, stall_pcap)

  old_late =
    Task.async(fn ->
      timed.(fn ->
        System.cmd(
          old_client,
          [vm.net_config.guest_ip, qport, "100000000", fact_path, key3, name1],
          stderr_to_stdout: true
        )
      end)
    end)

  {ms, result} = timed.(fn -> VM.unikernel_message(id, fact) end)
  IO.puts("     Mjolnir's client served in #{ms} ms behind four stalled handshakes")
  stop_capture.(dump)

  # What the guest sent each client port meanwhile, for the transcript.
  for {port, ds} <-
        datagrams.(stall_pcap)
        |> Enum.filter(&(&1.src == vm.net_config.guest_ip))
        |> Enum.group_by(& &1.dport) do
    first = hd(ds).t

    IO.puts(
      "     guest -> :#{port}: #{length(ds)} datagrams, #{Enum.count(ds, retry?)} Retries, " <>
        "first at #{first} ms, last #{List.last(ds).t - first} ms later"
    )
  end

  check.(
    result == {:ok, 0, expected} and ms < 1000,
    "served within a second behind stalled handshakes"
  )

  {old_ms, {_, old_status}} = Task.await(old_late, 30_000)
  IO.puts("     the e9a4c86 client: exit #{old_status} after #{old_ms} ms")

  check.(
    old_status == 0 and old_ms >= 1500 and old_ms <= 6000,
    "the client that ignores a Retry waits for the 2 s cap (control)"
  )

  for t <- stalls, do: {_, 0} = Task.await(t, 30_000)

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

  {_, err, status} =
    run_mj.([
      "spawn",
      "--kind",
      "unikernel",
      "--kernel",
      kernel,
      "--entity-key-file",
      key2,
      "--space",
      "0"
    ])

  check.(status != 0 and err =~ "invalid_space", "space 0 is refused: invalid_space")

  {second, entity2} = spawn_guest.(key2, ["--space", "100000"])
  Process.put(:guests, [id, second])
  check.(entity2 == name2 and entity2 != entity, "two keys, two guest names")
  {:ok, second_vm} = VM.get(second)
  {:ok, second_record} = StateStore.get(second)
  {info_json, _} = command_err.(["info", "--json", second])

  check.(
    String.ends_with?(second_vm.config.boot_args, " reflect.space=100000") and
      second_record.spawn_config["space"] == 100_000 and
      Jason.decode!(info_json)["space"] == 100_000,
    "a space given at spawn is on the command line, recorded, and in mj info"
  )

  check.(
    VM.unikernel_message(second, deep, 100_000_000) == {:ok, 0, space_reply},
    "the second guest, with space 100000, answers deep with 81 07"
  )

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
  # The first key again, on a new guest: the same entity, the same name. The
  # operator raises the host's maximum and this guest's space limit is
  # undone, so deep exhausts the guest's memory and it powers itself off
  # (homoiconic unikernel-net, "The limit undone").
  undone = 18_446_744_073_709_551_615
  Application.put_env(:mjolnir, :unikernel_space_max, undone)
  {fatal, fatal_entity} = spawn_guest.(key1, ["--space", Integer.to_string(undone)])
  Application.delete_env(:mjolnir, :unikernel_space_max)
  check.(fatal_entity == name1, "the same key spawned again has the same name")
  fatal_call = Task.async(fn -> VM.unikernel_message(fatal, deep, 100_000_000) end)

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
    stopped.spawn_config["space"] == undone and
      String.contains?(
        File.read!(
          Path.join(Application.fetch_env!(:mjolnir, :socket_dir), "#{fatal}_serial.log")
        ),
        "INTERNAL PANIC: out of memory"
      ),
    "the guest with its space undone ran out of memory and said so on serial"
  )

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
  if ip = Process.get(:other_ip), do: System.cmd("ip", ["addr", "del", "#{ip}/32", "dev", "lo"])
  for vm <- VM.list(), do: VM.stop(vm.id)
  Supervisor.stop(sup)
  File.rm(socket)
end
