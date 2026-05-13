defmodule Mjolnir.Forge.DeclarationTest do
  use ExUnit.Case, async: true

  # Test the DSL by using it inline in a throwaway module. The host string
  # serves as a per-test namespace so the modules don't collide.
  defmodule HostA do
    use Mjolnir.Forge.Declaration, host: "test-host-a"

    systemd_unit "alpha.service" do
      source "[Unit]\nDescription=Alpha\n"
      enabled true
      state :running
    end

    systemd_unit "beta.service" do
      source "[Unit]\nDescription=Beta\n"
      state :stopped
    end
  end

  defmodule HostB do
    use Mjolnir.Forge.Declaration, host: "test-host-b"

    systemd_unit "gamma.service" do
      source "x"
    end
  end

  test "module records its host" do
    assert HostA.__forge_host__() == "test-host-a"
    assert HostB.__forge_host__() == "test-host-b"
  end

  test "resources accumulate in declaration order" do
    [first, second] = HostA.__forge_resources__()
    assert {Mjolnir.Forge.Resource.SystemdUnit, "alpha.service", _} = first
    assert {Mjolnir.Forge.Resource.SystemdUnit, "beta.service", _} = second
  end

  test "default content is enabled=true, state=:running" do
    [{_, "gamma.service", content}] = HostB.__forge_resources__()
    assert content == %{source: "x", enabled: true, state: :running}
  end

  test "fields override defaults" do
    [_, {_, "beta.service", content}] = HostA.__forge_resources__()
    assert content.state == :stopped
    assert content.enabled == true
    assert content.source =~ "Beta"
  end

  test "unknown fields raise CompileError at compile time" do
    assert_raise CompileError, ~r/unsupported call/, fn ->
      defmodule HostBad do
        use Mjolnir.Forge.Declaration, host: "bad"

        systemd_unit "x.service" do
          nonexistent_field "value"
        end
      end
    end
  end
end
