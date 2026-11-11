defmodule Mjolnir.AIE.AdmitTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Mjolnir.AIE.{Admit, Pending}

  setup do
    name = :"admit_pending_#{System.unique_integer([:positive])}"
    start_supervised!({Pending, name: name})
    {:ok, pending: name}
  end

  defp frame do
    %{
      "biscuit_digest" => "bd1",
      "audience" => "mint-root-fp",
      "resource" => "owner/offer/incarnation",
      "design_id" => "vector-add",
      "input_blake3" => "in1",
      "idempotency_key" => "idem-1",
      "holder_fp" => "holder-z"
    }
  end

  defp post(pending, path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_private(:aie_pending, pending)
    |> Admit.call([])
  end

  test "enqueue then admission succeed without operator mark", %{pending: pending} do
    nonce = Mjolnir.Secrets.Nonces.issue()
    conn = post(pending, "/enqueue", %{nonce: nonce, frame: frame()})
    refute conn.private[:mjolnir_operator]
    assert conn.status == 200
    %{"pending_id" => id} = Jason.decode!(conn.resp_body)

    presented = %{
      pending_id: id,
      attempt_id: "att_live",
      job_digest: Pending.job_digest(frame()),
      resource: frame()["resource"]
    }

    conn = post(pending, "/admission", presented)
    refute conn.private[:mjolnir_operator]
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["kind"] == "live"
    assert body["attempt_id"] == "att_live"
  end

  test "does not expose VM operator routes", %{pending: pending} do
    conn = post(pending, "/api/vms", %{})
    refute conn.private[:mjolnir_operator]
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"] == "not_found"
  end

  test "admission without enqueue is refused", %{pending: pending} do
    conn =
      post(pending, "/admission", %{
        pending_id: "pnd_none",
        attempt_id: "att_1",
        job_digest: "x",
        resource: "owner/offer/incarnation"
      })

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] == "unknown"
  end

  test "socket perms are 0660 mjolnir-aie" do
    assert Admit.socket_mode() == 0o660
    assert Admit.socket_group() == "mjolnir-aie"

    dir = System.tmp_dir!()
    path = Path.join(dir, "aie-admit-#{System.unique_integer([:positive])}.sock")
    File.touch!(path)
    assert :ok = Admit.apply_socket_perms(path)
    %{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o777) == 0o660
    File.rm!(path)
  end
end
