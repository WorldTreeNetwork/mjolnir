# Isolated ordering model for fence-channel.
# Not a transport. Not a storage engine. Not the production host.
# The file is only a witness that acceptance is visible before the callback returns.
ExUnit.start(autorun: false)
import ExUnit.Assertions

defmodule SpikeFence do
  use GenServer

  def start(path) do
    GenServer.start_link(__MODULE__, path, name: __MODULE__)
  end

  def commit(channel, grant, mutation_id, write) do
    GenServer.call(__MODULE__, {:commit, channel, grant, mutation_id, write}, :infinity)
  end

  def transfer(new_instance) do
    GenServer.call(__MODULE__, {:transfer, new_instance}, :infinity)
  end

  @impl true
  def init(path) do
    state = %{path: path, owner: "inst-a", generation: 1, writes: 0, accepted: %{}}
    persist!(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:commit, channel, grant, mutation_id, write}, _from, state) do
    # Guest disk is not an argument. Channel identity is the only caller proof.
    cond do
      channel != grant.instance ->
        {:reply, {:error, :not_channel}, state}

      grant.instance != state.owner or grant.generation != state.generation ->
        {:reply, {:error, :revoked}, state}

      Map.has_key?(state.accepted, mutation_id) ->
        {:reply, {:error, :not_reusable}, state}

      true ->
        state = %{
          state
          | accepted:
              Map.put(state.accepted, mutation_id, %{
                instance: grant.instance,
                generation: grant.generation
              })
        }

        persist!(state)
        outcome = write.()
        state = %{state | writes: state.writes + if(outcome == :wrote, do: 1, else: 0)}
        persist!(state)
        {:reply, {:ok, outcome}, state}
    end
  end

  def handle_call({:transfer, new_instance}, _from, state) do
    state = %{state | owner: new_instance, generation: state.generation + 1}
    persist!(state)
    {:reply, {:ok, state.owner, state.generation}, state}
  end

  defp persist!(state) do
    body = :erlang.term_to_binary(Map.delete(state, :path))
    File.write!(state.path, body)
    {:ok, io} = File.open(state.path, [:read, :binary])

    try do
      :ok = :file.sync(io)
    after
      File.close(io)
    end
  end
end

defmodule SpikeRun do
  def main do
    path = Path.join(System.tmp_dir!(), "fence-channel-#{:os.getpid()}.bin")
    {:ok, _} = SpikeFence.start(path)
    parent = self()
    grant = %{instance: "inst-a", generation: 1}
    guest_disk = %{instance: "inst-forged", generation: 99, note: "must never be read"}

    # Channel mismatch loses even if a forged disk record would match the caller.
    {:error, :not_channel} =
      SpikeFence.commit("inst-forged", %{instance: "inst-a", generation: 1}, "forge", fn ->
        raise "write must not run"
      end)

    _ = guest_disk

    # Case 1. Acceptance is on the witness file before the callback returns.
    spawn(fn ->
      send(parent, {:caller, self()})

      result =
        SpikeFence.commit("inst-a", grant, "m1", fn ->
          send(parent, {:in_write, self()})

          receive do
            :continue -> :wrote
          end
        end)

      send(parent, {:commit_done, result})
    end)

    server = Process.whereis(SpikeFence)
    assert_receive {:caller, _caller1}, 2_000
    assert_receive {:in_write, ^server}, 2_000
    refute_received {:commit_done, _}
    seen = read!(path)
    assert seen.accepted["m1"].instance == "inst-a"
    assert seen.writes == 0
    IO.puts("CASE1 pass acceptance_visible_before_callback writes=#{seen.writes}")

    send(server, :continue)
    assert_receive {:commit_done, {:ok, :wrote}}, 2_000
    after_write = read!(path)
    assert after_write.writes == 1

    # Case 2. Dropping the reply and calling again does not write or reissue authority.
    {:error, :not_reusable} =
      SpikeFence.commit("inst-a", grant, "m1", fn ->
        raise "lost response must not rerun the guest write"
      end)

    assert read!(path).writes == 1
    IO.puts("CASE2 pass lost_response_not_reusable writes=1")

    # Case 3. Transfer waits on the same serialized turn while the callback stalls.
    # Killing the caller is the disconnect. The acceptance stays.
    spawn(fn ->
      send(parent, {:caller, self()})

      result =
        SpikeFence.commit("inst-a", grant, "m2", fn ->
          send(parent, {:in_write, self()})

          receive do
            :continue -> :wrote
          end
        end)

      send(parent, {:commit_done, result})
    end)

    assert_receive {:caller, caller2}, 2_000
    assert_receive {:in_write, ^server}, 2_000
    transfer =
      spawn(fn ->
        send(parent, {:transfer_done, SpikeFence.transfer("inst-b")})
      end)

    Process.sleep(100)
    mid = read!(path)
    assert mid.owner == "inst-a"
    assert mid.generation == 1
    assert mid.accepted["m2"].generation == 1
    refute_received {:transfer_done, _}
    Process.exit(caller2, :kill)
    Process.sleep(50)
    assert read!(path).accepted["m2"]
    refute_received {:transfer_done, _}
    IO.puts("CASE3 pass transfer_queued_during_stall owner=#{mid.owner} gen=#{mid.generation}")

    send(server, :continue)
    assert_receive {:transfer_done, {:ok, "inst-b", 2}}, 2_000
    done = read!(path)
    assert done.owner == "inst-b"
    assert done.generation == 2
    assert done.writes == 2
    assert done.accepted["m2"]

    {:error, :revoked} =
      SpikeFence.commit("inst-a", grant, "m3", fn ->
        raise "revoked grant must not write"
      end)

    {:error, :not_reusable} =
      SpikeFence.commit("inst-b", %{instance: "inst-b", generation: 2}, "m2", fn ->
        raise "accepted mutation must not write again after disconnect"
      end)

    assert read!(path).writes == 2
    IO.puts("CASE3 pass disconnect_keeps_acceptance transfer_then_revokes writes=2")
    IO.puts("ALL pass")
    File.rm(path)
    _ = transfer
  end

  defp read!(path) do
    Map.put(:erlang.binary_to_term(File.read!(path)), :path, path)
  end
end

SpikeRun.main()
