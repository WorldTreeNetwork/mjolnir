defmodule Mjolnir.API.TermPageTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Mjolnir.API.{Auth, Router, TermPage}

  @opts Router.init([])
  @vm_id "01234567-89ab-cdef-0123-456789abcdef"

  setup do
    original = Application.get_env(:mjolnir, :auth, [])
    Application.put_env(:mjolnir, :auth, bypass_localhost: true)

    on_exit(fn -> Application.put_env(:mjolnir, :auth, original) end)
    :ok
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
    end

    test "defaults a nil session to main" do
      html = TermPage.render(@vm_id, nil)
      assert html =~ "\"main\""
    end
  end

  describe "GET /term/:id" do
    test "serves HTML for a valid VM id" do
      conn = request("/term/#{@vm_id}")
      assert conn.status == 200
      assert conn.resp_body =~ "MJOLNIR"
      assert conn.resp_body =~ Mjolnir.VmId.storage_id(@vm_id)
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/html"
    end

    test "defaults the tmux session to main" do
      conn = request("/term/#{@vm_id}")
      assert conn.resp_body =~ "\"main\""
    end

    test "honours ?session=" do
      conn = request("/term/#{@vm_id}?session=solo")
      assert conn.status == 200
      assert conn.resp_body =~ "\"solo\""
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
