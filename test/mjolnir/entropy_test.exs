defmodule Mjolnir.EntropyTest do
  @moduledoc """
  mjolnir-3y6.5. Two VMs restored from one memory snapshot share CRNG state and
  will emit identical session keys and nonces. The host's only defence until
  VMGENID lands is to force a reseed and refuse to expose the VM until the
  guest confirms it.

  Everything here guards the *gate*: `interpret/1` decides whether a restored
  VM becomes reachable, so every ambiguous answer must resolve to "no". The
  ioctl itself is covered on the guest side (`native/.../entropy.rs`). The
  end-to-end property — two thaws, two different keys — is
  `Mjolnir.Entropy.Probe` (control flow in `entropy_probe_test.exs`; live
  sample needs KVM).
  """
  use ExUnit.Case, async: true

  alias Mjolnir.Entropy

  describe "fresh_seed/0" do
    test "draws 256 bits" do
      assert byte_size(Entropy.fresh_seed()) == 32
    end

    test "does not repeat" do
      # The whole point of the module. If this ever fails, the host CSPRNG is
      # broken and nothing downstream matters.
      seeds = for _ <- 1..50, do: Entropy.fresh_seed()
      assert length(Enum.uniq(seeds)) == 50
    end
  end

  describe "request/2" do
    test "encodes the seed as lowercase hex the guest can decode" do
      req = Entropy.request(<<0x00, 0xFF, 0x10>>, "req-1")

      assert req["type"] == "reseed_entropy"
      assert req["id"] == "req-1"
      assert req["seed_hex"] == "00ff10"
    end

    test "generates a correlation id when none is given" do
      # Vsock.Connection matches responses on "id"; a missing one strands the
      # caller until timeout.
      assert %{"id" => id} = Entropy.request(Entropy.fresh_seed())
      assert is_binary(id) and byte_size(id) > 0
    end

    test "seed_hex round-trips to the original bytes" do
      seed = Entropy.fresh_seed()
      assert {:ok, ^seed} = Base.decode16(Entropy.request(seed)["seed_hex"], case: :lower)
    end
  end

  describe "interpret/1 — the gate" do
    test "accepts a confirmed reseed that credited bytes" do
      assert :ok =
               Entropy.interpret(%{
                 "type" => "reseed_entropy_response",
                 "ok" => true,
                 "bytes" => 32
               })
    end

    test "refuses ok:true that credited nothing" do
      # A guest reporting success while crediting zero bytes has not moved the
      # kernel's entropy estimate. Trusting it would defeat the entire gate.
      assert {:error, {:reseed_credited_nothing, 0}} =
               Entropy.interpret(%{
                 "type" => "reseed_entropy_response",
                 "ok" => true,
                 "bytes" => 0
               })
    end

    test "refuses an explicit failure and carries the reason" do
      assert {:error, {:reseed_refused, "RNDADDENTROPY failed: EPERM"}} =
               Entropy.interpret(%{
                 "type" => "reseed_entropy_response",
                 "ok" => false,
                 "bytes" => 0,
                 "error" => "RNDADDENTROPY failed: EPERM"
               })
    end

    test "distinguishes an agent too old to know the request" do
      # Separate error because the operator action is different: rebuild and
      # redeploy the guest agent, not debug the guest kernel.
      assert {:error, {:reseed_unsupported_by_agent, _}} =
               Entropy.interpret(%{
                 "type" => "error",
                 "ok" => false,
                 "error" => "unsupported or malformed request: unknown variant"
               })
    end

    test "refuses anything it does not recognise" do
      # Fail closed. An unreachable VM is an operational problem; a silently
      # cloned CRNG is a key compromise.
      assert {:error, {:reseed_unexpected_response, _}} = Entropy.interpret(%{"type" => "pong"})
      assert {:error, {:reseed_unexpected_response, _}} = Entropy.interpret(%{})
    end

    test "a missing bytes field is not treated as success" do
      assert {:error, _} =
               Entropy.interpret(%{"type" => "reseed_entropy_response", "ok" => true})
    end
  end
end
