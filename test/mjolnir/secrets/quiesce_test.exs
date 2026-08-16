defmodule Mjolnir.Secrets.QuiesceTest do
  @moduledoc """
  mjolnir-k8y.3 — fail-closed classification of suspend/resume replies.

  The transport is a live vsock; these tests pin the policy that decides
  whether a secrets VM may be snapshotted or exposed after thaw, which is
  decidable from the JSON alone.
  """
  use ExUnit.Case, async: true

  alias Mjolnir.Secrets.Quiesce

  describe "interpret_suspend/1" do
    test "ok + suspended true is a wiped key" do
      assert {:ok, %{suspended: true}} =
               Quiesce.interpret_suspend(%{
                 "type" => "suspend_secrets_response",
                 "ok" => true,
                 "suspended" => true
               })
    end

    test "ok + suspended false is a successful no-op (nothing was open)" do
      assert {:ok, %{suspended: false}} =
               Quiesce.interpret_suspend(%{
                 "type" => "suspend_secrets_response",
                 "ok" => true,
                 "suspended" => false
               })
    end

    test "ok with a missing suspended flag is treated as not wiped" do
      # Don't invent a wipe that the guest did not confirm.
      assert {:ok, %{suspended: false}} =
               Quiesce.interpret_suspend(%{
                 "type" => "suspend_secrets_response",
                 "ok" => true
               })
    end

    test "guest refusal is an error" do
      assert {:error, {:suspend_refused, "cryptsetup failed"}} =
               Quiesce.interpret_suspend(%{
                 "type" => "suspend_secrets_response",
                 "ok" => false,
                 "error" => "cryptsetup failed"
               })
    end

    test "an old agent surfaces as unsupported, not a hang" do
      assert {:error, {:suspend_unsupported_by_agent, "unknown type"}} =
               Quiesce.interpret_suspend(%{
                 "type" => "error",
                 "error" => "unknown type"
               })
    end

    test "anything else is unexpected" do
      assert {:error, {:suspend_unexpected_response, %{"type" => "pong"}}} =
               Quiesce.interpret_suspend(%{"type" => "pong"})
    end
  end

  describe "interpret_resume/1" do
    test "ok is :ok" do
      assert :ok =
               Quiesce.interpret_resume(%{
                 "type" => "resume_secrets_response",
                 "ok" => true
               })
    end

    test "guest refusal is an error" do
      assert {:error, {:resume_refused, "bad passphrase"}} =
               Quiesce.interpret_resume(%{
                 "type" => "resume_secrets_response",
                 "ok" => false,
                 "error" => "bad passphrase"
               })
    end

    test "an old agent surfaces as unsupported" do
      assert {:error, {:resume_unsupported_by_agent, "nope"}} =
               Quiesce.interpret_resume(%{"type" => "error", "error" => "nope"})
    end
  end

  describe "request builders" do
    test "suspend_request/1 is a suspend_secrets message" do
      req = Quiesce.suspend_request(request_id: "s1")
      assert req["type"] == "suspend_secrets"
      assert req["id"] == "s1"
    end

    test "resume_request/2 carries the passphrase" do
      req = Quiesce.resume_request("hunter2", request_id: "r1")
      assert req["type"] == "resume_secrets"
      assert req["passphrase"] == "hunter2"
      assert req["id"] == "r1"
    end
  end
end
