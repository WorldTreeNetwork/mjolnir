defmodule Mjolnir.Relay.RoomJoinTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Relay.RoomJoin

  @owner Mjolnir.Deploy.Owner.encode(:binary.copy(<<9>>, 32))
  @open "t/#{@owner}/~open/standup"
  @protected "t/#{@owner}/standup"

  defp token(root), do: "admission-fixture:" <> root

  defp response(root, kind) do
    map = %{"token" => token(root), "root" => root}
    if kind, do: Map.put(map, "kind", kind), else: map
  end

  # Stub only the trusted admission boundary; these tests prove comparison,
  # not signature verification or lifecycle integration.
  defp check(expected, asked, response) do
    token = Map.get(response, "token", Map.get(response, :token))

    root = if is_binary(token), do: String.replace_prefix(token, "admission-fixture:", "")

    if token,
      do: RoomJoin.check(expected, asked, response, {:ok, %{token: token, root: root}}),
      else: {:error, :bad_token}
  end

  test "unauthenticated or different credentials cannot supply identity" do
    body = response(@protected, "protected")

    for admission <- [nil, {:error, :expired}, {:ok, %{token: "other", root: @protected}}] do
      assert {:error, :unauthenticated_identity} =
               RoomJoin.check(@protected, :protected, body, admission)
    end

    for payload <- ["[]", "null", "1", "true", "bad json"] do
      body = %{body | "token" => "x." <> Base.url_encode64(payload) <> "."}

      assert {:error, :unauthenticated_identity} =
               RoomJoin.check(@protected, :protected, body, {:error, :bad_token})
    end
  end

  test "present invalid kinds and conflicting representations refuse" do
    body = response(@protected, "protected")

    for kind <- [nil, false, true, 1, [], %{}] do
      assert {:error, :kind_mismatch} = check(@protected, :protected, Map.put(body, "kind", kind))
    end

    assert {:error, :kind_mismatch} = check(@protected, :protected, Map.put(body, :kind, "open"))
  end

  test "authenticated identities match independently expected roots" do
    open = response(@open, "open")
    protected = response(@protected, "protected")

    for _ <- [:identity_comparison] do
      assert {:ok, %{kind: :open, root: @open}} = check(@open, :open, open)

      assert {:ok, %{kind: :protected, root: @protected}} =
               check(@protected, :protected, protected)
    end
  end

  test "old mint fixture refuses explicit open and keeps protected" do
    # Shape captured before this mint change: no response kind, protected root.
    old = %{"token" => token(@protected), "root" => @protected, "publish" => "alice/**"}

    assert {:error, :open_refused} = check(@protected, :open, old)
    assert {:error, :unexpected_root} = check(@open, :open, old)

    assert {:ok, %{kind: :protected, root: @protected}} =
             check(@protected, :protected, old)
  end

  test "protected does not fall back onto an open token" do
    open = response(@open, "open")
    assert {:error, :protected_refused} = check(@open, :protected, open)
    assert {:error, :unexpected_root} = check(@protected, :protected, open)
  end

  test "response and token disagreement" do
    lying = %{"token" => token(@open), "root" => @protected, "kind" => "open"}
    assert {:error, :response_root_mismatch} = check(@open, :open, lying)

    kind_lie = response(@open, "protected")
    assert {:error, :kind_mismatch} = check(@open, :open, kind_lie)

    assert {:error, :bad_token} = check(@open, :open, %{"root" => @open})
  end

  test "atom keys on a matching response" do
    body = %{token: token(@protected), root: @protected, kind: "protected"}
    assert {:ok, %{kind: :protected}} = check(@protected, :protected, body)
  end
end
