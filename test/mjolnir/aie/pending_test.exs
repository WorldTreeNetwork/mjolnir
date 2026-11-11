defmodule Mjolnir.AIE.PendingTest do
  use ExUnit.Case, async: true

  alias Mjolnir.AIE.Pending

  setup do
    name = :"pending_#{System.unique_integer([:positive])}"
    pid = start_supervised!({Pending, name: name})
    nonce = Mjolnir.Secrets.Nonces.issue()
    {:ok, server: pid, nonce: nonce}
  end

  defp frame(overrides \\ %{}) do
    Map.merge(
      %{
        "biscuit_digest" => "bd1",
        "audience" => "mint-root-fp",
        "resource" => "owner/offer/incarnation",
        "design_id" => "vector-add",
        "input_blake3" => "in1",
        "idempotency_key" => "idem-1",
        "holder_fp" => "holder-z"
      },
      overrides
    )
  end

  test "enqueue consumes nonce once and returns pending_id", %{server: server, nonce: nonce} do
    assert {:ok, id} = Pending.enqueue(server, nonce, frame())
    assert String.starts_with?(id, "pnd_")
    assert {:error, :nonce} = Pending.enqueue(server, nonce, frame())
  end

  test "enqueue refuses unknown design and guest xclbin", %{server: server} do
    nonce = Mjolnir.Secrets.Nonces.issue()

    assert {:error, :unknown_design} =
             Pending.enqueue(server, nonce, frame(%{"design_id" => "evil.xclbin"}))

    nonce2 = Mjolnir.Secrets.Nonces.issue()

    assert {:error, :unknown_design} =
             Pending.enqueue(server, nonce2, frame(%{"design_id" => "/tmp/guest.xclbin"}))
  end

  test "admission without enqueue is refused", %{server: server} do
    assert {:error, :unknown} = Pending.admit(server, "pnd_missing", "att_1", %{})
  end

  test "admission binds attempt_id once; retry of same pair is historical", %{
    server: server,
    nonce: nonce
  } do
    {:ok, id} = Pending.enqueue(server, nonce, frame())
    presented = %{"job_digest" => Pending.job_digest(frame()), "resource" => frame()["resource"]}

    assert {:ok, %{"kind" => "live", "attempt_id" => "att_1"}} =
             Pending.admit(server, id, "att_1", presented)

    assert {:ok, %{"kind" => "historical", "attempt_id" => "att_1"}} =
             Pending.admit(server, id, "att_1", presented)

    assert {:error, :already_dispatched} = Pending.admit(server, id, "att_2", presented)
  end

  test "admission refuses frame mismatch and does not reset enqueue time", %{
    server: server,
    nonce: nonce
  } do
    {:ok, id} = Pending.enqueue(server, nonce, frame())
    {:ok, row} = Pending.fetch(server, id)

    assert {:error, :frame_mismatch} =
             Pending.admit(server, id, "att_1", %{
               "job_digest" => "other",
               "resource" => frame()["resource"]
             })

    {:ok, still} = Pending.fetch(server, id)
    assert still.enqueue_mono_ms == row.enqueue_mono_ms
    assert still.status == :pending
  end

  test "cancel and restart invalidate the id", %{server: server, nonce: nonce} do
    {:ok, id} = Pending.enqueue(server, nonce, frame())
    assert :ok = Pending.cancel(server, id)

    assert {:error, :cancelled} =
             Pending.admit(server, id, "att_1", %{
               "job_digest" => Pending.job_digest(frame()),
               "resource" => frame()["resource"]
             })

    :ok = Pending.reset(server)
    assert {:error, :unknown} = Pending.fetch(server, id)
  end

  test "expired queue age refuses admission" do
    name = :"pending_exp_#{System.unique_integer([:positive])}"
    server = start_supervised!({Pending, name: name, max_age_ms: 0})
    nonce = Mjolnir.Secrets.Nonces.issue()
    {:ok, id} = Pending.enqueue(server, nonce, frame())
    Process.sleep(2)

    assert {:error, :expired} =
             Pending.admit(server, id, "att_1", %{
               "job_digest" => Pending.job_digest(frame()),
               "resource" => frame()["resource"]
             })
  end
end
