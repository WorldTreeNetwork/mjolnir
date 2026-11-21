defmodule Mjolnir.PublishedPortsTest do
  use ExUnit.Case, async: false

  alias Mjolnir.{Network, PublishedPorts}
  alias Mjolnir.StateStore.Record

  @net %{tap_name: "mjt-abcdefgh", guest_ip: "10.200.0.9"}
  def public_side, do: {:ok, {"enp3s0", "192.168.0.10"}}

  defp port(host, guest \\ nil),
    do: %{protocol: "udp", host_port: host, guest_port: guest || host}

  # Stateful fake of -C/-I/-D/-S. Never invokes iptables.
  defp runner do
    {:ok, store} = Agent.start_link(fn -> {[], []} end)

    run = fn ["-t", table, op, chain | rest] = args ->
      Agent.get_and_update(store, fn {installed, calls} ->
        spec = if op == "-I", do: tl(rest), else: rest
        key = {table, chain, spec}

        {reply, next} =
          case op do
            "-C" ->
              {{"", if(key in installed, do: 0, else: 1)}, installed}

            "-I" ->
              {{"", 0}, [key | installed]}

            "-D" ->
              {{"", 0}, List.delete(installed, key)}

            "-S" ->
              lines =
                for {^table, ^chain, spec} <- installed do
                  quoted =
                    Enum.map(spec, fn word ->
                      if String.contains?(word, "publish:"), do: ~s("#{word}"), else: word
                    end)

                  Enum.join(["-A", chain | quoted], " ")
                end

              {{Enum.join(["-P #{chain} ACCEPT" | lines], "\n"), 0}, installed}
          end

        {reply, {next, calls ++ [args]}}
      end)
    end

    {store, run}
  end

  defp installed(store), do: Agent.get(store, fn {installed, _} -> installed end)

  describe "Network.published_port_rules/6" do
    test "one UDP DNAT and two flow-scoped accepts per port, permission first" do
      rules =
        Network.published_port_rules(
          "mjt-publish:vm1",
          "enp3s0",
          "192.168.0.10",
          "mjt-abcdefgh",
          "10.200.0.9",
          [port(20_001, 4433)]
        )

      assert [
               {"filter", "FORWARD", forward},
               {"filter", "FORWARD", reply},
               {"nat", "PREROUTING", dnat}
             ] =
               rules

      assert Enum.take(dnat, 8) ==
               ["-i", "enp3s0", "-d", "192.168.0.10/32", "-p", "udp", "--dport", "20001"]

      assert Enum.take(dnat, -4) == ["-j", "DNAT", "--to-destination", "10.200.0.9:4433"]

      assert Enum.take(forward, 10) ==
               [
                 "-i",
                 "enp3s0",
                 "-o",
                 "mjt-abcdefgh",
                 "-p",
                 "udp",
                 "-d",
                 "10.200.0.9",
                 "--dport",
                 "4433"
               ]

      assert Enum.take(reply, 10) ==
               [
                 "-i",
                 "mjt-abcdefgh",
                 "-o",
                 "enp3s0",
                 "-p",
                 "udp",
                 "-s",
                 "10.200.0.9",
                 "--sport",
                 "4433"
               ]

      for spec <- [forward, reply] do
        assert ["--ctorigdst", "192.168.0.10", "--ctorigdstport", "20001"] ==
                 Enum.slice(spec, 16, 4)
      end

      assert "NEW,ESTABLISHED" in forward
      assert "REPLY" in reply
      refute "NEW,ESTABLISHED" in reply

      for {_, _, spec} <- rules do
        assert ["--comment", "mjt-publish:vm1"] ==
                 Enum.slice(spec, Enum.find_index(spec, &(&1 == "--comment")), 2)

        refute "tcp" in spec
      end
    end

    test "several ports keep every accept ahead of every DNAT" do
      rules =
        Network.published_port_rules("t", "eth0", "192.168.0.10", "tap", "10.200.0.9", [
          port(20_001),
          port(20_002, 4433)
        ])

      assert Enum.map(rules, &elem(&1, 0)) == [
               "filter",
               "filter",
               "filter",
               "filter",
               "nat",
               "nat"
             ]
    end

    test "refuses loopback, bad ports and a tag that would not survive iptables -S" do
      bad = [
        ["t", "eth0", "127.0.0.1", "tap", "10.200.0.9", [port(20_001)]],
        ["t", "eth0", "192.168.0.10", "tap", "nope", [port(20_001)]],
        ["t", "eth0", "192.168.0.10", "tap", "10.200.0.9", [port(0)]],
        ["t", "eth0", "192.168.0.10", "tap", "10.200.0.9", [port(70_000)]],
        ["t", "", "192.168.0.10", "tap", "10.200.0.9", [port(20_001)]],
        ["a tag", "eth0", "192.168.0.10", "tap", "10.200.0.9", [port(20_001)]]
      ]

      for args <- bad do
        assert_raise ArgumentError, fn -> apply(Network, :published_port_rules, args) end
      end
    end

    test "default route parsing names no interface when there is no route" do
      assert {:ok, "enp1s0"} =
               Network.parse_default_route("default via 45.76.76.1 dev enp1s0 proto static\n")

      assert {:error, :no_default_route} = Network.parse_default_route("")
    end
  end

  describe "parse/1" do
    test "accepts JSON and atom keys; guest_port defaults to host_port" do
      assert {:ok, []} = PublishedPorts.parse(nil)

      assert {:ok,
              [
                %{protocol: "udp", host_port: 20_001, guest_port: 4433},
                %{host_port: 20_002, guest_port: 20_002}
              ]} =
               PublishedPorts.parse([
                 %{"host_port" => 20_001, "guest_port" => 4433, "protocol" => "udp"},
                 %{host_port: 20_002}
               ])
    end

    test "refuses bad numbers, other protocols, duplicates and too many" do
      for entry <- [
            %{"host_port" => 0},
            %{"host_port" => 65_536},
            %{"host_port" => "20001"},
            %{"host_port" => 20_001, "guest_port" => -1},
            %{"host_port" => 20_001, "guest_port" => 1.5},
            %{"host_port" => 20_001, "protocol" => "tcp"},
            %{"guest_port" => 4433},
            "20001:4433"
          ] do
        assert {:error, {:invalid_published_port, ^entry}} = PublishedPorts.parse([entry])
      end

      assert {:error, :invalid_published_ports} = PublishedPorts.parse(%{"host_port" => 1})
      assert {:error, :invalid_published_ports} = PublishedPorts.parse("20001")

      assert {:error, {:duplicate_host_port, 20_001}} =
               PublishedPorts.parse([%{host_port: 20_001}, %{host_port: 20_001, guest_port: 9}])

      many = for n <- 1..(PublishedPorts.max_per_vm() + 1), do: %{host_port: 20_000 + n}
      assert {:error, {:too_many_published_ports, _}} = PublishedPorts.parse(many)
    end

    test "quic resolves to the unikernel's port and is refused on linux" do
      {:ok, ports} = PublishedPorts.parse([%{"host_port" => 20_001, "guest_port" => "quic"}])
      {_udp, quic} = Mjolnir.Unikernel.ports("vm-id")

      assert {:ok, [%{host_port: 20_001, guest_port: ^quic}]} =
               PublishedPorts.resolve(ports, :unikernel, "vm-id")

      assert {:error, :quic_guest_port_requires_unikernel} =
               PublishedPorts.resolve(ports, :linux, "vm-id")
    end
  end

  describe "check/2" do
    defp check(ports, overrides \\ []) do
      PublishedPorts.check(
        ports,
        Keyword.merge(
          [
            range: {20_000, 20_099},
            reserved: MapSet.new([20_050]),
            bound: MapSet.new([20_060]),
            holders: %{20_070 => "other-vm"},
            public: &__MODULE__.public_side/0
          ],
          overrides
        )
      )
    end

    test "nothing to publish is always fine, even when disabled" do
      assert :ok = PublishedPorts.check([], range: nil)
    end

    test "disabled until the operator configures a range" do
      assert Application.get_env(:mjolnir, :published_port_range) == nil
      assert {:error, :published_ports_disabled} = PublishedPorts.check([port(20_001)])
      assert {:error, :published_ports_disabled} = check([port(20_001)], range: nil)
    end

    test "permits a free port inside the range" do
      assert :ok = check([port(20_001, 4433), port(20_099)])
    end

    test "refuses a host port outside the range" do
      assert {:error, {:host_port_not_permitted, 443, 20_000, 20_099}} = check([port(443)])

      assert {:error, {:host_port_not_permitted, 20_100, _, _}} =
               check([port(20_001), port(20_100)])
    end

    test "refuses reserved ports, ports a host socket has bound, and ports of another VM" do
      assert {:error, {:host_port_reserved, 20_050}} = check([port(20_050)])
      assert {:error, {:host_port_bound_by_host, 20_060}} = check([port(20_060)])
      assert {:error, {:host_port_published, 20_070, "other-vm"}} = check([port(20_070)])
    end

    test "refuses when the public interface has no address" do
      assert {:error, :published_port_interface_unavailable} =
               check([port(20_001)],
                 public: fn -> {:error, :published_port_interface_unavailable} end
               )
    end

    test "the default reserved set covers what the host binds" do
      reserved = PublishedPorts.reserved()

      for p <- [53, 443, 4000, 5432, 6379, 7222, Application.get_env(:mjolnir, :api_port, 4000)] do
        assert p in reserved
      end
    end

    test "reads bound UDP ports from /proc/net/udp" do
      text = """
         sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops
       1234: 00000000:0035 00000000:0000 07 00000000:00000000 00:00000000 00000000     0        0 1 2 0 0
       2345: 0100007F:4E21 00000000:0000 07 00000000:00000000 00:00000000 00000000     0        0 1 2 0 0
       3456: 00000000000000000000000000000000:14E9 00000000000000000000000000000000:0000 07 00000000:00000000 00:00000000 00000000 0 0 1 2 0 0
      """

      assert Enum.sort(PublishedPorts.parse_proc_udp(text)) == [53, 5353, 20_001]
    end

    test "range parsing never widens on a bad value" do
      assert PublishedPorts.parse_range("20000-20099") == {20_000, 20_099}
      assert PublishedPorts.parse_range("4433") == {4433, 4433}

      for bad <- ["", "20099-20000", "0-10", "1-70000", "a-b", "1-2-3", nil] do
        assert PublishedPorts.parse_range(bad) == nil
      end
    end
  end

  describe "holders/0 and claim/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "pp-state-#{System.unique_integer([:positive])}")
      prev = Application.get_env(:mjolnir, :state_dir)
      File.mkdir_p!(dir)
      Application.put_env(:mjolnir, :state_dir, dir)
      Mjolnir.StateStore.reload()

      on_exit(fn ->
        if prev,
          do: Application.put_env(:mjolnir, :state_dir, prev),
          else: Application.delete_env(:mjolnir, :state_dir)

        File.rm_rf(dir)
        Mjolnir.StateStore.reload()
      end)

      :ok
    end

    test "a stored VM holds its ports whatever its intent; old records hold none" do
      :ok =
        Mjolnir.StateStore.put(
          Record.new("held-vm", :failed,
            spawn_config: %{"published_ports" => [%{"host_port" => 20_011, "guest_port" => 4433}]}
          )
        )

      :ok = Mjolnir.StateStore.put(Record.new("old-vm", :running, spawn_config: %{"vcpus" => 1}))

      assert %{20_011 => "held-vm"} = holders = PublishedPorts.holders()
      refute "old-vm" in Map.values(holders)

      assert {:error, {:host_port_published, 20_011, "held-vm"}} =
               PublishedPorts.check([port(20_011)],
                 range: {20_000, 20_099},
                 reserved: MapSet.new(),
                 bound: MapSet.new(),
                 public: &__MODULE__.public_side/0
               )
    end

    test "the claim is atomic and is released when the holder exits" do
      test = self()

      holder =
        spawn(fn ->
          send(test, {:claimed, PublishedPorts.claim("vm-a", [port(20_021), port(20_022)])})
          Process.sleep(:infinity)
        end)

      assert_receive {:claimed, :ok}
      assert PublishedPorts.holders()[20_021] == "vm-a"

      assert {:error, {:host_port_published, 20_022, "vm-a"}} =
               PublishedPorts.claim("vm-b", [port(20_023), port(20_022)])

      # A refused claim keeps nothing.
      refute Map.has_key?(PublishedPorts.holders(), 20_023)

      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}
      Process.sleep(50)

      assert :ok = PublishedPorts.claim("vm-b", [port(20_022)])
      assert :ok = PublishedPorts.claim("vm-b", [port(20_022)])
    end
  end

  describe "rules on the host" do
    test "install is idempotent, remove finds rules by tag alone" do
      {store, run} = runner()
      ports = [port(20_001, 4433), port(20_002)]

      assert {:ok, owned} =
               PublishedPorts.install("vm1", ports, @net,
                 run: run,
                 public: &__MODULE__.public_side/0
               )

      assert length(owned) == 6
      assert {:ok, ^owned} = PublishedPorts.sync(owned, owned, run)
      assert length(installed(store)) == 6

      assert {:ok, other} =
               PublishedPorts.install("vm2", [port(20_003)], @net,
                 run: run,
                 public: &__MODULE__.public_side/0
               )

      # Nothing but the id: the address the rules were written with is not needed.
      assert :ok = PublishedPorts.remove("vm1", run)
      assert Enum.sort(installed(store)) == Enum.sort(other)

      assert :ok = PublishedPorts.remove("vm1", run)
      assert :ok = PublishedPorts.remove("vm2", run)
      assert installed(store) == []
    end

    test "an address change replaces the rules, old ones first" do
      {store, run} = runner()
      ports = [port(20_001, 4433)]

      {:ok, owned} =
        PublishedPorts.install("vm1", ports, @net, run: run, public: &__MODULE__.public_side/0)

      moved =
        PublishedPorts.desired("vm1", ports, @net, fn -> {:ok, {"enp3s0", "192.168.0.77"}} end)

      assert {:ok, new} = PublishedPorts.sync(owned, moved, run)
      assert Enum.sort(installed(store)) == Enum.sort(new)
      assert Enum.any?(new, fn {_, _, spec} -> "192.168.0.77/32" in spec end)

      # The address is gone: the rules go, and no other address stands in.
      gone = PublishedPorts.desired("vm1", ports, @net, fn -> {:error, :none} end)
      assert gone == []
      assert {:ok, []} = PublishedPorts.sync(new, gone, run)
      assert installed(store) == []
    end

    test "install without a public address is an error and writes nothing" do
      {store, run} = runner()

      assert {:error, :published_port_interface_unavailable} =
               PublishedPorts.install("vm1", [port(20_001)], @net,
                 run: run,
                 public: fn -> {:error, :none} end
               )

      assert installed(store) == []

      assert {:ok, []} =
               PublishedPorts.install("vm1", [], @net,
                 run: run,
                 public: &__MODULE__.public_side/0
               )
    end

    test "a failed install leaves no partial rules" do
      {store, run} = runner()

      failing = fn
        ["-t", "nat", "-I" | _] -> {"iptables: No chain/target/match by that name.", 1}
        args -> run.(args)
      end

      assert {:error, {:published_port_rules_failed, _}} =
               PublishedPorts.install("vm1", [port(20_001)], @net,
                 run: failing,
                 public: &__MODULE__.public_side/0
               )

      assert installed(store) == []
    end

    test "sweep removes the rules of VMs that are gone and keeps the rest" do
      {store, run} = runner()

      {:ok, _} =
        PublishedPorts.install("gone", [port(20_001)], @net,
          run: run,
          public: &__MODULE__.public_side/0
        )

      {:ok, kept} =
        PublishedPorts.install("alive", [port(20_002)], @net,
          run: run,
          public: &__MODULE__.public_side/0
        )

      # A rule of another BEAM (other tap prefix) and an untagged rule.
      foreign =
        {"nat", "PREROUTING",
         ["-p", "udp", "-m", "comment", "--comment", "mj-publish:prod", "-j", "DNAT"]}

      plain = {"filter", "FORWARD", ["-s", "10.192.0.0/10", "-j", "DROP"]}
      Agent.update(store, fn {installed, calls} -> {[foreign, plain | installed], calls} end)

      assert ["gone"] = PublishedPorts.sweep(keep: &(&1 == "alive"), run: run)
      assert Enum.sort(installed(store)) == Enum.sort([foreign, plain | kept])
      assert [] = PublishedPorts.sweep(keep: &(&1 == "alive"), run: run)
    end

    test "the default sweep keeps only ids with a :running record" do
      {store, run} = runner()
      gone = "pp-gone-#{System.unique_integer([:positive])}"
      alive = "pp-alive-#{System.unique_integer([:positive])}"
      stopped = "pp-stopped-#{System.unique_integer([:positive])}"
      :ok = Mjolnir.StateStore.put(Record.new(alive, :running))
      :ok = Mjolnir.StateStore.put(Record.new(stopped, :stopped))

      on_exit(fn ->
        Mjolnir.StateStore.delete(alive)
        Mjolnir.StateStore.delete(stopped)
      end)

      {:ok, _} =
        PublishedPorts.install(gone, [port(20_001)], @net,
          run: run,
          public: &__MODULE__.public_side/0
        )

      {:ok, _} =
        PublishedPorts.install(stopped, [port(20_002)], @net,
          run: run,
          public: &__MODULE__.public_side/0
        )

      {:ok, kept} =
        PublishedPorts.install(alive, [port(20_003)], @net,
          run: run,
          public: &__MODULE__.public_side/0
        )

      assert Enum.sort(PublishedPorts.sweep(run: run)) == Enum.sort([gone, stopped])
      assert Enum.sort(installed(store)) == Enum.sort(kept)
    end

    test "parse_tagged reads quoted and bare comments and ignores other rules" do
      quoted =
        ~s(-A PREROUTING -d 10.43.1.243/32 -i wlan0 -p udp -m udp --dport 20001 -m comment --comment "mjt-publish:AbC123" -j DNAT --to-destination 10.200.1.2:4433)

      assert {"AbC123", ["-D", "PREROUTING", "-d", "10.43.1.243/32" | rest]} =
               PublishedPorts.parse_tagged(quoted, "mjt-publish:")

      assert "mjt-publish:AbC123" in rest
      assert List.last(rest) == "10.200.1.2:4433"

      bare = "-A FORWARD -i tap -m comment --comment mjt-publish:x -j ACCEPT"
      assert {"x", ["-D", "FORWARD" | _]} = PublishedPorts.parse_tagged(bare, "mjt-publish:")

      assert nil == PublishedPorts.parse_tagged(quoted, "mj-publish:")
      assert nil == PublishedPorts.parse_tagged("-P FORWARD DROP", "mjt-publish:")

      assert nil ==
               PublishedPorts.parse_tagged(
                 "-A FORWARD -m comment --comment mjolnir-lan-files -j ACCEPT",
                 "mjt-publish:"
               )
    end
  end

  describe "spawn config" do
    defp vm(ports) do
      %Mjolnir.VM{
        id: "pp-record-vm",
        enable_iroh: false,
        secrets_mode: :none,
        restart_policy: :always,
        metadata: %{},
        config: %{
          vcpu_count: 1,
          mem_size_mib: 512,
          base_image: "ubuntu-24.04",
          guest_kind: :linux,
          published_ports: ports
        }
      }
    end

    test "published ports survive the record round trip" do
      record = Mjolnir.VM.build_running_record(vm([port(20_001, 4433)]))

      assert record.spawn_config["published_ports"] ==
               [%{"protocol" => "udp", "host_port" => 20_001, "guest_port" => 4433}]

      # Through JSON, as Reconcile reads it after a restart.
      {:ok, reread} = record |> Record.to_json() |> Record.from_json()

      assert [%{protocol: "udp", host_port: 20_001, guest_port: 4433}] =
               Mjolnir.VM.resume_opts(reread).published_ports
    end

    test "a VM without published ports writes the record it always wrote" do
      record = Mjolnir.VM.build_running_record(vm([]))
      refute Map.has_key?(record.spawn_config, "published_ports")
    end

    test "a record written before the field resumes with none" do
      old = Record.new("old-vm", :running, spawn_config: %{"vcpus" => 2, "memory_mb" => 512})
      assert Mjolnir.VM.resume_opts(old).published_ports == []

      mangled =
        Record.new("odd-vm", :running,
          spawn_config: %{
            "published_ports" => [%{"host_port" => "x"}, 7, %{"host_port" => 20_001}]
          }
        )

      assert [%{host_port: 20_001, guest_port: 20_001}] =
               Mjolnir.VM.resume_opts(mangled).published_ports

      assert PublishedPorts.decode("nonsense") == []
    end

    test "init claims the ports and threads them into the VM config" do
      {:ok, state, {:continue, :boot}} =
        Mjolnir.VM.init(%{
          id: UUID.uuid4(),
          published_ports: [%{"host_port" => 20_031, "guest_port" => 4433}]
        })

      assert [%{host_port: 20_031, guest_port: 4433}] = state.config.published_ports
      assert PublishedPorts.holders()[20_031] == state.id
      assert_received :published_ports_sync
    end

    test "init refuses a fresh VM whose port another VM holds, and resumes without it" do
      test = self()

      holder =
        spawn(fn ->
          send(test, PublishedPorts.claim("first", [port(20_041)]))
          Process.sleep(:infinity)
        end)

      assert_receive :ok
      on_exit(fn -> Process.exit(holder, :kill) end)

      assert {:stop, {:host_port_published, 20_041, "first"}} =
               Mjolnir.VM.init(%{id: UUID.uuid4(), published_ports: [port(20_041)]})

      assert {:ok, state, _} =
               Mjolnir.VM.init(%{id: UUID.uuid4(), resume: true, published_ports: [port(20_041)]})

      assert state.config.published_ports == []
    end
  end

  describe "VM.spawn/1" do
    test "refuses published ports before any VM process starts" do
      before = Registry.count(Mjolnir.VMRegistry)

      assert {:error, :published_ports_disabled} =
               Mjolnir.VM.spawn(%{published_ports: [%{host_port: 20_001}]})

      assert {:error, {:invalid_published_port, _}} =
               Mjolnir.VM.spawn(%{published_ports: [%{host_port: 0}]})

      assert {:error, :quic_guest_port_requires_unikernel} =
               Mjolnir.VM.spawn(%{published_ports: [%{host_port: 20_001, guest_port: "quic"}]})

      assert Registry.count(Mjolnir.VMRegistry) == before
    end
  end
end
