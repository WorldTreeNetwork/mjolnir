defmodule Mjolnir.API.TermPageTest do
  # Registers a stand-in VM in the shared registry. Not async.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Mjolnir.API.{Auth, Router, TermPage}

  @opts Router.init([])
  @vm_id "01234567-89ab-cdef-0123-456789abcdef"
  @owner "owner-user"
  @invitee "invite-user"

  defmodule FakeVM do
    use GenServer

    def start(id, owner_id, invites) do
      GenServer.start(__MODULE__, %{owner_id: owner_id, pty_invites: invites},
        name: {:via, Registry, {Mjolnir.VMRegistry, id}}
      )
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:get_state, _from, state), do: {:reply, state, state}
  end

  setup do
    original = Application.get_env(:mjolnir, :auth, [])
    Application.put_env(:mjolnir, :auth, bypass_localhost: true)

    on_exit(fn -> Application.put_env(:mjolnir, :auth, original) end)
    :ok
  end

  defp canonical, do: Mjolnir.VmId.storage_id(@vm_id)

  defp register_vm do
    {:ok, pid} = FakeVM.start(canonical(), @owner, [@invitee])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp request(path) do
    conn(:get, path)
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> Router.call(@opts)
  end

  describe "render/2" do
    test "bakes the vm id and session into the page" do
      html = TermPage.render(@vm_id, "main")
      assert html =~ @vm_id
      assert html =~ "01234567"
      assert html =~ "main"
      assert html =~ "/api/vms/"
      assert html =~ "xterm"
      assert html =~ "attachCustomKeyEventHandler"
      assert html =~ "getSelection"
      assert html =~ "Ctrl+C copies"
      assert html =~ ~s(id="identikey")
      assert html =~ ~s(id="mark")
      assert html =~ "#D21B3C"
    end

    test "defaults a nil session to main" do
      html = TermPage.render(@vm_id, nil)
      assert html =~ "\"main\""
    end

    test "the locked page still carries the mark and no terminal" do
      html = TermPage.denied()
      assert html =~ ~s(id="identikey")
      assert html =~ ~s(id="mark")
      assert html =~ "locked to its owner"
      refute html =~ "xterm"
    end
  end

  describe "GET /term/:id" do
    test "serves HTML for a VM the caller may open" do
      register_vm()
      conn = request("/term/#{@vm_id}")
      assert conn.status == 200
      assert conn.resp_body =~ "MJOLNIR"
      assert conn.resp_body =~ ~s(id="identikey")
      assert conn.resp_body =~ canonical()
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/html"
    end

    test "a missing VM is not a terminal" do
      conn = request("/term/#{@vm_id}")
      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"] == "not_found"
    end

    test "defaults the tmux session to main" do
      register_vm()
      conn = request("/term/#{@vm_id}")
      assert conn.resp_body =~ "\"main\""
    end

    test "honours ?session=" do
      register_vm()
      conn = request("/term/#{@vm_id}?session=solo")
      assert conn.status == 200
      assert conn.resp_body =~ "\"solo\""
    end

    test "a logged-in stranger gets the locked page" do
      register_vm()

      conn =
        conn(:get, "/term/#{canonical()}")
        |> assign(:user_id, "stranger-xid")
        |> Router.serve_term(canonical(), "main")

      assert conn.status == 403
      assert conn.resp_body =~ "locked to its owner"
      refute conn.resp_body =~ "xterm"
    end

    test "the owner and an invitee get the terminal" do
      register_vm()

      for uid <- [@owner, @invitee] do
        conn =
          conn(:get, "/term/#{canonical()}")
          |> assign(:user_id, uid)
          |> Router.serve_term(canonical(), "pi")

        assert conn.status == 200, "expected #{uid} to be allowed"
        assert conn.resp_body =~ "\"pi\""
        assert conn.resp_body =~ ~s(id="identikey")
      end
    end

    test "rejects a non-uuid id" do
      conn = request("/term/not-a-uuid")
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] == "invalid_vm_id"
    end

    test "stashes ?token= in the cookie and redirects it off the URL" do
      conn = request("/term/#{@vm_id}?token=sekrit&session=main")
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/term/#{@vm_id}?session=main"]

      assert %{value: "sekrit", http_only: true, secure: true} =
               conn.resp_cookies[Auth.term_cookie()]
    end
  end
end
