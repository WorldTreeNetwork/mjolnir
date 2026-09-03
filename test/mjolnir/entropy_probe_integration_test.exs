defmodule Mjolnir.Entropy.ProbeIntegrationTest do
  @moduledoc """
  Live two-thaw key probe. Needs KVM + root + a freezeable VM.

  `mix test --include integration test/mjolnir/entropy_probe_integration_test.exs`

  Spawns a VM, freezes it, tears the source down, thaws the snapshot onto two
  identities, reseeds, and asserts the `/dev/urandom` samples diverge.
  """
  use Mjolnir.VMCase

  @moduletag :integration
  @moduletag :snapshot
  @moduletag timeout: 180_000

  alias Mjolnir.Entropy.Probe
  alias Mjolnir.MemorySnapshot

  test "two remapped thaws of one snapshot produce different keys after reseed" do
    {:ok, vm} = Mjolnir.VM.spawn(%{memory_mb: 512})
    on_exit(fn -> Mjolnir.VM.stop(vm.id) end)

    name = "entropy-probe-#{System.unique_integer([:positive])}"

    assert {:ok, _meta} = MemorySnapshot.freeze(vm, name)
    :ok = Mjolnir.VM.stop(vm.id)

    on_exit(fn ->
      _ = Mjolnir.BTRFS.delete_snapshot(name)
      _ = File.rm_rf(MemorySnapshot.memory_dir(name))
      _ = File.rm_rf(Path.dirname(MemorySnapshot.fork_dir(name, "x")))
    end)

    assert {:ok, result} = Probe.run(name, reseed: true, connect_timeout_ms: 45_000)

    assert result.reseeded

    assert result.diverged,
           "expected distinct samples, got #{result.key_a} and #{result.key_b}"
  end
end
