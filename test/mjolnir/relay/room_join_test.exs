defmodule Mjolnir.Relay.RoomJoinTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Relay.RoomJoin

  @owner Mjolnir.Deploy.Owner.encode(:binary.copy(<<9>>, 32))
  @open "t/#{@owner}/~open/standup"
  @protected "t/#{@owner}/standup"

  defp token(root) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "EdDSA"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(%{"root" => root, "exp" => 1}), padding: false)
    header <> "." <> payload <> ".sig"
  end

  defp response(root, kind) do
    map = %{"token" => token(root), "root" => root}
    if kind, do: Map.put(map, "kind", kind), else: map
  end

  test "join, replacement, and renewal share one expected-root check" do
    open = response(@open, "open")
    protected = response(@protected, "protected")

    for _step <- [:join, :replacement, :renewal] do
      assert {:ok, %{kind: :open, root: @open}} = RoomJoin.check(@open, :open, open)

      assert {:ok, %{kind: :protected, root: @protected}} =
               RoomJoin.check(@protected, :protected, protected)
    end
  end

  test "old mint fixture refuses explicit open and keeps protected" do
    # Shape captured before this mint change: no response kind, protected root.
    old = %{"token" => token(@protected), "root" => @protected, "publish" => "alice/**"}

    assert {:error, :open_refused} = RoomJoin.check(@protected, :open, old)
    assert {:error, :unexpected_root} = RoomJoin.check(@open, :open, old)

    assert {:ok, %{kind: :protected, root: @protected}} =
             RoomJoin.check(@protected, :protected, old)
  end

  test "protected does not fall back onto an open token" do
    open = response(@open, "open")
    assert {:error, :protected_refused} = RoomJoin.check(@open, :protected, open)
    assert {:error, :unexpected_root} = RoomJoin.check(@protected, :protected, open)
  end

  test "response and token disagreement" do
    lying = %{"token" => token(@open), "root" => @protected, "kind" => "open"}
    assert {:error, :response_root_mismatch} = RoomJoin.check(@open, :open, lying)

    kind_lie = response(@open, "protected")
    assert {:error, :kind_mismatch} = RoomJoin.check(@open, :open, kind_lie)

    assert {:error, :bad_token} = RoomJoin.check(@open, :open, %{"root" => @open})
  end

  test "atom keys on a matching response" do
    body = %{token: token(@protected), root: @protected, kind: "protected"}
    assert {:ok, %{kind: :protected}} = RoomJoin.check(@protected, :protected, body)
  end
end
