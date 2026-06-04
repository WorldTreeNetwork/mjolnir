defmodule Mjolnir.Forge.ToDeclarationTest do
  @moduledoc """
  Round-trip coverage for the per-kind `to_declaration/2` serializers.

  The strongest possible check: render content → DSL source, compile that
  source through the *real* `Mjolnir.Forge.Declaration` macros, and assert the
  parsed-back content is canonical-equal to the original. If the serializer
  and the macro ever disagree, this fails.
  """

  use ExUnit.Case, async: true

  alias Mjolnir.Forge.Resource.{
    AptPackage,
    File,
    Iptables,
    Sysctl,
    SystemdUnit,
    UfwNat,
    User
  }

  # Render `content` to a DSL block, compile it under a uniquely-named module,
  # and return the single {kind_mod, id, parsed_content} the macros produced.
  defp parse_back(kind_mod, id, content) do
    block = kind_mod.to_declaration(id, content) |> IO.iodata_to_binary()
    n = System.unique_integer([:positive])

    src = """
    defmodule Mjolnir.Forge.ToDeclarationTest.RT#{n} do
      use Mjolnir.Forge.Declaration, host: "rt"
      #{block}
    end
    """

    [{mod, _bytecode}] = Code.compile_string(src)
    [{^kind_mod, ^id, parsed}] = mod.__forge_resources__()
    parsed
  end

  defp assert_roundtrip(kind_mod, id, content) do
    parsed = parse_back(kind_mod, id, content)

    assert kind_mod.canonical(parsed) == kind_mod.canonical(content),
           "#{kind_mod.kind()} #{id}: canonical mismatch after round-trip\n" <>
             "  declared: #{kind_mod.to_declaration(id, content) |> IO.iodata_to_binary()}"

    parsed
  end

  test "systemd_unit round-trips (observed shape: enabled/state nil)" do
    content = %{
      source: "[Unit]\nDescription=Test\n[Service]\nExecStart=/bin/true\n",
      enabled: nil,
      state: nil
    }

    assert_roundtrip(SystemdUnit, "test.service", content)
  end

  test "systemd_unit round-trips with embedded quotes and newlines" do
    content = %{
      source: ~s([Service]\nExecStart=/bin/sh -c "echo \\"hi\\"\n),
      enabled: true,
      state: :running
    }

    assert_roundtrip(SystemdUnit, "quoted.service", content)
  end

  test "file round-trips with octal mode and owner" do
    content = %{path: "/etc/motd", source: "Welcome\n", mode: 0o600, owner: "root", group: nil}
    parsed = assert_roundtrip(File, "/etc/motd", content)
    # mode is rendered octal and parsed back to the same integer
    assert parsed.mode == 0o600
    assert parsed.owner == "root"
  end

  test "file round-trips with a path id containing spaces" do
    content = %{source: "x\n", mode: 0o644}
    assert_roundtrip(File, "/etc/with space/foo.conf", content)
  end

  test "sysctl round-trips" do
    assert_roundtrip(Sysctl, "net.ipv4.ip_forward", %{value: "1"})
  end

  test "apt_package round-trips a held+pinned package" do
    parsed = assert_roundtrip(AptPackage, "cloud-hypervisor", %{state: :held, version: "50.0"})
    assert parsed.state == :held
    assert parsed.version == "50.0"
  end

  test "apt_package round-trips with no version (observed installed)" do
    assert_roundtrip(AptPackage, "nginx", %{state: :installed, version: nil})
  end

  test "user round-trips a system account with groups" do
    content = %{
      state: :present,
      uid: 999,
      shell: "/usr/sbin/nologin",
      home: "/nonexistent",
      groups: ["docker", "kvm"],
      system: true
    }

    parsed = assert_roundtrip(User, "mjolnir_pg", content)
    assert parsed.uid == 999
    assert parsed.system == true
  end

  test "user round-trips the partial observed shape (system: false omitted)" do
    # parse_observed/1 yields this shape; system:false must round-trip cleanly.
    content = %{
      state: :present,
      uid: 1000,
      shell: "/bin/bash",
      home: "/home/x",
      groups: nil,
      system: false
    }

    assert_roundtrip(User, "x", content)
  end

  test "ufw_nat round-trips a multi-line rules block" do
    rules =
      "*nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -s 10.0.0.0/8 -o eth0 -j MASQUERADE\nCOMMIT"

    assert_roundtrip(UfwNat, "mjolnir-vm-nat", %{rules: rules})
  end

  test "iptables round-trips a rule list" do
    content = %{
      table: "filter",
      chain: "FORWARD",
      rules: ["-i mj-+ -o mj-+ -j ACCEPT", "-i mj-+ -o eth0 -j ACCEPT"]
    }

    parsed = assert_roundtrip(Iptables, "mjolnir-forward", content)
    assert parsed.table == "filter"
    assert parsed.chain == "FORWARD"
  end

  test "render_block quotes the id and indents fields" do
    out =
      Mjolnir.Forge.Resource.render_block("sysctl", "net.ipv4.ip_forward", [{:value, ~s("1")}])

    str = IO.iodata_to_binary(out)
    assert str == ~s(sysctl "net.ipv4.ip_forward" do\n  value "1"\nend\n)
  end
end
