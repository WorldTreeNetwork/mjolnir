defmodule Mjolnir.VMMailboxNonBlockingTest do
  # Regression tests for mjolnir-75d: several `handle_call` clauses ran their
  # vsock round-trip INLINE, so an unresponsive guest blocked the VM
  # GenServer's mailbox for the duration of each (bounded, ~10s per probe, but
  # four of them stacked up made a healthy-but-slow VM look dead to any
  # concurrent caller — see mjolnir-75d for the observed false
  # `vm_unreachable` reports).
  #
  # This mirrors vm_exec_nonblocking_test.exs (mjolnir-8ie): call
  # `Mjolnir.VM.handle_call/3` directly against a stand-in for the slow
  # dependency and assert the callback returns `{:noreply, ...}` in well under
  # the dependency's own bound, then assert the original caller still gets a
  # reply once the off-process work finishes.
  use ExUnit.Case, async: true

  # Stand-in for Mjolnir.Vsock.Connection that accepts calls and never answers
  # — used by the terminal_*/authorize_inject_peer clauses, all of which talk
  # to `state.vsock_conn`.
  defmodule SilentConn do
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(_), do: {:ok, %{}}

    @impl true
    def handle_call(_msg, _from, state), do: {:noreply, state}
  end

  defp state_with_conn(conn), do: %Mjolnir.VM{id: "test-vm", vsock_conn: conn}

  # A raw Unix-domain-socket listener that accepts the vsock proxy's
  # "CONNECT <port>\n" handshake and then goes silent — the same shape
  # `probe_iroh_status`/`reconfigure_iroh`/`reconfigure_network` see when a
  # guest's vsock is wedged. Used because those clauses talk to
  # `state.vsock_path` via a raw socket (`vsock_connect/2` in vm.ex), not
  # through the Connection GenServer.
  defp start_silent_vsock_listener do
    path =
      Path.join(System.tmp_dir!(), "mjolnir-test-vsock-#{System.unique_integer([:positive])}")

    _ = File.rm(path)

    {:ok, listen_sock} = :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, path}])

    acceptor =
      spawn_link(fn ->
        case :gen_tcp.accept(listen_sock) do
          {:ok, sock} ->
            # Accept the connection but never reply — held open until the
            # test process exits and takes the socket down with it.
            :timer.sleep(:infinity)
            :gen_tcp.close(sock)

          {:error, _} ->
            :ok
        end
      end)

    on_exit_cleanup(listen_sock, acceptor, path)
    path
  end

  defp on_exit_cleanup(listen_sock, acceptor, path) do
    ExUnit.Callbacks.on_exit(fn ->
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen_sock)
      _ = File.rm(path)
    end)
  end

  describe "terminal_* handle_call clauses with an unresponsive guest" do
    for {name, msg} <- [
          {"terminal_open", {:terminal_open, "sess"}},
          {"terminal_read", {:terminal_read, "sess", 100}},
          {"terminal_send", {:terminal_send, "sess", "ls", nil}},
          {"terminal_list", :terminal_list},
          {"terminal_close", {:terminal_close, "sess"}}
        ] do
      test "#{name} returns :noreply immediately instead of blocking the mailbox" do
        {:ok, conn} = SilentConn.start_link()
        from = {self(), make_ref()}

        {elapsed_us, result} =
          :timer.tc(fn ->
            Mjolnir.VM.handle_call(unquote(Macro.escape(msg)), from, state_with_conn(conn))
          end)

        assert {:noreply, %Mjolnir.VM{}} = result

        assert elapsed_us < 100_000,
               "#{unquote(name)} blocked handle_call for #{div(elapsed_us, 1000)}ms " <>
                 "instead of handing the vsock round-trip off (mjolnir-75d)"
      end

      test "#{name} still replies to the caller instead of leaving it hanging" do
        {:ok, conn} = SilentConn.start_link()
        ref = make_ref()
        from = {self(), ref}

        {:noreply, _} =
          Mjolnir.VM.handle_call(unquote(Macro.escape(msg)), from, state_with_conn(conn))

        # Connection's underlying GenServer.call default-times-out at 5s since
        # SilentConn never answers; the spawned worker catches that :exit and
        # answers the ORIGINAL caller with an error rather than hanging it.
        assert_receive {^ref, {:error, {:vsock_unavailable, _reason}}}, 8_000
      end
    end
  end

  describe "authorize_inject_peer with an unresponsive guest" do
    test "returns :noreply immediately instead of blocking the mailbox" do
      {:ok, conn} = SilentConn.start_link()
      from = {self(), make_ref()}

      {elapsed_us, result} =
        :timer.tc(fn ->
          Mjolnir.VM.handle_call(
            {:authorize_inject_peer, "peer-node-id"},
            from,
            state_with_conn(conn)
          )
        end)

      assert {:noreply, %Mjolnir.VM{}} = result
      assert elapsed_us < 100_000
    end

    # NOTE: unlike the terminal_* family (which use Connection's default 5s
    # GenServer.call timeout), `send_request/2`'s default is 30s (35s outer,
    # see Connection.outer_timeout/1) — asserting the eventual reply here
    # would make this test ~35s all by itself. The elapsed-time assertion
    # above already proves the mailbox isn't blocked, which is the property
    # mjolnir-75d cares about; the eventual-reply half is covered by the
    # terminal_* tests using a dependency with a realistic test timeout.

    test "no vsock connection replies off-process with a clean error" do
      ref = make_ref()
      from = {self(), ref}

      {:noreply, _} =
        Mjolnir.VM.handle_call(
          {:authorize_inject_peer, "peer-node-id"},
          from,
          state_with_conn(nil)
        )

      assert_receive {^ref, {:error, :no_vsock_connection}}, 1_000
    end
  end

  describe "probe_iroh_status with a wedged vsock" do
    test "returns :noreply immediately instead of blocking the mailbox for `timeout`" do
      path = start_silent_vsock_listener()
      from = {self(), make_ref()}
      state = %Mjolnir.VM{id: "test-vm", vsock_path: path}

      # The probe's own bound is 300ms — an inline implementation would sit in
      # handle_call for at least that long. It must return essentially
      # instantly instead.
      {elapsed_us, result} =
        :timer.tc(fn -> Mjolnir.VM.handle_call({:probe_iroh_status, 300}, from, state) end)

      assert {:noreply, %Mjolnir.VM{}} = result
      assert elapsed_us < 100_000
    end

    test "the caller still gets a bounded reply" do
      path = start_silent_vsock_listener()
      ref = make_ref()
      from = {self(), ref}
      state = %Mjolnir.VM{id: "test-vm", vsock_path: path}

      {:noreply, _} = Mjolnir.VM.handle_call({:probe_iroh_status, 300}, from, state)

      assert_receive {^ref, {:error, _reason}}, 3_000
    end
  end

  describe "a concurrent cheap call is served while a slow probe is in flight" do
    test ":status answers promptly even though a probe_iroh_status call is outstanding" do
      path = start_silent_vsock_listener()
      probe_from = {self(), make_ref()}
      state = %Mjolnir.VM{id: "test-vm", state: :running, vsock_path: path}

      # Simulate the mailbox processing the slow probe first...
      {:noreply, state_after_probe} =
        Mjolnir.VM.handle_call({:probe_iroh_status, 5_000}, probe_from, state)

      # ...then a cheap concurrent call. Because the probe handed its work off
      # instead of blocking inline, the mailbox is already free for this next
      # message — proven by `:status` resolving synchronously with no wait.
      {elapsed_us, result} =
        :timer.tc(fn ->
          Mjolnir.VM.handle_call(:status, {self(), make_ref()}, state_after_probe)
        end)

      assert {:reply, :running, %Mjolnir.VM{}} = result
      assert elapsed_us < 50_000
    end
  end

  describe "reconfigure_iroh with a wedged vsock" do
    test "returns :noreply immediately instead of blocking the mailbox" do
      path = start_silent_vsock_listener()
      from = {self(), make_ref()}
      state = %Mjolnir.VM{id: "test-vm", vsock_path: path, enable_iroh: true}

      {elapsed_us, result} =
        :timer.tc(fn -> Mjolnir.VM.handle_call(:reconfigure_iroh, from, state) end)

      assert {:noreply, %Mjolnir.VM{}} = result
      assert elapsed_us < 100_000
    end

    test "no vsock path replies off-process with a clean error" do
      ref = make_ref()
      from = {self(), ref}
      state = %Mjolnir.VM{id: "test-vm", vsock_path: nil, enable_iroh: true}

      {:noreply, _} = Mjolnir.VM.handle_call(:reconfigure_iroh, from, state)

      assert_receive {^ref, {:error, :no_vsock_path}}, 1_000
    end
  end

  describe "reconfigure_network" do
    test "returns :noreply immediately instead of blocking the mailbox" do
      path = start_silent_vsock_listener()
      from = {self(), make_ref()}

      state = %Mjolnir.VM{
        id: "test-vm",
        vsock_path: path,
        net_config: %{tap_name: "mj-nonexistent-test-tap", guest_ip: "10.99.99.99"}
      }

      {elapsed_us, result} =
        :timer.tc(fn -> Mjolnir.VM.handle_call(:reconfigure_network, from, state) end)

      assert {:noreply, %Mjolnir.VM{}} = result
      assert elapsed_us < 100_000
    end

    test "no net_config replies off-process with a clean error" do
      ref = make_ref()
      from = {self(), ref}
      state = %Mjolnir.VM{id: "test-vm", vsock_path: "/tmp/whatever", net_config: nil}

      {:noreply, _} = Mjolnir.VM.handle_call(:reconfigure_network, from, state)

      assert_receive {^ref, {:error, :no_net_config}}, 1_000
    end
  end

  describe "rebuild_vsock_connection (Tier 2 — mutates state.vsock_conn)" do
    test "returns :noreply immediately and marks a rebuild in flight" do
      {:ok, conn} = SilentConn.start_link()
      from = {self(), make_ref()}
      state = %Mjolnir.VM{id: "test-vm", vsock_conn: conn, vsock_path: "/tmp/does-not-matter"}

      {elapsed_us, result} =
        :timer.tc(fn -> Mjolnir.VM.handle_call(:rebuild_vsock_connection, from, state) end)

      assert {:noreply, %Mjolnir.VM{vsock_rebuild_waiters: [^from]}} = result
      assert elapsed_us < 100_000
    end

    test "a second concurrent caller piggybacks instead of racing a second rebuild" do
      first_from = {self(), make_ref()}
      second_from = {self(), make_ref()}

      state = %Mjolnir.VM{
        id: "test-vm",
        vsock_conn: nil,
        vsock_path: nil,
        vsock_rebuild_waiters: [first_from]
      }

      {:noreply, result} =
        Mjolnir.VM.handle_call(:rebuild_vsock_connection, second_from, state)

      assert result.vsock_rebuild_waiters == [second_from, first_from]
    end

    test "handle_info folds a failed rebuild's result into state and replies every waiter" do
      from1 = {self(), make_ref()}
      from2 = {self(), make_ref()}

      state = %Mjolnir.VM{
        id: "test-vm",
        vsock_conn: :stale_pid_placeholder,
        vsock_rebuild_waiters: [from2, from1]
      }

      {:noreply, new_state} =
        Mjolnir.VM.handle_info({:vsock_rebuild_result, {:error, :no_vsock_path}}, state)

      assert new_state.vsock_conn == nil
      assert new_state.vsock_rebuild_waiters == []

      for {_pid, ref} = from <- [from1, from2] do
        assert_receive {^ref, {:error, :no_vsock_path}}, 1_000
        _ = from
      end
    end

    test "a rebuild worker that dies uncatchably fails its waiters instead of stranding them" do
      # try/catch inside the worker converts ordinary failures into an
      # {:error, _} result, so this clause is only reached when the worker is
      # killed uncatchably. If it did nothing, vsock_rebuild_waiters would stay
      # non-empty forever and EVERY later rebuild would piggyback onto a queue
      # that can never drain — permanently wedging the recovery path this whole
      # change exists to keep working.
      worker_ref = make_ref()
      from1 = {self(), make_ref()}
      from2 = {self(), make_ref()}

      state = %Mjolnir.VM{
        id: "test-vm",
        vsock_rebuild_waiters: [from2, from1],
        vsock_rebuild_ref: worker_ref
      }

      {:noreply, new_state} =
        Mjolnir.VM.handle_info({:DOWN, worker_ref, :process, self(), :killed}, state)

      assert new_state.vsock_rebuild_waiters == [],
             "waiters must be cleared, or the rebuild path wedges permanently"

      assert new_state.vsock_rebuild_ref == nil

      for {_pid, ref} <- [from1, from2] do
        assert_receive {^ref, {:error, {:rebuild_worker_died, :killed}}}, 1_000
      end
    end

    test "a DOWN from an unrelated monitor does not disturb rebuild state" do
      # The healthy case: the result message arrives first and clears the ref,
      # so the worker's own (now stale) DOWN must fall through to the catch-all
      # rather than matching and replying twice.
      from = {self(), make_ref()}

      state = %Mjolnir.VM{
        id: "test-vm",
        vsock_rebuild_waiters: [from],
        vsock_rebuild_ref: nil
      }

      {:noreply, new_state} =
        Mjolnir.VM.handle_info({:DOWN, make_ref(), :process, self(), :normal}, state)

      assert new_state.vsock_rebuild_waiters == [from]
      refute_receive {_, {:error, {:rebuild_worker_died, _}}}, 200
    end

    test "handle_info folds a successful rebuild's new connection into state" do
      {:ok, new_conn} = SilentConn.start_link()
      from = {self(), make_ref()}

      state = %Mjolnir.VM{id: "test-vm", vsock_conn: nil, vsock_rebuild_waiters: [from]}

      {:noreply, new_state} =
        Mjolnir.VM.handle_info({:vsock_rebuild_result, {:ok, new_conn}}, state)

      assert new_state.vsock_conn == new_conn
      assert new_state.vsock_rebuild_waiters == []

      ref = elem(from, 1)
      assert_receive {^ref, :ok}, 1_000
    end

    test "end-to-end: rebuild against a wedged old connection still frees the mailbox and replies" do
      {:ok, old_conn} = SilentConn.start_link()
      from = {self(), make_ref()}

      # No vsock_path, so the rebuild will fail fast once it runs — but the
      # key property under test is that handle_call never blocks on it.
      state = %Mjolnir.VM{id: "test-vm", vsock_conn: old_conn, vsock_path: nil}

      {elapsed_us, {:noreply, state_after_call}} =
        :timer.tc(fn -> Mjolnir.VM.handle_call(:rebuild_vsock_connection, from, state) end)

      assert elapsed_us < 100_000

      # In production this GenServer's own `handle_info` loop picks this up
      # automatically; here we drive it manually — same technique
      # vm_exec_nonblocking_test.exs uses for the exec Task's :DOWN message —
      # to prove the full round trip (worker -> message -> state fold ->
      # reply) actually completes.
      assert_receive {:vsock_rebuild_result, result}, 3_000

      {:noreply, _final_state} =
        Mjolnir.VM.handle_info({:vsock_rebuild_result, result}, state_after_call)

      ref = elem(from, 1)
      assert_receive {^ref, {:error, :no_vsock_path}}, 1_000
    end
  end
end
