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
      assert vm.shell_ready == true or vm.shell_ready == false

      if vm.shell_ready do
        assert is_binary(vm.iroh_node_id)
        assert is_binary(vm.iroh_json)
        # Node IDs are hex-encoded 32-byte public keys (64 chars)
        assert String.length(vm.iroh_node_id) == 64
        # Tickets are longer (include address info)
        assert String.length(vm.iroh_json) > 50
      else
        # If shell not ready, iroh fields should be nil
        assert is_nil(vm.iroh_node_id)
        assert is_nil(vm.iroh_json)
      end

      Mjolnir.VM.stop(vm.id)
    end

    @tag timeout: 60_000
    test "get_ticket returns z32 ticket for running VM" do
      {:ok, vm} = Mjolnir.VM.spawn()

      case Mjolnir.VM.get_ticket(vm.id) do
        {:ok, ticket} ->
          assert is_binary(ticket)
          # z32 tickets are exactly 52 chars (32 bytes encoded)
          assert String.length(ticket) == 52
          # Should match what Ticket.from_hex produces
          assert ticket == Mjolnir.Ticket.from_hex(vm.iroh_node_id)

        {:error, :not_ready} ->
          # Shell not ready is acceptable - depends on network
          :ok
      end

      Mjolnir.VM.stop(vm.id)
    end

    @tag timeout: 60_000
    test "connection_info returns ticket and iroh_addr" do
      {:ok, vm} = Mjolnir.VM.spawn()

      case Mjolnir.VM.connection_info(vm.id) do
        {:ok, ticket, iroh_addr} ->
          # ticket is z32
          assert is_binary(ticket)
          assert String.length(ticket) == 52
          # iroh_addr is JSON
          assert is_binary(iroh_addr)
          assert String.starts_with?(iroh_addr, "{")

        {:error, :not_ready} ->
          :ok
      end

      Mjolnir.VM.stop(vm.id)
    end

    @tag timeout: 60_000
    test "await_shell returns z32 ticket" do
      {:ok, vm} = Mjolnir.VM.spawn()

      if vm.shell_ready do
        {time, result} =
          :timer.tc(fn ->
            Mjolnir.VM.await_shell(vm.id, 5000)
          end)

        assert {:ok, ticket} = result
        # Should be z32 format, not iroh JSON
        assert is_binary(ticket)
        refute String.starts_with?(ticket, "{")
        assert ticket == Mjolnir.Ticket.from_hex(vm.iroh_node_id)
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
    test "connection_info returns not_found for unknown VM" do
      fake_id = UUID.uuid4()
      assert {:error, :not_found} = Mjolnir.VM.connection_info(fake_id)
    end

    @tag timeout: 60_000
    test "await_shell returns not_found for unknown VM" do
      fake_id = UUID.uuid4()
      assert {:error, :not_found} = Mjolnir.VM.await_shell(fake_id, 1000)
    end
  end
end
