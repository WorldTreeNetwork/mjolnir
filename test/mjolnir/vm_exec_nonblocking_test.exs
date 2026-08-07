defmodule Mjolnir.VMExecNonBlockingTest do
  # Regression tests for mjolnir-8ie: an unresponsive guest must not wedge the
  # VM GenServer's mailbox.
  #
  # The original bug had two halves. `VM.exec/3` applied its `:timeout` to the
  # outer `GenServer.call` but passed `:infinity` to the inner
  # `Vsock.Connection.exec`, so when the outer timeout fired the caller exited
  # while the VM GenServer stayed blocked *forever* on the inner call. And
  # because that call ran inline in `handle_call`, the mailbox was blocked with
  # it — every later `status`, health probe and stop timed out, and no heal path
  # could recover it (they all route through the same process).
  #
  # Reproduced deterministically on 2026-08-07 by pausing a VM long enough to
  # write 1GiB of RAM to disk, which severs the guest-agent vsock.
  use ExUnit.Case, async: true

  # A stand-in for Mjolnir.Vsock.Connection that accepts calls and never answers
  # — exactly how the connection behaves after a long pause severs it.
  defmodule SilentConn do
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(_), do: {:ok, %{}}

    @impl true
    def handle_call(_msg, _from, state), do: {:noreply, state}
  end

  defp state_with(conn), do: %Mjolnir.VM{id: "test-vm", vsock_conn: conn}

  describe "handle_call({:exec, ...}) with an unresponsive guest" do
    test "returns :noreply immediately instead of blocking the mailbox" do
      {:ok, conn} = SilentConn.start_link()
      from = {self(), make_ref()}

      # The inner bound is 200ms, so an inline implementation would sit here for
      # at least that long. Measure it: the callback must return essentially
      # instantly, because the waiting happens off-process.
      {elapsed_us, result} =
        :timer.tc(fn ->
          Mjolnir.VM.handle_call({:exec, "sleep forever", 200}, from, state_with(conn))
        end)

      assert {:noreply, %Mjolnir.VM{}} = result

      assert elapsed_us < 100_000,
             "handle_call blocked for #{div(elapsed_us, 1000)}ms — it must hand the " <>
               "vsock round-trip off and return immediately (mjolnir-8ie)"
    end

    test "the caller still gets a reply rather than hanging forever" do
      {:ok, conn} = SilentConn.start_link()
      ref = make_ref()
      from = {self(), ref}

      {:noreply, _} =
        Mjolnir.VM.handle_call({:exec, "sleep forever", 200}, from, state_with(conn))

      # Connection.exec's outer timeout fires, the Task catches the exit, and the
      # caller is answered with an error instead of being pinned indefinitely.
      assert_receive {^ref, {:error, {:vsock_unavailable, _reason}}}, 15_000
    end

    test "a dead connection is reported, not raised" do
      {:ok, conn} = SilentConn.start_link()
      GenServer.stop(conn)
      ref = make_ref()
      from = {self(), ref}

      {:noreply, _} = Mjolnir.VM.handle_call({:exec, "uname -a", 200}, from, state_with(conn))

      assert_receive {^ref, {:error, {:vsock_unavailable, _reason}}}, 5_000
    end

    test "no vsock connection replies inline — nothing to wait on" do
      from = {self(), make_ref()}

      assert {:reply, {:error, :no_vsock_connection}, %Mjolnir.VM{}} =
               Mjolnir.VM.handle_call({:exec, "uname -a", 200}, from, state_with(nil))
    end

    test "the legacy 2-tuple exec call is still handled" do
      {:ok, conn} = SilentConn.start_link()
      from = {self(), make_ref()}

      assert {:noreply, %Mjolnir.VM{}} =
               Mjolnir.VM.handle_call({:exec, "uname -a"}, from, state_with(conn))
    end
  end

  describe "exec/3 timeout defaults" do
    test "an unknown VM fails fast instead of hanging on the default timeout" do
      # Guards the default being BOUNDED: with :infinity restored here, a call
      # against a missing VM would raise rather than return, and this would fail.
      assert catch_exit(Mjolnir.VM.exec("no-such-vm-#{System.unique_integer()}", "true"))
    end
  end
end
