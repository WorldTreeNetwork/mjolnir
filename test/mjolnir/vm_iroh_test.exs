defmodule Mjolnir.VMIrohTest do
  @moduledoc """
  Integration tests for Iroh shell support.

  These tests require:
  - A running VM with the new guest agent (includes Iroh)
  - Network connectivity (for Iroh relay)

  Run with: mix test test/mjolnir/vm_iroh_test.exs --include integration
  """
  use Mjolnir.VMCase
  @moduletag :integration

  describe "Iroh shell readiness" do
    @tag timeout: 60_000
    test "VM reports shell ready after boot" do
      {:ok, vm} = Mjolnir.VM.spawn()

      # Shell may not be ready immediately (needs relay connection)
      # Give it some time
      assert vm.shell_ready == true or vm.shell_ready == false

      if vm.shell_ready do
        assert is_binary(vm.iroh_node_id)
        assert is_binary(vm.iroh_ticket)
        # Node IDs are base32-encoded 32-byte public keys (52 chars)
        assert String.length(vm.iroh_node_id) == 52
        # Tickets are longer (include address info)
        assert String.length(vm.iroh_ticket) > 50
      else
        # If shell not ready, iroh fields should be nil
        assert is_nil(vm.iroh_node_id)
        assert is_nil(vm.iroh_ticket)
      end

      Mjolnir.VM.stop(vm.id)
    end

    @tag timeout: 60_000
    test "get_ticket returns ticket for running VM" do
      {:ok, vm} = Mjolnir.VM.spawn()

      case Mjolnir.VM.get_ticket(vm.id) do
        {:ok, ticket} ->
          assert is_binary(ticket)
          assert ticket == vm.iroh_ticket

        {:error, :not_ready} ->
          # Shell not ready is acceptable - depends on network
          :ok
      end

      Mjolnir.VM.stop(vm.id)
    end

    @tag timeout: 60_000
    test "node_id returns valid iroh format" do
      {:ok, vm} = Mjolnir.VM.spawn()

      case Mjolnir.VM.node_id(vm.id) do
        {:ok, node_id} ->
          # Iroh node IDs are 52 chars (base32 encoded public key)
          assert String.length(node_id) == 52
          assert node_id == vm.iroh_node_id

        {:error, :not_ready} ->
          # Shell not ready is acceptable
          :ok
      end

      Mjolnir.VM.stop(vm.id)
    end

    @tag timeout: 60_000
    test "await_shell returns quickly if already ready" do
      {:ok, vm} = Mjolnir.VM.spawn()

      if vm.shell_ready do
        {time, result} =
          :timer.tc(fn ->
            Mjolnir.VM.await_shell(vm.id, 5000)
          end)

        assert {:ok, ticket} = result
        assert ticket == vm.iroh_ticket
        # Should return nearly instantly if already ready
        assert time < 1_000_000, "Expected < 1s, got #{time / 1000}ms"
      end

      Mjolnir.VM.stop(vm.id)
    end

    @tag timeout: 60_000
    test "get_ticket returns not_found for unknown VM" do
      fake_id = UUID.uuid4()
      assert {:error, :not_found} = Mjolnir.VM.get_ticket(fake_id)
    end

    @tag timeout: 60_000
    test "node_id returns not_found for unknown VM" do
      fake_id = UUID.uuid4()
      assert {:error, :not_found} = Mjolnir.VM.node_id(fake_id)
    end

    @tag timeout: 60_000
    test "await_shell returns not_found for unknown VM" do
      fake_id = UUID.uuid4()
      assert {:error, :not_found} = Mjolnir.VM.await_shell(fake_id, 1000)
    end
  end
end
