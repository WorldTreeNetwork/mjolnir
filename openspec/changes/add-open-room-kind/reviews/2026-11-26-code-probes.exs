# Independent review probes for 0d1b3f0. Assertions describe observed behavior,
# including defects; passing this script is NOT security acceptance.
# MIX_ENV=test mix run --no-start --no-compile <this file>
ExUnit.start()

defmodule OpenRoomCodeReviewProbes do
  use ExUnit.Case, async: false
  alias Mjolnir.Relay.{Mint, RoomClass, RoomJoin}
  @owner Mjolnir.Deploy.Owner.encode(:binary.copy(<<9>>, 32))
  @open "t/#{@owner}/~open/standup"
  @protected "t/#{@owner}/standup"

  defp token(claims),
    do: "not-a-header." <> Base.url_encode64(Jason.encode!(claims), padding: false) <> "."

  defp response(root, claims),
    do: %{"token" => token(claims), "root" => root, "kind" => "open"}

  test "R1: unauthenticated, expired, grantless payload is accepted" do
    assert {:ok, %{kind: :open}} =
             RoomJoin.check(@open, :open, response(@open, %{"root" => @open, "exp" => 1}))
    assert {:ok, %{kind: :open}} =
             RoomJoin.check(@open, :open, response(@open, %{"root" => @open}))
  end

  test "R2: valid JSON non-object payload raises instead of returning bad_token" do
    for claims <- [[], [1], "text", 1, true] do
      assert catch_error(RoomJoin.check(@open, :open, response(@open, claims)))
    end
  end

  test "R3: protected response false and null kind are accepted as missing" do
    for kind <- [false, nil] do
      body = %{"token" => token(%{"root" => @protected}), "root" => @protected, "kind" => kind}
      assert {:ok, %{kind: :protected}} = RoomJoin.check(@protected, :protected, body)
    end
  end

  test "identity mismatch and old-mint refusal remain fail closed" do
    other = Mjolnir.Deploy.Owner.encode(:binary.copy(<<8>>, 32))
    for root <- ["t/#{other}/~open/standup", "t/#{@owner}/~open/other", @protected] do
      assert {:error, :unexpected_root} =
               RoomJoin.check(@open, :open, response(root, %{"root" => root}))
    end
    old = %{"token" => token(%{"root" => @protected}), "root" => @protected}
    assert {:error, :unexpected_root} = RoomJoin.check(@open, :open, old)
    assert {:error, :open_refused} = RoomJoin.check(@protected, :open, old)
    missing_kind = Map.delete(response(@open, %{"root" => @open}), "kind")
    assert {:error, :open_refused} = RoomJoin.check(@open, :open, missing_kind)
  end

  test "classifier limits, zero owner, and whitespace are exact" do
    zero = String.duplicate("1", 32)
    assert :open = RoomClass.classify("t/#{zero}/~open/" <> String.duplicate("a", 64))
    for root <- ["t/#{zero}1/a", "t/#{String.duplicate("1", 31)}/a",
                 "t/#{@owner}/" <> String.duplicate("a", 65),
                 "t/#{@owner}/a\n", "t/#{@owner}\n/a", "t/#{@owner}/~open/",
                 "t/#{@owner}/~open/a/", "t/#{@owner}/~open/é"] do
      assert :invalid = RoomClass.classify(root)
    end
  end

  test "mint validation order and complete bad-kind corpus with absent env" do
    caller = %{kind: :user, scopes: "relay:join", sub: @owner}
    opts = [env_path: "/nonexistent/review-relay.env"]
    bad = %{"kind" => "Open"}
    assert {:error, 403, _} = Mint.issue(%{caller | scopes: ""}, "!", "p", bad, opts)
    assert {:error, 400, "bad_segment"} = Mint.issue(caller, "!", "p", bad, opts)
    assert {:error, 400, "bad_ttl"} = Mint.issue(caller, "r", "p", Map.put(bad, "ttl", "1"), opts)
    assert {:error, 400, "bad_kind"} = Mint.issue(caller, "r", "p", Map.put(bad, "ttl", 0), opts)
    assert {:error, 503, "relay_unavailable"} = Mint.issue(caller, "r", "p", %{"ttl" => 0}, opts)
    for kind <- ["Open", "open ", "", nil, 1, 1.0, true, false, ["open"], %{}, "open\n"] do
      assert {:error, 400, "bad_kind"} = Mint.issue(caller, "r", "p", %{"kind" => kind}, opts)
    end
  end

  @tag :tmp_dir
  test "both minted kinds have independently verified signatures and exact grants", %{tmp_dir: dir} do
    key = JOSE.JWK.generate_key({:okp, :Ed25519})
    {_, jwk} = JOSE.JWK.to_map(key)
    path = Path.join(dir, "key.json")
    env = Path.join(dir, "relay.env")
    File.chmod!(dir, 0o700)
    File.write!(path, Jason.encode!(Map.merge(jwk, %{"kid" => "review", "alg" => "EdDSA"})))
    File.chmod!(path, 0o600)
    File.write!(env, "MJOLNIR_RELAY_ENABLED=true\nMJOLNIR_RELAY_HOST=review.invalid\n")
    caller = %{kind: :user, scopes: "relay:join", sub: @owner}
    for {body, root, kind} <- [{%{}, @protected, "protected"}, {%{"kind" => "protected"}, @protected, "protected"}, {%{"kind" => "open"}, @open, "open"}] do
      assert {:ok, minted} = Mint.issue(caller, "standup", "alice", body,
        env_path: env, key_path: path, uid: File.stat!(path).uid)
      assert {true, jwt, _} = JOSE.JWT.verify_strict(JOSE.JWK.to_public(key), ["EdDSA"], minted.token)
      assert jwt.fields["root"] == root
      assert minted.root == root and minted.kind == kind
      assert jwt.fields["publish"] == ["alice/**"]
      assert jwt.fields["subscribe"] == ["**"]
      assert Enum.sort(Map.keys(jwt.fields)) == ~w(exp iat jti publish root subscribe)
    end
  end
end
